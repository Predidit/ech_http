import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:ech_http/src/build_support/prebuilt.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _revision = 'cff1385e77b9b2095558fa625b3c35d589ffe09b';

List<int> _sdk({
  String target = 'windows-x64',
  String revision = _revision,
  Map<String, String> extra = const {},
  bool omitCrypto = false,
}) {
  final files = <String, String>{
    'cmake/EchHttpDeps.cmake': 'verified cmake',
    'include/curl/curl.h': 'curl header',
    'include/openssl/ssl.h': 'ssl header',
    'lib/curl.lib': 'curl static library',
    'lib/ssl.lib': 'ssl static library',
    if (!omitCrypto) 'lib/crypto.lib': 'crypto static library',
    ...extra,
  };
  final archive = Archive();
  for (final file in files.entries) {
    final bytes = utf8.encode(file.value);
    archive.addFile(ArchiveFile(file.key, bytes.length, bytes));
  }
  final metadata = utf8.encode(
    jsonEncode({
      'schema': 1,
      'target': target,
      'release': 'v0.1.0',
      'curl': {'version': '8.22.0'},
      'boringssl': {'revision': revision},
      'files': {
        for (final file in files.entries)
          file.key: sha256.convert(utf8.encode(file.value)).toString(),
      },
    }),
  );
  archive.addFile(ArchiveFile('metadata.json', metadata.length, metadata));
  return ZipEncoder().encode(archive);
}

PrebuiltDependency _pin(List<int> bytes) => PrebuiltDependency(
  target: 'windows-x64',
  release: 'v0.1.0',
  url: Uri.https('example.test', '/dependency.zip'),
  digest: sha256.convert(bytes).toString(),
  curlVersion: '8.22.0',
  boringRevision: _revision,
);

void main() {
  late Directory cache;
  setUp(() async => cache = await Directory.systemTemp.createTemp('ech-sdk-'));
  tearDown(() async => cache.delete(recursive: true));

  test('iOS device and simulator SDKs have distinct cache targets', () {
    expect(dependencyTarget(OS.windows, Architecture.x64), 'windows-x64');
    expect(
      dependencyTarget(OS.iOS, Architecture.arm64, iosSdk: IOSSdk.iPhoneOS),
      'ios-arm64-device',
    );
    expect(
      dependencyTarget(
        OS.iOS,
        Architecture.arm64,
        iosSdk: IOSSdk.iPhoneSimulator,
      ),
      'ios-arm64-simulator',
    );
  });

  test(
    'verified SDK works offline and repairs modified extracted libraries',
    () async {
      final bytes = _sdk();
      final pin = _pin(bytes);
      var downloads = 0;
      Future<void> download(Uri _, File file) async {
        downloads++;
        await file.writeAsBytes(bytes);
      }

      final sdk = await preparePrebuilt(pin, cache.path, download: download);
      final library = File(p.join(sdk, 'lib', 'curl.lib'));
      await library.writeAsString('tampered');
      expect(await preparePrebuilt(pin, cache.path, download: download), sdk);
      expect(await library.readAsString(), 'curl static library');
      expect(downloads, 1);
      await preparePrebuilt(
        pin,
        cache.path,
        download: (_, _) =>
            throw StateError('Offline cache must not contact the network'),
      );
    },
  );

  test(
    'corrupt cached archive is replaced only by a matching download',
    () async {
      final bytes = _sdk();
      final pin = _pin(bytes);
      var downloads = 0;
      Future<void> download(Uri _, File file) async {
        downloads++;
        await file.writeAsBytes(bytes);
      }

      await preparePrebuilt(pin, cache.path, download: download);
      final zip = File(p.join(cache.path, '${pin.target}-${pin.digest}.zip'));
      await zip.writeAsString('truncated');
      await preparePrebuilt(pin, cache.path, download: download);
      expect(downloads, 2);
      expect(sha256.convert(await zip.readAsBytes()).toString(), pin.digest);
    },
  );

  test(
    'mismatched download is rejected and partial bytes are removed',
    () async {
      await expectLater(
        preparePrebuilt(
          _pin(_sdk()),
          cache.path,
          download: (_, file) async {
            await file.writeAsString('untrusted bytes');
          },
        ),
        throwsStateError,
      );
      expect(
        await cache
            .list()
            .where((file) => !file.path.endsWith('.lock'))
            .toList(),
        isEmpty,
      );
    },
  );

  for (final mismatch in [
    ('wrong architecture', _sdk(target: 'windows-arm64')),
    ('wrong BoringSSL revision', _sdk(revision: '0' * 40)),
    ('missing static library', _sdk(omitCrypto: true)),
    ('path traversal', _sdk(extra: {'../escaped.txt': 'escape'})),
    ('Windows absolute path', _sdk(extra: {'C:/escaped.txt': 'escape'})),
  ]) {
    test('rejects ${mismatch.$1} even with a matching archive hash', () async {
      await expectLater(
        preparePrebuilt(
          _pin(mismatch.$2),
          cache.path,
          download: (_, file) async {
            await file.writeAsBytes(mismatch.$2);
          },
        ),
        throwsStateError,
      );
      expect(
        await Directory(
          cache.path,
        ).list().where((e) => e is Directory).toList(),
        isEmpty,
      );
    });
  }
}
