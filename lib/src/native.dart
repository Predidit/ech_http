// C ABI declarations corresponding to src/ech_http.h.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _asset = 'package:ech_http/ech_http_bindings';

final class NativeClient extends Opaque {}

final class NativeRequest extends Opaque {}

final class NativeOptions extends Struct {
  external Pointer<Utf8> url;
  external Pointer<Utf8> method;
  external Pointer<Utf8> headers;
  external Pointer<Utf8> proxy;
  external Pointer<Utf8> echConfig;
  external Pointer<Utf8> connectIp;
  external Pointer<Utf8> caPem;
  external Pointer<Uint8> body;
  @Size()
  external int bodyLength;
  @Int64()
  external int timeoutMs;
  @Int64()
  external int connectTimeoutMs;
  @Int64()
  external int maxResponseBytes;
}

final class NativeEvent extends Struct {
  @Int32()
  external int type;
  @Int32()
  external int code;
  @Int32()
  external int echAccepted;
  @Int32()
  external int echRetries;
  @Size()
  external int length;
  external Pointer<Uint8> data;
}

@Native<Pointer<Utf8> Function()>(symbol: 'eh_version', assetId: _asset)
external Pointer<Utf8> nativeVersion();
@Native<Pointer<NativeClient> Function()>(
  symbol: 'eh_client_create',
  assetId: _asset,
)
external Pointer<NativeClient> clientCreate();
@Native<Void Function(Pointer<NativeClient>)>(
  symbol: 'eh_client_destroy',
  assetId: _asset,
)
external void clientDestroy(Pointer<NativeClient> client);
@Native<
  Pointer<NativeRequest> Function(Pointer<NativeClient>, Pointer<NativeOptions>)
>(symbol: 'eh_request_start', assetId: _asset)
external Pointer<NativeRequest> requestStart(
  Pointer<NativeClient> client,
  Pointer<NativeOptions> options,
);
@Native<Pointer<NativeEvent> Function(Pointer<NativeRequest>)>(
  symbol: 'eh_request_poll',
  assetId: _asset,
)
external Pointer<NativeEvent> requestPoll(Pointer<NativeRequest> request);
@Native<Void Function(Pointer<NativeRequest>)>(
  symbol: 'eh_request_cancel',
  assetId: _asset,
)
external void requestCancel(Pointer<NativeRequest> request);
@Native<Void Function(Pointer<NativeRequest>)>(
  symbol: 'eh_request_destroy',
  assetId: _asset,
)
external void requestDestroy(Pointer<NativeRequest> request);
@Native<Void Function(Pointer<NativeEvent>)>(
  symbol: 'eh_event_destroy',
  assetId: _asset,
)
external void eventDestroy(Pointer<NativeEvent> event);
