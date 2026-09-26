import 'dart:async';
import 'dart:isolate';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args, SendPort parent) async {
  final client = EchClient(timeout: const Duration(seconds: 60));
  final response = await client.send(
    http.Request('GET', Uri.parse(args.single)),
  );
  parent.send(response.statusCode);
  // Leave cleanup to native finalizers when the parent kills this isolate group.
  await Completer<void>().future;
}
