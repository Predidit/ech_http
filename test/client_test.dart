import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  final clients = <EchClient>[];
  final servers = <HttpServer>[];
  EchClient client({
    int concurrency = 6,
    int limit = 1024 * 1024,
    Duration timeout = const Duration(seconds: 5),
    String? roots,
    EchResolver? resolver,
  }) {
    final c = EchClient(
      maxConcurrentRequests: concurrency,
      maxResponseBytes: limit,
      timeout: timeout,
      trustedRootsPem: roots,
      resolver: resolver,
    );
    clients.add(c);
    return c;
  }

  Future<HttpServer> serve(
    FutureOr<void> Function(HttpRequest) handler, {
    bool secure = false,
  }) async {
    final server = secure
        ? await HttpServer.bindSecure(
            InternetAddress.loopbackIPv4,
            0,
            SecurityContext()
              ..useCertificateChain('test/fixtures/localhost-cert.pem')
              ..usePrivateKey('test/fixtures/localhost-key.pem'),
          )
        : await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen(
      (request) async {
        try {
          await handler(request);
        } on SocketException {
          /* Deliberate client cancellation. */
        } on HttpException {
          /* Deliberate client cancellation. */
        }
      },
      onError: (Object _) {
        /* Deliberate TLS verification failures. */
      },
    );
    return server;
  }

  Uri url(HttpServer server, [String path = '/']) =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: path);
  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    for (final server in servers) {
      await server.close(force: true);
    }
    servers.clear();
  });

  test('GET, binary data, response headers and HTTP error statuses', () async {
    final server = await serve((r) async {
      r.response.statusCode = 404;
      r.response.headers.set('etag', 'test-tag');
      r.response.add([0, 255, 128, 42]);
      await r.response.close();
    });
    final response = await client().get(url(server));
    expect(response.statusCode, 404);
    expect(response.headers['etag'], 'test-tag');
    expect(response.bodyBytes, [0, 255, 128, 42]);
  });

  test('POST body is preserved and 303 switches to GET', () async {
    final seen = <String>[];
    final server = await serve((r) async {
      seen.add('${r.method} ${await utf8.decoder.bind(r).join()}');
      if (r.uri.path == '/') {
        r.response.statusCode = 303;
        r.response.headers.set('location', '/next');
      } else {
        r.response.write('done');
      }
      await r.response.close();
    });
    final response = await client().post(url(server), body: 'payload');
    expect(response.body, 'done');
    expect(seen, ['POST payload', 'GET ']);
  });

  test('large responses complete without a periodic event pump', () async {
    final expected = Uint8List.fromList(List.generate(2000000, (i) => i % 251));
    final server = await serve((r) async {
      r.response.add(expected);
      await r.response.close();
    });
    var periodicTimers = 0;
    final response = await runZoned(
      () => client(limit: expected.length).get(url(server)),
      zoneSpecification: ZoneSpecification(
        createPeriodicTimer: (self, parent, zone, period, callback) {
          periodicTimers++;
          return parent.createPeriodicTimer(zone, period, callback);
        },
      ),
    );
    expect(response.bodyBytes, expected);
    expect(periodicTimers, 0);
  });

  test(
    'a delayed listener can pause repeatedly without losing wakeups',
    () async {
      final expected = Uint8List.fromList(
        List.generate(900000, (i) => i % 251),
      );
      final server = await serve((r) async {
        r.response.add(expected);
        await r.response.close();
      });
      final response = await client().send(http.Request('GET', url(server)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final received = BytesBuilder(copy: false);
      final complete = Completer<void>();
      var pauses = 0;
      late StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen(
        (data) {
          received.add(data);
          if (pauses++ < 8) {
            subscription.pause(
              Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
        },
        onDone: complete.complete,
        onError: complete.completeError,
      );
      await complete.future.timeout(const Duration(seconds: 3));
      expect(pauses, greaterThanOrEqualTo(8));
      expect(received.takeBytes(), expected);
    },
  );

  test('cancelling a paused response immediately releases its slot', () async {
    final server = await serve((r) async {
      if (r.uri.path == '/large') {
        r.response.add(Uint8List(900000));
      } else {
        r.response.write('next');
      }
      await r.response.close();
    });
    final c = client(concurrency: 1);
    final response = await c.send(http.Request('GET', url(server, '/large')));
    final subscription = response.stream.listen((_) {});
    subscription.pause();
    final next = c.get(url(server));
    await subscription.cancel();
    expect((await next.timeout(const Duration(seconds: 1))).body, 'next');
  });

  test('cross-origin redirect removes sensitive headers', () async {
    String? authorization, cookie;
    final target = await serve((r) async {
      authorization = r.headers.value('authorization');
      cookie = r.headers.value('cookie');
      r.response.write('ok');
      await r.response.close();
    });
    final origin = await serve((r) async {
      r.response.statusCode = 302;
      r.response.headers.set('location', url(target).toString());
      await r.response.close();
    });
    await client().get(
      url(origin),
      headers: {'Authorization': 'Bearer test', 'Cookie': 'session=test'},
    );
    expect(authorization, isNull);
    expect(cookie, isNull);
  });

  test('HEAD exposes content length without waiting for a body', () async {
    final server = await serve((r) async {
      r.response.contentLength = 800;
      await r.response.close();
    });
    final response = await client().head(url(server));
    expect(response.bodyBytes, isEmpty);
    expect(response.headers['content-length'], '800');
  });

  test('paused streaming responses resume without corrupting bytes', () async {
    final expected = Uint8List.fromList(List.generate(700000, (i) => i % 251));
    final server = await serve((r) async {
      r.response.add(expected);
      await r.response.close();
    });
    final response = await client().send(http.Request('GET', url(server)));
    final received = BytesBuilder(copy: false);
    final complete = Completer<void>();
    final subscription = response.stream.listen(
      received.add,
      onDone: complete.complete,
      onError: complete.completeError,
    );
    subscription.pause();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    subscription.resume();
    await complete.future;
    expect(received.takeBytes(), expected);
  });

  test('max response size fails with a transport exception', () async {
    final server = await serve((r) async {
      r.response.add(List.filled(10000, 65));
      await r.response.close();
    });
    await expectLater(
      client(limit: 100).get(url(server)),
      throwsA(isA<EchException>()),
    );
  });

  test('request timeout is bounded', () async {
    final server = await serve((r) async {
      await Future<void>.delayed(const Duration(seconds: 1));
      await r.response.close();
    });
    await expectLater(
      client(timeout: const Duration(milliseconds: 100)).get(url(server)),
      throwsA(
        isA<EchException>().having((e) => e.nativeCode, 'curl timeout', 28),
      ),
    );
  });

  test('abort trigger cancels a request before headers', () async {
    final server = await serve((r) async {
      await Future<void>.delayed(const Duration(seconds: 1));
      await r.response.close();
    });
    final abort = Completer<void>();
    final request = http.AbortableRequest(
      'GET',
      url(server),
      abortTrigger: abort.future,
    );
    final response = client().send(request);
    Timer(const Duration(milliseconds: 30), abort.complete);
    await expectLater(response, throwsA(isA<http.RequestAbortedException>()));
  });

  test('concurrency limit queues requests and completes all of them', () async {
    var active = 0, maximum = 0;
    final server = await serve((r) async {
      active++;
      if (active > maximum) maximum = active;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      active--;
      r.response.write('ok');
      await r.response.close();
    });
    final c = client(concurrency: 2);
    final responses = await Future.wait(
      List.generate(8, (_) => c.get(url(server))),
    );
    expect(responses.length, 8);
    expect(maximum, lessThanOrEqualTo(2));
  });

  test(
    'aborting a queued request removes it without consuming a slot',
    () async {
      var count = 0;
      final entered = Completer<void>();
      final release = Completer<void>();
      final server = await serve((r) async {
        count++;
        if (count == 1) {
          entered.complete();
          await release.future;
        }
        r.response.write('ok');
        await r.response.close();
      });
      final c = client(concurrency: 1);
      final first = c.get(url(server));
      await entered.future;
      final abort = Completer<void>();
      final queued = c.send(
        http.AbortableRequest('GET', url(server), abortTrigger: abort.future),
      );
      final failed = expectLater(
        queued,
        throwsA(isA<http.RequestAbortedException>()),
      );
      abort.complete();
      await failed.timeout(const Duration(seconds: 1));
      release.complete();
      await first;
      expect((await c.get(url(server))).body, 'ok');
      expect(count, 2);
    },
  );

  test('closing before listening delivers a response stream error', () async {
    final server = await serve((r) async {
      r.response.write('start');
      await r.response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await r.response.close();
    });
    final c = client();
    final response = await c.send(http.Request('GET', url(server)));
    c.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(
      response.stream.drain<void>(),
      throwsA(isA<http.ClientException>()),
    );
  });

  test(
    'abort interrupts resolver wait before a native request starts',
    () async {
      final pending = Completer<EchRoute?>();
      final c = client(resolver: _PendingResolver(pending.future));
      final abort = Completer<void>();
      final response = c.send(
        http.AbortableRequest(
          'GET',
          Uri.https('pending.test'),
          abortTrigger: abort.future,
        ),
      );
      final failed = expectLater(
        response,
        throwsA(isA<http.RequestAbortedException>()),
      );
      Timer(const Duration(milliseconds: 20), abort.complete);
      await failed.timeout(const Duration(seconds: 1));
      pending.complete(null);
    },
  );

  test('closing a client rejects active and queued requests', () async {
    final server = await serve((r) async {
      await Future<void>.delayed(const Duration(seconds: 1));
      await r.response.close();
    });
    final c = client(concurrency: 1);
    final first = expectLater(
      c.get(url(server)),
      throwsA(isA<http.ClientException>()),
    );
    final second = expectLater(
      c.get(url(server)),
      throwsA(isA<http.ClientException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    c.close();
    await Future.wait([first, second]);
  });

  test('TLS requires a trusted certificate and matching hostname', () async {
    final server = await serve((r) async {
      r.response.write('trusted');
      await r.response.close();
    }, secure: true);
    final local = Uri(scheme: 'https', host: 'localhost', port: server.port);
    await expectLater(client().get(local), throwsA(isA<EchException>()));
    final roots = await File('test/fixtures/localhost-cert.pem').readAsString();
    final c = client(roots: roots);
    expect((await c.get(local)).body, 'trusted');
    await expectLater(
      c.get(local.replace(host: '127.0.0.1')),
      throwsA(isA<EchException>()),
    );
  });

  test('unsupported ECH is rejected before opening a connection', () async {
    var connections = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      connections++;
      socket.destroy();
    });
    addTearDown(server.close);
    final c = client(
      resolver: StaticEchResolver({
        'localhost': EchRoute(
          configList: base64.encode([0, 4, 0, 1, 0, 0]),
          addresses: ['127.0.0.1'],
        ),
      }),
    );
    await expectLater(
      c.get(Uri(scheme: 'https', host: 'localhost', port: server.port)),
      throwsA(
        isA<EchException>().having((e) => e.nativeCode, 'ECH required', 101),
      ),
    );
    expect(connections, 0);
  });

  test('redirect limit is enforced', () async {
    final server = await serve((r) async {
      r.response.statusCode = 302;
      r.response.headers.set('location', '/again');
      await r.response.close();
    });
    await expectLater(
      client().send(http.Request('GET', url(server))..maxRedirects = 1),
      throwsA(isA<http.ClientException>()),
    );
  });

  for (final name in ['cloudflare-ech.123', 'cloudflare-ech.0x0']) {
    test('unusable ECH public name $name never emits ClientHello', () async {
      final captured = <int>[];
      final closed = Completer<void>();
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        socket.listen(
          captured.addAll,
          onDone: () {
            socket.destroy();
            if (!closed.isCompleted) closed.complete();
          },
          onError: (Object _) {
            socket.destroy();
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      addTearDown(server.close);
      // These are syntactically valid LDH names which BoringSSL treats as
      // unusable under WHATWG's "ends in a number" rule. Without a native
      // no-fallback policy it would send ordinary SNI for localhost.
      const encoded =
          'AEX+DQBBDwAgACDH/iPbkA9gQKNYkBgsN7iK5HFPtVOJrMbQ3Ioehxz1NwAEAAEAAQASY2xvdWRmbGFyZS1lY2guY29tAAA=';
      final bytes = latin1.encode(
        latin1
            .decode(base64.decode(encoded))
            .replaceFirst('cloudflare-ech.com', name),
      );
      final c = client(
        resolver: StaticEchResolver({
          'localhost': EchRoute(
            configList: base64.encode(bytes),
            addresses: ['127.0.0.1'],
          ),
        }),
      );
      await expectLater(
        c.get(Uri(scheme: 'https', host: 'localhost', port: server.port)),
        throwsA(
          isA<EchException>().having(
            (e) => e.nativeCode,
            'local TLS rejection',
            35,
          ),
        ),
      );
      await closed.future.timeout(const Duration(seconds: 1));
      // Only TLS alerts are permitted on the wire; never a handshake record.
      var offset = 0;
      while (offset < captured.length) {
        expect(captured.length - offset, greaterThanOrEqualTo(5));
        expect(captured[offset], 21);
        offset += 5 + captured[offset + 3] * 256 + captured[offset + 4];
      }
      expect(offset, captured.length);
    });
  }
}

final class _PendingResolver implements EchResolver {
  _PendingResolver(this.future);
  final Future<EchRoute?> future;
  @override
  Future<EchRoute?> resolve(Uri uri) => future;
}
