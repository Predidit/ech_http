import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'types.dart';

/// Discovers ECHConfigList and addresses through a DNS JSON HTTPS endpoint.
///
/// [client] is supplied by the caller so bootstrap DNS uses the intended proxy
/// and trust policy. The resolver never closes it. Use a separate client without
/// this resolver to avoid recursive resolution.
///
/// [configDomains] explicitly opts hosts into borrowing another host's ECH
/// configuration. This is provider-specific behavior, not guaranteed by ECH.
/// IP hints of a borrowed configuration are never used for the original host.
final class DohEchResolver implements EchResolver {
  DohEchResolver({
    required this.client,
    required this.endpoint,
    required Set<String> hosts,
    Map<String, String> configDomains = const {},
    Map<String, List<String>> addressOverrides = const {},
    this.maxCacheAge = const Duration(minutes: 5),
  }) : hosts = Set.unmodifiable(hosts.map((h) => h.toLowerCase())),
       configDomains = Map.unmodifiable(
         configDomains.map(
           (k, v) => MapEntry(k.toLowerCase(), v.toLowerCase()),
         ),
       ),
       addressOverrides = Map.unmodifiable(
         addressOverrides.map(
           (k, v) => MapEntry(k.toLowerCase(), List<String>.unmodifiable(v)),
         ),
       ) {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'DoH requires an HTTPS endpoint',
      );
    }
    if (maxCacheAge.isNegative) {
      throw ArgumentError.value(maxCacheAge, 'maxCacheAge');
    }
  }

  final http.Client client;
  final Uri endpoint;
  final Set<String> hosts;
  final Map<String, String> configDomains;
  final Map<String, List<String>> addressOverrides;
  final Duration maxCacheAge;
  final Map<String, ({EchRoute route, DateTime expires})> _cache = {};
  final Map<String, Future<EchRoute>> _pending = {};

  /// Removes cached configurations, for example after changing networks.
  void clearCache() => _cache.clear();

  @override
  Future<EchRoute?> resolve(Uri uri) async {
    final host = uri.host.toLowerCase();
    if (!hosts.contains(host)) return null;
    if (uri.scheme != 'https' || uri.port != 443) {
      throw EchException(
        'DoH discovery currently supports HTTPS on port 443',
        uri: uri,
      );
    }
    final cached = _cache[host];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return cached.route;
    }
    final pending = _pending[host];
    if (pending != null) return pending;
    final future = _load(host, uri);
    _pending[host] = future;
    try {
      return await future;
    } finally {
      if (identical(_pending[host], future)) _pending.remove(host);
    }
  }

  Future<EchRoute> _load(String host, Uri uri) async {
    final configHost = configDomains[host] ?? host;
    final records = await _query(configHost, 65);
    String? config;
    final hints = <String>[];
    var ttl = maxCacheAge.inSeconds;
    for (final record in records) {
      if (record['type'] != 65) continue;
      final data = record['data'];
      if (data is! String) continue;
      final match = RegExp(r'(?:^|\s)ech="?([A-Za-z0-9+/=]+)').firstMatch(data);
      if (match == null) continue;
      config = match.group(1);
      ttl = math.min(ttl, (record['TTL'] as num?)?.toInt() ?? 0);
      if (configHost == host) {
        for (final key in ['ipv4hint', 'ipv6hint']) {
          final hint = RegExp('(?:^|\\s)$key="?([^"\\s]+)').firstMatch(data);
          if (hint != null) hints.addAll(hint.group(1)!.split(','));
        }
      }
      break;
    }
    if (config == null) {
      throw EchException(
        'No ECHConfigList published for $configHost',
        uri: uri,
      );
    }
    var addresses = addressOverrides[host] ?? hints;
    if (addresses.isEmpty) {
      final answers = await _query(host, 1);
      addresses = [];
      for (final rr in answers) {
        if (rr['type'] == 1 && rr['data'] is String) {
          addresses.add(rr['data'] as String);
          ttl = math.min(ttl, (rr['TTL'] as num?)?.toInt() ?? 0);
        }
      }
    }
    if (addresses.isEmpty) {
      throw EchException('No destination addresses for $host', uri: uri);
    }
    final route = EchRoute(configList: config, addresses: addresses);
    _cache[host] = (
      route: route,
      expires: DateTime.now().add(Duration(seconds: math.max(ttl, 0))),
    );
    return route;
  }

  Future<List<Map<String, dynamic>>> _query(String host, int type) async {
    final uri = endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'name': host,
        'type': '$type',
      },
    );
    final response = await client.send(
      http.Request('GET', uri)..headers['accept'] = 'application/dns-json',
    );
    if (response.statusCode != 200) {
      await response.stream.listen(null).cancel();
      throw EchException('DoH returned HTTP ${response.statusCode}', uri: uri);
    }
    final chunks = <int>[];
    await for (final chunk in response.stream) {
      if (chunks.length + chunk.length > 1024 * 1024) {
        throw EchException('DoH response exceeds 1 MiB', uri: uri);
      }
      chunks.addAll(chunk);
    }
    final decoded = jsonDecode(utf8.decode(chunks));
    if (decoded is! Map<String, dynamic> || decoded['Status'] != 0) {
      throw EchException('DoH returned an unsuccessful DNS response', uri: uri);
    }
    return (decoded['Answer'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }
}
