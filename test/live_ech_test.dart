import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

// Explicit opt-in. No target, destination address or proxy is built into tests.
// See doc/releasing.md for the complete environment contract.
void main() {
  final proxyText = _environment('ECH_TEST_PROXY');
  final proxy = proxyText == null ? null : Uri.parse(proxyText);
  final trustUrl = _environment('ECH_TEST_TRUST_URL');
  final targetUrl = _environment('ECH_TEST_URL');
  test('custom roots replace rather than augment host trust stores', () async {
    final target = _httpsUrl(trustUrl!);
    final client = EchClient(
      proxy: proxy,
      trustedRootsPem: await File(
        'test/fixtures/localhost-cert.pem',
      ).readAsString(),
    );
    addTearDown(client.close);
    await expectLater(
      client.send(http.Request('GET', target)..followRedirects = false),
      throwsA(
        isA<EchException>().having(
          (e) => e.nativeCode,
          'certificate verification',
          60,
        ),
      ),
    );
  }, skip: trustUrl == null ? 'Set ECH_TEST_TRUST_URL to opt in' : false);
  test(
    'required ECH with optional authenticated retry and response integrity',
    () async {
      final target = _httpsUrl(targetUrl!);
      final config = _environment('ECH_TEST_CONFIG');
      expect(
        config,
        isNotNull,
        reason: 'ECH_TEST_URL requires ECH_TEST_CONFIG',
      );
      final addressText = _environment('ECH_TEST_ADDRESSES');
      final client = EchClient(
        proxy: proxy,
        resolver: StaticEchResolver({
          target.host: EchRoute(
            configList: config!,
            addresses: addressText == null
                ? const []
                : addressText.split(',').map((a) => a.trim()).toList(),
          ),
        }),
      );
      addTearDown(client.close);
      final response = await client.send(
        http.Request('GET', target)..followRedirects = false,
      );
      expect(response.statusCode, 200);
      expect(response.echAccepted, isTrue);
      if (_environment('ECH_TEST_EXPECT_RETRY') == '1') {
        expect(response.echRetries, greaterThan(0));
      }
      final bytes = await response.stream.toBytes();
      final expectedBytes = _environment('ECH_TEST_BYTES');
      if (expectedBytes != null) expect(bytes.length, int.parse(expectedBytes));
      final expectedHash = _environment('ECH_TEST_SHA256');
      if (expectedHash != null) {
        expect(expectedHash, matches(RegExp(r'^[a-fA-F0-9]{64}$')));
        expect(sha256.convert(bytes).toString(), expectedHash.toLowerCase());
      }
    },
    skip: targetUrl == null
        ? 'Set ECH_TEST_URL and ECH_TEST_CONFIG to opt in'
        : false,
  );
}

String? _environment(String name) {
  final value = Platform.environment[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

Uri _httpsUrl(String value) {
  final uri = Uri.parse(value);
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw ArgumentError('Live checks require HTTPS URLs without credentials');
  }
  return uri;
}
