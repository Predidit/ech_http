// Creates a disposable Flutter consumer to verify automatic native bundling.
import 'dart:io';

Future<void> main() async {
  final root = Directory.current.absolute.path;
  final app = Directory('build/flutter_smoke').absolute;
  final create = await Process.run('flutter', [
    'create',
    '--no-pub',
    '--platforms=android,ios,macos,windows,linux',
    '--project-name=ech_http_smoke',
    app.path,
  ], runInShell: Platform.isWindows);
  if (create.exitCode != 0) {
    throw StateError('${create.stdout}\n${create.stderr}');
  }
  final packagePath = root.replaceAll('\\', '/').replaceAll("'", "''");
  await File('${app.path}/pubspec.yaml').writeAsString('''
name: ech_http_smoke
publish_to: none
environment:
  sdk: '>=3.10.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  ech_http:
    path: '$packagePath'
''');
  await File('${app.path}/lib/main.dart').writeAsString('''
import 'package:flutter/material.dart';
import 'package:ech_http/ech_http.dart';

void main() {
  final client = EchClient();
  final result = client.get(Uri.https('example.com')).then((r) {
    client.close();
    return '\${EchClient.backendVersion}: HTTP \${r.statusCode}';
  }, onError: (Object error) { client.close(); return error.toString(); });
  runApp(MaterialApp(home: Scaffold(body: Center(child: FutureBuilder(
    future: result,
    builder: (context, snapshot) => Text(snapshot.data ?? 'Loading'),
  )))));
}
''');
  // The generated counter-widget test no longer describes this consumer.
  final counterTest = File('${app.path}/test/widget_test.dart');
  if (await counterTest.exists()) await counterTest.delete();
  stdout.writeln(
    'Created ${app.path}. Run flutter pub get and flutter build <target> there.',
  );
}
