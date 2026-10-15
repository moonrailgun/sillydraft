import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../assets/asset_library.dart';
import '../providers/image_provider.dart';
import '../providers/provider.dart';
import '../st/import_types.dart';
import 'remote_session.dart';

Map<String, Object?> encodeProviderEvent(ProviderEvent event) =>
    switch (event) {
      TextDelta(:final text) => {'e': 'text', 't': text},
      ReasoningDelta(:final text) => {'e': 'reasoning', 't': text},
      ToolCallReady() => {
        'e': 'tool',
        'id': event.id,
        'name': event.name,
        'arguments': event.arguments,
      },
      GenerationFinished() => {
        'e': 'finish',
        'reason': event.reason,
        'usage': event.usage,
      },
    };

ProviderEvent decodeProviderEvent(Map<String, dynamic> json) =>
    switch (json['e']) {
      'text' => TextDelta(json['t'] as String),
      'reasoning' => ReasoningDelta(json['t'] as String),
      'tool' => ToolCallReady(
        json['id'] as String,
        json['name'] as String,
        jsonObject(json['arguments'], 'arguments'),
      ),
      'finish' => GenerationFinished(
        json['reason'] as String,
        usage: (json['usage'] as Map? ?? {}).cast<String, dynamic>(),
      ),
      _ => throw const FormatException('未知的模型事件'),
    };

/// The desktop's JSON lines for [path], heartbeats skipped and errors
/// raised as the provider raised them there.
Stream<Map<String, dynamic>> _desktopLines(
  RemoteSession session,
  String path,
  Object body,
  GenerationCancellation? cancellation,
) async* {
  cancellation?.check();
  final response = await session.send(
    'POST',
    path,
    json: body,
    cancellation: cancellation,
  );
  if (response.statusCode != 200) throw await RemoteRequestFailed.of(response);
  final lines = StreamIterator(
    response.transform(utf8.decoder).transform(const LineSplitter()),
  );
  // Aborting the request does nothing once the answer has begun; dropping
  // the stream hangs up, which the desktop notices at its next heartbeat.
  final cancelled = Completer<bool>();
  final unregister = cancellation?.onCancel(() => cancelled.complete(false));
  try {
    while (await Future.any([lines.moveNext(), cancelled.future])) {
      cancellation?.check();
      if (lines.current.isEmpty) continue;
      final json = jsonDecode(lines.current) as Map<String, dynamic>;
      if (json['e'] == 'error') {
        throw ProviderException(
          json['code'] as String,
          json['message'] as String,
          statusCode: json['status'] as int?,
        );
      }
      yield json;
    }
    cancellation?.check();
  } finally {
    unregister?.call();
    await lines.cancel();
  }
}

/// [config]'s text calls, run by the desktop that keeps its key.
final class DesktopModelProvider implements ModelProvider {
  DesktopModelProvider(this.session, this.config);
  final RemoteSession session;
  @override
  final ModelConnection config;

  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => _desktopLines(session, '/v1/provider/text', {
    'connection': config.raw,
    'request': request.raw,
  }, cancellation).map(decodeProviderEvent);

  @override
  Future<List<String>> listModels() async => config.models;

  /// The desktop's own provider validates when it runs the request.
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      const [];

  @override
  void close() {}
}

/// [config]'s images and ComfyUI workflows, from the desktop.
final class DesktopImageProvider implements ImageProvider, WorkflowSource {
  DesktopImageProvider(this.session, this.config);
  final RemoteSession session;
  @override
  final ModelConnection config;

  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final line = await _desktopLines(session, '/v1/provider/image', {
      'connection': config.raw,
      'request': request.raw,
      'references': [
        for (final r in references)
          {'mimeType': r.mimeType, 'data': base64Encode(r.bytes)},
      ],
    }, cancellation).firstWhere((line) => line['e'] == 'image');
    return GeneratedImage(
      bytes: base64Decode(line['image'] as String),
      revisedPrompt: line['revisedPrompt'] as String? ?? '',
      usage: (line['usage'] as Map? ?? {}).cast<String, dynamic>(),
    );
  }

  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) async =>
      jsonObject(
        (await session.request(
          'POST',
          '/v1/provider/workflow',
          json: {'connection': config.raw, 'filename': filename},
        ))['nodes'],
        'nodes',
      );

  @override
  void close() {}
}

/// A remote library's files, by content hash, on the desktop.
final class HttpAssetMirror implements AssetMirror {
  HttpAssetMirror(this.session);
  final RemoteSession session;

  @override
  Future<Uint8List> download(String name) async {
    final response = await session.send('GET', '/v1/assets/$name');
    if (response.statusCode != 200) {
      throw await RemoteRequestFailed.of(response);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > AssetLibrary.maxBytes) {
        throw const FormatException('图片文件大小异常');
      }
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    final response = await session.send(
      'PUT',
      '/v1/assets/$name',
      bytes: bytes,
    );
    if (response.statusCode != 200) {
      throw await RemoteRequestFailed.of(response);
    }
    await response.drain<void>();
  }
}
