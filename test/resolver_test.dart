import 'dart:async';
import 'dart:convert';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

const config =
    'AEX+DQBBDwAgACDH/iPbkA9gQKNYkBgsN7iK5HFPtVOJrMbQ3Ioehxz1NwAEAAEAAQASY2xvdWRmbGFyZS1lY2guY29tAAA=';

void main() {
  test('borrowing ECH never substitutes the configuration host IP', () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add(request.url.queryParameters['name']!);
      return http.Response(
        jsonEncode({
          'Status': 0,
          'Answer': [
            {
              'type': 65,
              'TTL': 300,
              'data': '1 . ech="$config" ipv4hint="192.0.2.1"',
            },
          ],
        }),
        200,
      );
    });
    final resolver = DohEchResolver(
      client: client,
      endpoint: Uri.https('resolver.test', '/resolve'),
      hosts: {'target.test'},
      configDomains: {'target.test': 'config.test'},
      addressOverrides: {
        'target.test': ['192.0.2.9'],
      },
    );
    final route = await resolver.resolve(Uri.https('target.test', '/'));
    expect(route!.addresses, ['192.0.2.9']);
    expect(seen, ['config.test']);
    expect(await resolver.resolve(Uri.https('unlisted.test', '/')), isNull);
  });

  test('coalesces concurrent DNS requests and caches by TTL', () async {
    var count = 0;
    final client = MockClient((request) async {
      count++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return http.Response(
        jsonEncode({
          'Status': 0,
          'Answer': [
            {
              'type': 65,
              'TTL': 300,
              'data': '1 . ech=$config ipv4hint=192.0.2.1',
            },
          ],
        }),
        200,
      );
    });
    final resolver = DohEchResolver(
      client: client,
      endpoint: Uri.https('resolver.test', '/resolve'),
      hosts: {'target.test'},
    );
    await Future.wait(
      List.generate(10, (_) => resolver.resolve(Uri.https('target.test'))),
    );
    await resolver.resolve(Uri.https('target.test'));
    expect(count, 1);
    resolver.clearCache();
    await resolver.resolve(Uri.https('target.test'));
    expect(count, 2);
  });

  test(
    'missing ECH fails rather than silently choosing ordinary TLS',
    () async {
      final resolver = DohEchResolver(
        client: MockClient(
          (_) async => http.Response('{"Status":0,"Answer":[]}', 200),
        ),
        endpoint: Uri.https('resolver.test', '/resolve'),
        hosts: {'target.test'},
      );
      await expectLater(
        resolver.resolve(Uri.https('target.test')),
        throwsA(isA<EchException>()),
      );
    },
  );

  test('invalid configuration framing and non-IP overrides are rejected', () {
    expect(() => EchRoute(configList: 'AAAA'), throwsArgumentError);
    expect(
      () => EchRoute(configList: config, addresses: ['example.com']),
      throwsArgumentError,
    );
  });
}
