import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// An ECH configuration and optional destination IPs for one HTTPS authority.
///
/// IP overrides change the TCP/CONNECT destination, never the TLS identity or
/// HTTP Host. The connection fails if the server does not accept ECH.
final class EchRoute {
  EchRoute({required String configList, List<String> addresses = const []})
    : configList = _validateConfig(configList),
      addresses = List.unmodifiable(addresses.map(_validateAddress));

  final String configList;
  final List<String> addresses;

  static String _validateConfig(String value) {
    final bytes = base64.decode(value);
    if (bytes.length < 6 ||
        ByteData.sublistView(bytes).getUint16(0) != bytes.length - 2) {
      throw ArgumentError.value(
        value,
        'configList',
        'Invalid ECHConfigList framing',
      );
    }
    return base64.encode(bytes);
  }

  static String _validateAddress(String address) {
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null) {
      throw ArgumentError.value(address, 'addresses', 'Expected an IP literal');
    }
    return parsed.address;
  }
}

/// Selects required ECH for an HTTPS request. Null selects ordinary verified TLS.
abstract interface class EchResolver {
  Future<EchRoute?> resolve(Uri uri);
}

/// Supplies explicit configurations without any DNS requests.
final class StaticEchResolver implements EchResolver {
  StaticEchResolver(Map<String, EchRoute> routes)
    : routes = Map.unmodifiable(
        routes.map((k, v) => MapEntry(k.toLowerCase(), v)),
      );
  final Map<String, EchRoute> routes;

  @override
  Future<EchRoute?> resolve(Uri uri) async => routes[uri.host.toLowerCase()];
}

/// Transport details reported by the native TLS implementation.
final class EchResponse extends http.StreamedResponse {
  EchResponse(
    super.stream,
    super.statusCode, {
    required this.echAccepted,
    required this.echRetries,
    this.compressionState = HttpClientResponseCompressionState.notCompressed,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.reasonPhrase,
  });
  final bool echAccepted;
  final int echRetries;

  /// Whether gzip decoding was selected, following dart:io HttpClient.
  ///
  /// Headers and [contentLength] describe the encoded response on the wire,
  /// even when [stream] delivers decoded bytes. For a buffered http.Response,
  /// contentLength instead equals its bodyBytes.length, as in package:http.
  final HttpClientResponseCompressionState compressionState;
}

/// A native transport failure, distinct from an HTTP error status response.
final class EchException extends http.ClientException {
  EchException(String message, {Uri? uri, this.nativeCode})
    : super(message, uri);
  final int? nativeCode;

  @override
  String toString() =>
      'EchException${nativeCode == null ? '' : ' ($nativeCode)'}: $message${uri == null ? '' : ', uri=$uri'}';
}
