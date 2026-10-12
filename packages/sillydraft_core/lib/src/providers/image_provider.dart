import 'dart:typed_data';

import '../st/import_types.dart';
import 'provider.dart';

final class ImageRequest extends JsonSource {
  ImageRequest({
    required String prompt,
    Map<String, dynamic> parameters = const {},
    List<String> allowedDownloadHosts = const [],
  }) : super({
         'prompt': prompt,
         'parameters': parameters,
         'allowedDownloadHosts': allowedDownloadHosts,
       }) {
    if (prompt.trim().isEmpty || prompt.length > 32000) {
      throw const FormatException('图片提示词须为 1 到 32000 个字符');
    }
  }
  factory ImageRequest.fromJson(Map<String, dynamic> raw) => ImageRequest(
    prompt: raw['prompt'] as String,
    parameters: (raw['parameters'] as Map? ?? {}).cast<String, dynamic>(),
    allowedDownloadHosts: (raw['allowedDownloadHosts'] as List? ?? [])
        .cast<String>(),
  );
  String get prompt => raw['prompt'] as String;
  Map<String, dynamic> get parameters =>
      raw['parameters'] as Map<String, dynamic>;
  List<String> get allowedDownloadHosts =>
      (raw['allowedDownloadHosts'] as List).cast<String>();
}

final class ImageReference {
  ImageReference({required Uint8List bytes, required this.mimeType})
    : _bytes = Uint8List.fromList(bytes);
  final Uint8List _bytes;
  final String mimeType;
  Uint8List get bytes => Uint8List.fromList(_bytes);
}

final class GeneratedImage {
  GeneratedImage({
    required Uint8List bytes,
    this.revisedPrompt = '',
    Map<String, dynamic> usage = const {},
  }) : _bytes = Uint8List.fromList(bytes),
       _usage = JsonSource(usage);
  final Uint8List _bytes;
  final JsonSource _usage;
  final String revisedPrompt;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  Map<String, dynamic> get usage => _usage.raw;
}

abstract interface class ImageProvider {
  ModelConnection get config;
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  });
  void close();
}
