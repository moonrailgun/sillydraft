import 'dart:convert';

import 'provider.dart';

/// SSE frames, independent of transport packet/UTF-8 boundaries.
Stream<String> decodeSse(
  Stream<List<int>> stream, {
  int maxFrameLength = 2 * 1024 * 1024,
}) async* {
  final data = <String>[];
  var size = 0;
  await for (final line
      in stream.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield data.join('\n');
      data.clear();
      size = 0;
      continue;
    }
    if (line.startsWith('data:')) {
      final part = line.substring(line.startsWith('data: ') ? 6 : 5);
      size += part.length;
      if (size > maxFrameLength) {
        throw const ProviderException('frame_limit', '模型响应帧超过大小限制');
      }
      data.add(part);
    }
  }
  // A final frame may omit its empty separator; the protocol adapter still
  // requires an explicit finish reason rather than treating EOF as success.
  if (data.isNotEmpty) yield data.join('\n');
}
