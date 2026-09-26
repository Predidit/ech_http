import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io' show HttpClientResponseCompressionState;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;

import 'native.dart' as native;
import 'types.dart';

/// A package:http client with an in-process C++ TLS/HTTP backend.
///
/// A non-null resolver result requires successful ECH, without plaintext
/// fallback. Null uses ordinary certificate-verified TLS. Response bodies are
/// streamed with bounded native buffering. Upload bodies are buffered up to
/// [maxRequestBytes]. Call [close] when the client is no longer needed.
final class EchClient extends http.BaseClient implements Finalizable {
  EchClient({
    this.resolver,
    this.proxy,
    this.timeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.maxResponseBytes = 32 * 1024 * 1024,
    this.maxRequestBytes = 8 * 1024 * 1024,
    this.maxConcurrentRequests = 6,
    this.autoUncompress = true,
    this.trustedRootsPem,
  }) {
    if (timeout.inMilliseconds <= 0 ||
        timeout.inMilliseconds > 0x7fffffff ||
        connectTimeout.inMilliseconds <= 0 ||
        connectTimeout.inMilliseconds > 0x7fffffff) {
      throw ArgumentError(
        'Timeouts must be positive and fit a signed 32-bit millisecond count',
      );
    }
    if (maxResponseBytes <= 0 ||
        maxRequestBytes <= 0 ||
        maxConcurrentRequests <= 0) {
      throw ArgumentError('Limits must be positive');
    }
    if (proxy != null &&
        (proxy!.scheme != 'http' ||
            proxy!.host.isEmpty ||
            proxy!.fragment.isNotEmpty ||
            proxy!.query.isNotEmpty ||
            (proxy!.path.isNotEmpty && proxy!.path != '/'))) {
      throw ArgumentError.value(proxy, 'proxy', 'Expected an HTTP proxy URL');
    }
    _client = native.clientCreate();
    if (_client == nullptr) {
      throw StateError('Unable to initialize the native HTTP backend');
    }
    _finalizer.attach(this, _client.cast(), detach: this);
  }

  final EchResolver? resolver;
  final Uri? proxy;
  final Duration timeout;
  final Duration connectTimeout;

  /// Maximum delivered body bytes, after gzip decoding when enabled.
  final int maxResponseBytes;
  final int maxRequestBytes;
  final int maxConcurrentRequests;

  /// Automatically decodes responses whose Content-Encoding is gzip.
  ///
  /// Like dart:io HttpClient, this leaves response headers and their compressed
  /// Content-Length unchanged. It does not disable gzip request negotiation.
  final bool autoUncompress;

