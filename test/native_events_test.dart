import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ech_http/ech_http.dart';
import 'package:ech_http/src/native.dart' as native;
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

// Leave the body incomplete so disconnects prove teardown, not normal completion.
Future<(Uri, Future<void>)> streamingServer() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final disconnected = Completer<void>();
  final sockets = <Socket>[];
  server.listen((socket) {
    sockets.add(socket);
    var sent = false;
    void finish() {
      socket.destroy();
      if (!disconnected.isCompleted) disconnected.complete();
    }

    unawaited(socket.done.then((_) {}, onError: (Object _) => finish()));
    socket.listen(
      (_) {
        if (sent) return;
        sent = true;
        socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2097152\r\n\r\n');
        socket.add(Uint8List(1024 * 1024));
      },
      onDone: finish,
      onError: (Object _) => finish(),
      cancelOnError: true,
    );
  });
  addTearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await server.close();
  });
  return (
    Uri(scheme: 'http', host: '127.0.0.1', port: server.port),
    disconnected.future,
  );
}

Pointer<native.NativeRequest> start(
  Pointer<native.NativeClient> client,
  Uri uri,
  ReceivePort port,
) => using((arena) {
  final options = arena<native.NativeOptions>();
  options.ref
    ..url = uri.toString().toNativeUtf8(allocator: arena)
    ..method = 'GET'.toNativeUtf8(allocator: arena)
    ..timeoutMs = 60000
    ..connectTimeoutMs = 1000
    ..maxResponseBytes = 4 * 1024 * 1024;
  return native.requestStart(
    client,
    options,
    NativeApi.postCObject,
    port.sendPort.nativePort,
  );
});

void main() {
  test('unacknowledged port payloads stay within the body budget', () async {
    final (uri, disconnected) = await streamingServer();
    final port = ReceivePort();
    addTearDown(port.close);
    final client = native.clientCreate();
    var request = start(client, uri, port);
    expect(request, isNot(nullptr));
    // The worker must retain the pool independently of its client handle.
    native.clientDestroy(client);
    addTearDown(() => native.requestDestroy(request));
    var received = 0;
    var acknowledge = false;
    final firstBody = Completer<void>();
    final allBody = Completer<void>();
    port.listen((message) {
      final event = message as List<Object?>;
      if (event[0] != 2) return;
      final data = event[4] as Uint8List;
      received += data.length;
      if (!firstBody.isCompleted) firstBody.complete();
      if (acknowledge) native.requestAcknowledge(request, data.length);
      if (received == 1024 * 1024) allBody.complete();
    });
    await firstBody.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, inInclusiveRange(240 * 1024, 256 * 1024));
    final stalled = received;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, stalled);
    acknowledge = true;
    native.requestAcknowledge(request, received);
    await allBody.future.timeout(const Duration(seconds: 3));
    port.close();
    native.requestDestroy(request);
    request = nullptr;
    await disconnected.timeout(const Duration(seconds: 3));
  });

  test('posting to a closed port cancels the native transfer safely', () async {
    final (uri, disconnected) = await streamingServer();
    final port = ReceivePort();
    final client = native.clientCreate();
    final request = start(client, uri, port);
    expect(request, isNot(nullptr));
    native.clientDestroy(client);
    addTearDown(() => native.requestDestroy(request));
    port.close();
    await disconnected.timeout(const Duration(seconds: 3));
  });

  test(
    'isolate group shutdown releases a backpressured native worker',
    () async {
      for (var i = 0; i < 3; i++) {
        final (uri, disconnected) = await streamingServer();
        final ready = ReceivePort();
        final exited = ReceivePort();
        final errors = ReceivePort();
        addTearDown(ready.close);
        addTearDown(exited.close);
        addTearDown(errors.close);
        final isolate = await Isolate.spawnUri(
          File('test/fixtures/abandon_transfer.dart').absolute.uri,
          [uri.toString()],
          ready.sendPort,
          onExit: exited.sendPort,
          onError: errors.sendPort,
          errorsAreFatal: true,
        );
        addTearDown(() => isolate.kill(priority: Isolate.immediate));
        final status = await Future.any([
          ready.first,
          errors.first.then<Object>((error) => throw StateError('$error')),
        ]).timeout(const Duration(seconds: 10));
        expect(status, 200);
        isolate.kill(priority: Isolate.immediate);
        await exited.first.timeout(const Duration(seconds: 3));
        await disconnected.timeout(const Duration(seconds: 3));
      }
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) {
        r.response.write('survived');
        unawaited(r.response.close());
      });
      final client = EchClient();
      addTearDown(client.close);
      expect(
        (await client.get(Uri.parse('http://127.0.0.1:${server.port}'))).body,
        'survived',
      );
    },
  );
}
