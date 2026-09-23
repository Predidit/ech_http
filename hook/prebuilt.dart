import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

String dependencyTarget(OS os, Architecture architecture, {IOSSdk? iosSdk}) {
  final base = '$os-$architecture';
  if (os == OS.iOS) {
    if (iosSdk == null) throw ArgumentError('iOS SDK is required');
    return '$base-${iosSdk == IOSSdk.iPhoneOS ? 'device' : 'simulator'}';
  }
  return base;
}

/// Integrity pins come from the package, never a mutable remote checksum file.
final class PrebuiltDependency {
  PrebuiltDependency({
    required this.target,
    required this.release,
    required this.url,
    required this.digest,
    required this.curlVersion,
    required this.boringRevision,
  }) {
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(target) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty) {
      throw ArgumentError('Invalid prebuilt dependency pin');
    }
  }

  factory PrebuiltDependency.fromManifest(
    Map<String, dynamic> manifest,
    String target,
  ) {
    final entry = (manifest['targets'] as Map<String, dynamic>)[target];
    if (entry is! Map<String, dynamic>) {
      throw UnsupportedError('No prebuilt ech_http dependency SDK for $target');
    }
    return PrebuiltDependency(
      target: target,
      release: entry['release'] as String,
      url: Uri.parse(entry['url'] as String),
      digest: entry['sha256'] as String,
      curlVersion: manifest['curl']['version'] as String,
      boringRevision: manifest['boringssl']['revision'] as String,
    );
  }

  final String target, release, digest, curlVersion, boringRevision;
  final Uri url;
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

String _safePath(String root, String name) {
  if (name.isEmpty ||
      name.contains('\\') ||
      name.contains(':') ||
      p.posix.isAbsolute(name) ||
      name.split('/').any((part) => part == '..' || part == '.')) {
    throw StateError('Unsafe dependency archive path: $name');
  }
  final path = p.normalize(p.join(root, name));
  if (!p.isWithin(root, path)) {
    throw StateError('Dependency archive escapes its cache directory');
  }
  return path;
}

Future<bool> _matches(
  String directory,
  Map<String, dynamic> hashes,
  List<int> metadataBytes,
) async {
  if (await FileSystemEntity.type(directory, followLinks: false) !=
      FileSystemEntityType.directory) {
    return false;
  }
  await for (final entry in Directory(
    directory,
  ).list(recursive: true, followLinks: false)) {
    if (entry is Link) return false;
  }
  for (final entry in hashes.entries) {
    final file = File(_safePath(directory, entry.key));
    if (!await file.exists() || await _hash(file) != entry.value) return false;
  }
  final metadata = File(p.join(directory, 'metadata.json'));
  return await metadata.exists() &&
      await _hash(metadata) == sha256.convert(metadataBytes).toString();
}

/// Rechecks cached ZIPs and extracted files; a partial/modified cache is repaired.
Future<String> preparePrebuilt(
  PrebuiltDependency dependency,
  String cache, {
  Future<void> Function(Uri, File)? download,
}) async {
  cache = p.normalize(p.absolute(cache));
  await Directory(cache).create(recursive: true);
  final key = '${dependency.target}-${dependency.digest}';
  final lock = await File(
    p.join(cache, '$key.lock'),
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.blockingExclusive);
    final archiveFile = File(p.join(cache, '$key.zip'));
    if (!await archiveFile.exists() ||
        await _hash(archiveFile) != dependency.digest) {
      stderr.writeln(
        'ech_http: downloading dependency SDK ${dependency.target}',
      );
      final partial = File('${archiveFile.path}.part');
      try {
        await (download ?? _download)(dependency.url, partial);
        if (await _hash(partial) != dependency.digest) {
          throw StateError('ech_http dependency archive SHA-256 mismatch');
        }
        if (await archiveFile.exists()) await archiveFile.delete();
        await partial.rename(archiveFile.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    final archive = ZipDecoder().decodeBytes(await archiveFile.readAsBytes());
    final directory = p.join(cache, key);
    var unpackedBytes = 0;
    for (final entry in archive) {
      _safePath(directory, entry.name);
      if (entry.isSymbolicLink) {
        throw StateError('Dependency archive contains a symbolic link');
      }
      unpackedBytes += entry.size;
      if (unpackedBytes > 256 * 1024 * 1024) {
        throw StateError('Dependency archive exceeds the size limit');
      }
    }
    final metadataBytes = archive.find('metadata.json')?.readBytes();
    if (metadataBytes == null) throw StateError('Missing SDK metadata');
    final metadata =
        jsonDecode(utf8.decode(metadataBytes)) as Map<String, dynamic>;
    if (metadata['schema'] != 1 ||
        metadata['release'] != dependency.release ||
        metadata['target'] != dependency.target ||
        metadata['curl']['version'] != dependency.curlVersion ||
        metadata['boringssl']['revision'] != dependency.boringRevision) {
      throw StateError(
        'Dependency SDK metadata does not match the pinned target',
      );
    }
    final hashes = metadata['files'] as Map<String, dynamic>;
    final extension = dependency.target.startsWith('windows-') ? 'lib' : 'a';
    final prefix = extension == 'lib' ? '' : 'lib';
    for (final name in [
      'cmake/EchHttpDeps.cmake',
      'include/curl/curl.h',
      'include/openssl/ssl.h',
      for (final lib in ['curl', 'ssl', 'crypto']) 'lib/$prefix$lib.$extension',
    ]) {
      if (!hashes.containsKey(name)) throw StateError('Incomplete SDK: $name');
    }
    for (final entry in hashes.entries) {
      _safePath(directory, entry.key);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.value as String)) {
        throw StateError('Invalid file digest in SDK metadata');
      }
    }
    if (!await _matches(directory, hashes, metadataBytes)) {
      final staging = await Directory(cache).createTemp('.$key-');
      try {
        await extractArchiveToDisk(archive, staging.path);
        if (!await _matches(staging.path, hashes, metadataBytes)) {
          throw StateError('Dependency SDK file verification failed');
        }
        // Only this content-addressed directory, strictly inside our cache,
        // may be replaced. Never follow a link to a caller-owned directory.
        if (!p.isWithin(cache, directory)) {
          throw StateError('Invalid cache path');
        }
        final type = await FileSystemEntity.type(directory, followLinks: false);
        if (type == FileSystemEntityType.link) {
          throw StateError('Dependency cache directory must not be a symlink');
        }
        if (type == FileSystemEntityType.directory) {
          await Directory(directory).delete(recursive: true);
        }
        await staging.rename(directory);
      } finally {
        if (await staging.exists()) await staging.delete(recursive: true);
      }
    }
    return directory;
  } finally {
    await lock.unlock();
    await lock.close();
  }
}

Future<void> _download(Uri url, File destination) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  client.findProxy = HttpClient.findProxyFromEnvironment;
  try {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (url.scheme != 'https' || url.userInfo.isNotEmpty) {
        throw StateError(
          'Dependency downloads require HTTPS without credentials',
        );
      }
      final request = await client.getUrl(url);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) {
          throw StateError('Dependency redirect has no URL');
        }
        url = url.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Dependency download: HTTP ${response.statusCode}');
      }
      final sink = destination.openWrite();
      var received = 0;
      try {
        await for (final bytes in response.timeout(
          const Duration(seconds: 60),
        )) {
          received += bytes.length;
          if (received > 100 * 1024 * 1024) {
            throw StateError('Dependency download exceeds the size limit');
          }
          sink.add(bytes);
        }
      } finally {
        await sink.close();
      }
      return;
    }
    throw HttpException('Too many dependency download redirects');
  } finally {
    client.close(force: true);
  }
}
