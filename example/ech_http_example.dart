import 'dart:io';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;

/// Fetches a caller-selected HTTPS resource with required ECH.
///
/// Optional environment variables: ECH_PROXY, ECH_CONFIG_DOMAIN, ECH_ADDRESSES.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run example/ech_http_example.dart '
      '<https-url> <dns-json-https-endpoint>',
    );
    exitCode = 64;
    return;
  }
  final target = Uri.parse(arguments[0]);
  if (target.scheme != 'https' || target.host.isEmpty || target.port != 443) {
    throw ArgumentError('Discovery requires an HTTPS target on port 443');
  }
  final proxyText = _environment('ECH_PROXY');
  final proxy = proxyText == null ? null : Uri.parse(proxyText);
  final configDomain = _environment('ECH_CONFIG_DOMAIN');
  final addresses = _environment('ECH_ADDRESSES');
  final bootstrap = EchClient(proxy: proxy);
  EchClient? client;
  try {
    client = EchClient(
      proxy: proxy,
      resolver: DohEchResolver(
        client: bootstrap,
        endpoint: Uri.parse(arguments[1]),
        hosts: {target.host},
        configDomains: {target.host: ?configDomain},
        addressOverrides: {
          if (addresses != null)
            target.host: addresses.split(',').map((a) => a.trim()).toList(),
        },
      ),
    );
    print(EchClient.backendVersion);
    // Keep this example on the selected authority. Applications should apply
    // their own ECH policy to any redirect destination.
    final response = await client.send(
      http.Request('GET', target)..followRedirects = false,
    );
    print(
      'HTTP ${response.statusCode}, ECH accepted: ${response.echAccepted}, '
      'authenticated retries: ${response.echRetries}',
    );
    final bytes = await response.stream.fold<int>(
      0,
      (n, chunk) => n + chunk.length,
    );
    print('$bytes bytes received');
    if (!response.echAccepted || response.statusCode >= 400) exitCode = 1;
  } finally {
    client?.close();
    bootstrap.close();
  }
}

String? _environment(String name) {
  final value = Platform.environment[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}
