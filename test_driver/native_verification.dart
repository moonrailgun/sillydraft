import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    if (data == null || data['captures'] is! Map) {
      throw StateError('Native verification did not return screenshots.');
    }
    final platform = data['platform'];
    if (!['android', 'ios', 'macos', 'windows', 'linux'].contains(platform)) {
      throw StateError('Unexpected verification platform.');
    }
    final output = Directory('docs/verification');
    await output.create(recursive: true);
    final captures = data['captures'] as Map;
    if (captures.isEmpty) throw StateError('No screenshots returned.');
    // Each target decides its screenshots and fails itself when one is missing.
    for (final MapEntry(key: name, value: encoded) in captures.entries) {
      if (encoded is! String) throw StateError('Missing $name screenshot.');
      final file = File('${output.path}/native-$platform-$name.png');
      await file.writeAsBytes(base64Decode(encoded));
      stdout.writeln('Verified screenshot: ${file.path}');
    }
  },
);
