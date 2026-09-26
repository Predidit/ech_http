import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:test/test.dart';

void main() {
  final clients = <http.Client>[];
  final servers = <HttpServer>[];
  EchClient client({bool auto = true, int limit = 4 * 1024 * 1024}) {
    final result = EchClient(
      autoUncompress: auto,
      maxResponseBytes: limit,
      maxConcurrentRequests: 1,
    );
    clients.add(result);
    return result;
  }

  IOClient reference({bool auto = true}) {
    final result = IOClient(HttpClient()..autoUncompress = auto);
    clients.add(result);
    return result;
  }

  Future<Uri> serve(Future<void> Function(HttpRequest) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      try {
        await handler(request);
      } on SocketException {
        // Deliberate cancellation or response limit.
      } on HttpException {
        // Deliberate cancellation or response limit.
      }
    });
    return Uri.http('127.0.0.1:${server.port}', '/');
  }

  tearDown(() async {
    for (final c in clients) {
      c.close();
    }
    clients.clear();
    for (final s in servers) {
      await s.close(force: true);
    }
    servers.clear();
  });

  final plain = utf8.encode('gzip response 正文\n' * 200);
  final packed = gzip.encode(plain);

  for (final auto in [true, false]) {
    for (final encoding in <String?>[
      'gzip',
      null,
      'deflate',
      'br',
      'GZip',
      'x-gzip',
      'gzip, gzip',
    ]) {
      test('IOClient parity: encoding=$encoding auto=$auto', () async {
        final uri = await serve((r) async {
          if (encoding != null) {
            r.response.headers.set('content-encoding', encoding);
          }
          r.response.headers.set('content-type', 'application/gzip');
          r.response.contentLength = packed.length;
          r.response.add(packed);
          await r.response.close();
        });
        final expected = await reference(
          auto: auto,
        ).send(http.Request('GET', uri));
        final actual = await client(auto: auto).send(http.Request('GET', uri));
        expect(actual.contentLength, expected.contentLength);
        expect(
          actual.headers['content-length'],
          expected.headers['content-length'],
        );
        expect(
          actual.headers['content-encoding'],
          expected.headers['content-encoding'],
        );
        expect(await actual.stream.toBytes(), await expected.stream.toBytes());
        expect(
          actual.compressionState,
          encoding == 'gzip'
              ? (auto
                    ? HttpClientResponseCompressionState.decompressed
                    : HttpClientResponseCompressionState.compressed)
              : HttpClientResponseCompressionState.notCompressed,
        );
      });
    }

    test('IOClient parity: negotiation and override with auto=$auto', () async {
      final uri = await serve((r) async {
        r.response.write(r.headers.value('accept-encoding'));
        await r.response.close();
      });
      for (final headers in <Map<String, String>>[
        {},
        {'Accept-Encoding': 'identity'},
        {'accept-encoding': 'gzip, deflate'},
        {'Accept-Encoding': ''},
      ]) {
        expect(
          (await client(auto: auto).get(uri, headers: headers)).body,
          (await reference(auto: auto).get(uri, headers: headers)).body,
        );
      }
    });
  }

  test('buffered body length and original headers match IOClient', () async {
    final uri = await serve((r) async {
      r.response.headers.set('content-encoding', 'gzip');
      r.response.contentLength = packed.length;
      r.response.add(packed);
      await r.response.close();
    });
    final actual = await client().get(uri);
    final expected = await reference().get(uri);
    expect(actual.bodyBytes, plain);
    expect(actual.contentLength, expected.contentLength);
    expect(actual.contentLength, plain.length);
    expect(actual.headers['content-length'], '${packed.length}');
    expect(actual.headers['content-encoding'], 'gzip');
  });

  test('uploads are not compressed or re-encoded automatically', () async {
    final uri = await serve((r) async {
      final body = await r.fold<List<int>>(
        [],
        (all, data) => all..addAll(data),
      );
      if (r.headers.value('content-encoding') == 'gzip') {
        expect(body, packed);
      } else {
        expect(body, plain);
      }
      r.response.write('ok');
      await r.response.close();
    });
    final c = client();
    expect((await c.post(uri, body: plain)).body, 'ok');
    expect(
      (await c.post(
        uri,
        headers: {'Content-Encoding': 'gzip'},
        body: packed,
      )).body,
      'ok',
    );
  });

  for (final entry in [
    ('GET', 200),
    ('HEAD', 200),
    ('GET', 204),
    ('GET', 304),
  ]) {
    test('IOClient parity: empty ${entry.$1} ${entry.$2}', () async {
      final uri = await serve((r) async {
        r.response.statusCode = entry.$2;
        r.response.headers.set('content-encoding', 'gzip');
        r.response.contentLength = entry.$1 == 'HEAD' ? packed.length : 0;
        await r.response.close();
      });
      final actual = await client().send(http.Request(entry.$1, uri));
      final expected = await reference().send(http.Request(entry.$1, uri));
      expect(actual.contentLength, expected.contentLength);
      expect(await actual.stream.toBytes(), await expected.stream.toBytes());
      expect(actual.headers['content-encoding'], 'gzip');
    });
  }

  test(
    'chunked multi-member gzip is decoded across one-byte input chunks',
    () async {
      final uri = await serve((r) async {
        r.response.headers.set('content-encoding', 'gzip');
        for (final byte in [...gzip.encode([]), ...packed, ...packed]) {
          r.response.add([byte]);
          await r.response.flush();
        }
        await r.response.close();
      });
      final c = client();
      final response = await c.send(http.Request('GET', uri));
      expect(response.contentLength, isNull);
      expect(await response.stream.toBytes(), [...plain, ...plain]);
      expect(
        (await c.get(uri)).bodyBytes,
        (await reference().get(uri)).bodyBytes,
      );
    },
  );

  test(
    'gzip selected by the response is decoded after identity negotiation',
    () async {
      final uri = await serve((r) async {
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add(packed);
        await r.response.close();
      });
      expect(
        (await client().get(
          uri,
          headers: {'Accept-Encoding': 'identity'},
        )).bodyBytes,
        (await reference().get(
          uri,
          headers: {'Accept-Encoding': 'identity'},
        )).bodyBytes,
      );
    },
  );

  test(
    'gzip redirects are drained and negotiation reaches the final request',
    () async {
      final seen = <String?>[];
      final uri = await serve((r) async {
        seen.add(r.headers.value('accept-encoding'));
        if (r.uri.path == '/') {
          r.response.statusCode = 302;
          r.response.headers.set('location', '/final');
        }
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add(packed);
        await r.response.close();
      });
      expect((await client().get(uri)).bodyBytes, plain);
      expect(seen, ['gzip', 'gzip']);
    },
  );

  test(
    'range requests retain IOClient negotiation and decoding behavior',
    () async {
      final uri = await serve((r) async {
        expect(r.headers.value('accept-encoding'), 'gzip');
        expect(r.headers.value('range'), 'bytes=0-');
        r.response.statusCode = 206;
        r.response.headers.set('content-encoding', 'gzip');
        r.response.headers.set(
          'content-range',
          'bytes 0-${packed.length - 1}/${packed.length}',
        );
        r.response.contentLength = packed.length;
        r.response.add(packed);
        await r.response.close();
      });
      final headers = {'Range': 'bytes=0-'};
      final actual = await client().get(uri, headers: headers);
      final expected = await reference().get(uri, headers: headers);
      expect(actual.bodyBytes, expected.bodyBytes);
      expect(
        actual.headers['content-range'],
        expected.headers['content-range'],
      );
    },
  );

  test(
    'decoded size is limited and failure releases the request slot',
    () async {
      final compressed = gzip.encode(Uint8List(2 * 1024 * 1024));
      final uri = await serve((r) async {
        if (r.uri.path == '/') {
          r.response.headers.set('content-encoding', 'gzip');
          r.response.add(compressed);
        } else {
          r.response.write('next');
        }
        await r.response.close();
      });
      final c = client(limit: 64 * 1024);
      await expectLater(
        c.get(uri),
        throwsA(
          isA<EchException>().having(
            (e) => e.message,
            'limit',
            contains('maxResponseBytes'),
          ),
        ),
      );
      expect((await c.get(uri.resolve('/next'))).body, 'next');
      expect(
        (await client(auto: false, limit: 64 * 1024).get(uri)).bodyBytes,
        compressed,
      );
    },
  );

  for (final kind in ['invalid header', 'CRC', 'truncated', 'trailing data']) {
    test(
      'invalid gzip ($kind) fails the stream and releases its slot',
      () async {
        final bytes = List<int>.of(packed);
        switch (kind) {
          case 'invalid header':
            bytes[0] = 0;
          case 'CRC':
            bytes[bytes.length - 8] ^= 255;
          case 'truncated':
            bytes.removeLast();
          case 'trailing data':
            bytes.addAll([1, 2, 3]);
        }
        final uri = await serve((r) async {
          if (r.uri.path == '/') {
            r.response.headers.set('content-encoding', 'gzip');
            r.response.add(bytes);
          } else {
            r.response.write('ok');
          }
          await r.response.close();
        });
        final c = client();
        await expectLater(
          c.get(uri),
          throwsA(
            isA<EchException>().having(
              (e) => e.nativeCode,
              'bad content encoding',
              61,
            ),
          ),
        );
        expect((await c.get(uri.resolve('/next'))).body, 'ok');
      },
    );
  }

  test(
    'paused gzip output can resume and cancel without retaining its slot',
    () async {
      final bytes = Uint8List(2 * 1024 * 1024);
      final compressed = gzip.encode(bytes);
      final uri = await serve((r) async {
        r.response.headers.set('content-encoding', 'gzip');
        r.response.add(compressed);
        await r.response.close();
      });
      final c = client();
      final response = await c.send(http.Request('GET', uri));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final output = BytesBuilder(copy: false);
      final done = Completer<void>();
      late StreamSubscription<List<int>> subscription;
      var pauses = 0;
      subscription = response.stream.listen(
        (data) {
          output.add(data);
          if (pauses++ < 8) {
            subscription.pause(
              Future<void>.delayed(const Duration(milliseconds: 2)),
            );
          }
        },
        onDone: done.complete,
        onError: done.completeError,
      );
      await done.future.timeout(const Duration(seconds: 5));
      expect(output.takeBytes(), bytes);
      final second = await c.send(http.Request('GET', uri));
      final paused = second.stream.listen((_) {})..pause();
      final next = c.get(uri);
      await paused.cancel();
      expect((await next.timeout(const Duration(seconds: 5))).bodyBytes, bytes);
    },
  );
}