  /// Replaces the bundled Mozilla CA roots for this client, e.g. for private PKI.
  final String? trustedRootsPem;
  static final _finalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(Pointer<native.NativeClient>)>
        >(native.clientDestroy)
        .cast(),
  );
  late Pointer<native.NativeClient> _client;
  final Set<_Transfer> _transfers = {};
  final Set<_Operation> _operations = {};
  final List<Completer<void>> _waiting = [];
  int _active = 0;
  bool _closed = false;

  static String get backendVersion => native.nativeVersion().toDartString();

  @override
  Future<EchResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('Client is closed', request.url);
    _validateUrl(request.url);
    final operation = _Operation();
    _operations.add(operation);
    if (request is http.Abortable) {
      unawaited(
        request.abortTrigger?.then(
          (_) => operation.cancel(http.RequestAbortedException(request.url)),
          onError: (Object _, StackTrace _) =>
              operation.cancel(http.RequestAbortedException(request.url)),
        ),
      );
    }
    try {
      return await _send(request, operation);
    } finally {
      _operations.remove(operation);
    }
  }

  Future<EchResponse> _send(
    http.BaseRequest request,
    _Operation operation,
  ) async {
    final body = BytesBuilder(copy: false);
    final upload = StreamIterator(request.finalize());
    try {
      while (await operation.race(upload.moveNext())) {
        final chunk = upload.current;
        if (body.length + chunk.length > maxRequestBytes) {
          throw http.ClientException(
            'Upload exceeds maxRequestBytes',
            request.url,
          );
        }
        body.add(chunk);
      }
    } finally {
      unawaited(upload.cancel());
    }
    var bytes = body.takeBytes();
    var uri = request.url;
    var method = request.method;
    var headers = Map<String, String>.of(request.headers);
    if (!headers.keys.any((key) => key.toLowerCase() == 'accept-encoding')) {
      headers['accept-encoding'] = 'gzip';
    }
    for (var redirects = 0; ; redirects++) {
      if (_closed) throw http.ClientException('Client is closed', uri);
      operation.check();
      final route = uri.scheme == 'https' && resolver != null
          ? await operation.race(resolver!.resolve(uri))
          : null;
      final response = await _sendWithRoute(
        request,
        uri,
        method,
        headers,
        bytes,
        route,
        operation,
      );
      final location = response.headers['location'];
      if (!request.followRedirects ||
          !response.isRedirect ||
          location == null) {
        return response;
      }
      await response.stream.drain<void>();
      if (redirects >= request.maxRedirects) {
        throw http.ClientException('Too many redirects', uri);
      }
      final next = uri.resolve(location);
      _validateUrl(next);
      if (uri.scheme == 'https' && next.scheme != 'https') {
        throw http.ClientException('HTTPS downgrade redirect refused', next);
      }
      if (uri.origin != next.origin) {
        headers.removeWhere(
          (key, _) => {
            'authorization',
            'cookie',
            'proxy-authorization',
            'host',
          }.contains(key.toLowerCase()),
        );
      }
      if ((response.statusCode == 303 && method != 'HEAD') ||
          ((response.statusCode == 301 || response.statusCode == 302) &&
              method == 'POST')) {
        method = 'GET';
        bytes = Uint8List(0);
        headers.removeWhere(
          (key, _) => {
            'content-length',
            'content-type',
            'transfer-encoding',
          }.contains(key.toLowerCase()),
        );
      }
      uri = next;
    }
  }

  Future<EchResponse> _sendWithRoute(
    http.BaseRequest original,
    Uri uri,
    String method,
    Map<String, String> headers,
    Uint8List body,
    EchRoute? route,
    _Operation operation,
  ) async {
    final addresses = route == null || route.addresses.isEmpty
        ? ['']
        : route.addresses;
    Object? lastError;
    for (final address in addresses) {
      await _acquire(uri, operation);
      if (_closed) {
        _release();
        throw http.ClientException('Client is closed', uri);
      }
      _Transfer? transfer;
      try {
        operation.check();
        transfer = _Transfer(
          this,
          original,
          uri,
          method,
          headers,
          body,
          route,
          address,
        );
        _transfers.add(transfer);
        final activeTransfer = transfer;
        unawaited(
          operation.stopped.then((error) => activeTransfer.cancel(error)),
        );
        return await transfer.response.future;
      } catch (error) {
        if (transfer == null) _release();
        if (error is! EchException) rethrow;
        if (method != 'GET' && method != 'HEAD') rethrow;
        lastError = error;
        // Only replay GET/HEAD, and only before receiving response headers.
      }
    }
    throw lastError ?? EchException('No usable destination', uri: uri);
  }

  Future<void> _acquire(Uri uri, _Operation operation) async {
    if (_closed) throw http.ClientException('Client is closed', uri);
    operation.check();
    if (_active < maxConcurrentRequests) {
      _active++;
      return;
    }
    final ready = Completer<void>();
    _waiting.add(ready);
    try {
      await operation.race(ready.future);
    } catch (_) {
      // If a slot was handed to us during cancellation, pass it on.
      if (!_waiting.remove(ready) && !_closed) _release();
      rethrow;
    }
  }

  void _release() {
    if (_waiting.isNotEmpty && !_closed) {
      _waiting.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  void _finished(_Transfer transfer) {
    _transfers.remove(transfer);
    _release();
  }

  static void _validateUrl(Uri uri) {
    if (!{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(
        uri,
        'url',
        'Expected an HTTP(S) URL without embedded credentials',
      );
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final operation in _operations) {
      operation.cancel(http.ClientException('Client is closed'));
    }
    for (final waiter in _waiting) {
      waiter.completeError(http.ClientException('Client is closed'));
    }
    _waiting.clear();
    for (final transfer in _transfers.toList()) {
      transfer.cancel(http.ClientException('Client is closed', transfer.uri));
    }
    _finalizer.detach(this);
    native.clientDestroy(_client);
    _client = nullptr;
  }
}

final class _Operation {
  final _stopped = Completer<Object>();
  Object? _reason;
  Future<Object> get stopped => _stopped.future;
  void cancel(Object reason) {
    if (_reason != null) return;
    _reason = reason;
    _stopped.complete(reason);
  }

  void check() {
    if (_reason case final reason?) throw reason;
  }

  Future<T> race<T>(Future<T> future) {
    return Future.any([future, stopped.then<T>((reason) => throw reason)]).then(
      (value) {
        check();
        return value;
      },
    );
  }
}

final class _Transfer implements Finalizable {
  _Transfer(
    this.client,
    this.original,
    this.uri,
    String method,
    Map<String, String> headers,
    Uint8List bytes,
    EchRoute? route,
    String address,
  ) {
    if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(method)) {
      throw ArgumentError.value(method, 'method');
    }
    for (final entry in headers.entries) {
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key) ||
          entry.value.contains(RegExp(r'[\r\n\x00]'))) {
        throw ArgumentError('Invalid HTTP header');
      }
    }
    events = ReceivePort('ech_http response');
    subscription = events.listen(_onEvent);
    body = StreamController<List<int>>(
      onListen: _updateDelivery,
      onPause: _updateDelivery,
      onResume: _updateDelivery,
      onCancel: () => _finish(null),
    );
    try {
      pointer = using((arena) {
        final opts = arena<native.NativeOptions>();
        opts.ref
          ..url = uri.toString().toNativeUtf8(allocator: arena)
          ..method = method.toNativeUtf8(allocator: arena)
          ..headers = headers.entries
              .where(
                (e) => !{
                  'content-length',
                  'transfer-encoding',
                }.contains(e.key.toLowerCase()),
              )
              .map(
                (e) => e.value.isEmpty ? '${e.key};' : '${e.key}: ${e.value}',
              )
              .join('\r\n')
              .toNativeUtf8(allocator: arena)
          ..proxy = (client.proxy?.toString() ?? '').toNativeUtf8(
            allocator: arena,
          )
          ..echConfig = (route?.configList ?? '').toNativeUtf8(allocator: arena)
          ..connectIp = address.toNativeUtf8(allocator: arena)
          ..caPem = (client.trustedRootsPem ?? '').toNativeUtf8(
            allocator: arena,
          )
          ..bodyLength = bytes.length
          ..timeoutMs = client.timeout.inMilliseconds
          ..connectTimeoutMs = client.connectTimeout.inMilliseconds
          ..maxResponseBytes = client.maxResponseBytes
          ..autoUncompress = client.autoUncompress;
        if (bytes.isNotEmpty) {
          opts.ref.body = arena<Uint8>(bytes.length);
          opts.ref.body.asTypedList(bytes.length).setAll(0, bytes);
        }
        return native.requestStart(
          client._client,
          opts,
          NativeApi.postCObject,
          events.sendPort.nativePort,
        );
      });
      if (pointer == nullptr) {
        throw StateError('Unable to start native request');
      }
      _finalizer.attach(this, pointer.cast(), detach: this);
    } catch (_) {
      events.close();
      unawaited(subscription.cancel());
      unawaited(body.close());
      if (pointer != nullptr) native.requestDestroy(pointer);
      rethrow;
    }
  }

  final EchClient client;
  final http.BaseRequest original;
  final Uri uri;
  final Completer<EchResponse> response = Completer();
  static final _finalizer = NativeFinalizer(
    Native.addressOf<
          NativeFunction<Void Function(Pointer<native.NativeRequest>)>
        >(native.requestDestroy)
        .cast(),
  );
  Pointer<native.NativeRequest> pointer = nullptr;
  late final StreamController<List<int>> body;
  late final ReceivePort events;
  late final StreamSubscription<Object?> subscription;
  bool done = false;
  bool deliveryPaused = false;

  void cancel(Object reason) => _finish(reason);

  void _updateDelivery() {
    if (done) return;
    // Pausing port delivery withholds acknowledgements and bounds native output.
    final shouldPause =
        response.isCompleted && (!body.hasListener || body.isPaused);
    if (shouldPause == deliveryPaused) return;
    deliveryPaused = shouldPause;
    if (shouldPause) {
      subscription.pause();
    } else {
      subscription.resume();
    }
  }

  void _onEvent(Object? message) {
    if (done) return;
    final event = message as List<Object?>;
    final type = event[0] as int;
    final code = event[1] as int;
    final data = event[4] as Uint8List;
    if (type == 1) {
      final lines = latin1.decode(data).split('\r\n');
      final headers = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon <= 0) continue;
        final key = line.substring(0, colon).trim().toLowerCase();
        final text = line.substring(colon + 1).trim();
        headers.update(
          key,
          (previous) => '$previous, $text',
          ifAbsent: () => text,
        );
      }
      response.complete(
        EchResponse(
          body.stream,
          code,
          echAccepted: event[2] != 0,
          echRetries: event[3] as int,
          compressionState: headers['content-encoding'] == 'gzip'
              ? (client.autoUncompress
                    ? HttpClientResponseCompressionState.decompressed
                    : HttpClientResponseCompressionState.compressed)
              : HttpClientResponseCompressionState.notCompressed,
          contentLength: int.tryParse(headers['content-length'] ?? ''),
          request: original,
          headers: headers,
          isRedirect: const {301, 302, 303, 307, 308}.contains(code),
          reasonPhrase: lines.first.split(' ').skip(2).join(' '),
        ),
      );
      _updateDelivery();
    } else if (type == 2) {
      body.add(data);
      native.requestAcknowledge(pointer, data.length);
    } else if (type == 3 || type == 4) {
      _finish(
        type == 4
            ? EchException(
                utf8.decode(data, allowMalformed: true),
                uri: uri,
                nativeCode: code,
              )
            : null,
      );
    }
  }

  void _finish(Object? error) {
    if (done) return;
    done = true;
    events.close();
    unawaited(subscription.cancel());
    _finalizer.detach(this);
    native.requestDestroy(pointer);
    pointer = nullptr;
    client._finished(this);
    if (!response.isCompleted) {
      response.completeError(
        error ?? EchException('Response ended without headers', uri: uri),
      );
    } else if (error != null) {
      body.addError(error);
    }
    unawaited(body.close());
  }
}
