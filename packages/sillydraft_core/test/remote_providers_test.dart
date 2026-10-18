import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

final class _Painter implements ImageProvider, WorkflowSource {
  _Painter(this.config, this.references);
  @override
  final ModelConnection config;
  final List<ImageReference> references;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    this.references.addAll(references);
    return GeneratedImage(
      bytes: Uint8List.fromList([1, 2, 3]),
      revisedPrompt: '改写：${request.prompt}',
    );
  }

  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) async => {
    '9': {'class_type': 'SaveImage', 'file': filename},
  };
  @override
  void close() {}
}

void main() {
  final writer = ModelConnection(
    id: 'writer',
    name: '写手',
    baseUrl: 'http://localhost:1234/v1',
    model: 'm',
  );
  final painter = ModelConnection(
    id: 'painter',
    name: '画师',
    baseUrl: 'http://localhost:8188',
    model: 'workflow',
    kind: ModelKind.image,
  );
  final references = <ImageReference>[];
  final desktopCancelled = Completer<void>();
  late Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  late Desktop desktop;
  late RemoteSession phone;
  setUp(() async {
    references.clear();
    script = (_, _) async* {
      yield const ReasoningDelta('想');
      yield const TextDelta('甲');
      yield decodeProviderEvent({
        'e': 'tool',
        'id': '1',
        'name': 'look',
        'arguments': {'q': 1},
        'extra_content': {
          'google': {'thought_signature': 'opaque+/='},
        },
      });
      yield const GenerationFinished('stop', usage: {'total': 3});
    };
    desktop = await Desktop.start(
      connections: [writer, painter],
      providerFactory: (c) async => ScriptProvider(c, (r, k) => script(r, k)),
      imageProviderFactory: (c) async => _Painter(c, references),
    );
    phone = await desktop.phone();
  });
  tearDown(() async {
    await phone.close();
    await desktop.close();
  });

  test('tool events without metadata keep their existing wire shape', () {
    final json = <String, dynamic>{
      'e': 'tool',
      'id': '1',
      'name': 'look',
      'arguments': {'q': 1},
    };
    final event = decodeProviderEvent(json) as ToolCallReady;
    expect(encodeProviderEvent(event), json);
    expect(event.toOpenAI().containsKey('extra_content'), isFalse);
  });

  test('text calls stream from the desktop\'s provider', () async {
    final events = await DesktopModelProvider(phone, writer)
        .generate(
          ProviderRequest(
            messages: [
              {'role': 'user', 'content': '你好'},
            ],
          ),
        )
        .toList();
    expect(events[0], isA<ReasoningDelta>().having((e) => e.text, 'text', '想'));
    expect(events[1], isA<TextDelta>().having((e) => e.text, 'text', '甲'));
    expect(
      events[2],
      isA<ToolCallReady>().having((e) => e.arguments, 'args', {'q': 1}),
    );
    expect((events[2] as ToolCallReady).toOpenAI()['extra_content'], {
      'google': {'thought_signature': 'opaque+/='},
    });
    expect(
      events[3],
      isA<GenerationFinished>().having((e) => e.usage, 'usage', {'total': 3}),
    );
  });

  test('cancelling on the phone cancels the desktop call', () async {
    script = (_, cancel) async* {
      yield const TextDelta('甲');
      final stop = Completer<void>();
      cancel.onCancel(() {
        if (!desktopCancelled.isCompleted) desktopCancelled.complete();
        stop.complete();
      });
      await stop.future;
      throw const GenerationCancelled();
    };
    final cancel = GenerationCancellation();
    Object? error;
    try {
      await for (final _ in DesktopModelProvider(phone, writer).generate(
        ProviderRequest(
          messages: [
            {'role': 'user', 'content': '你好'},
          ],
        ),
        cancellation: cancel,
      )) {
        cancel.cancel();
      }
    } catch (e) {
      error = e;
    }
    expect(error, isA<GenerationCancelled>());
    await desktopCancelled.future.timeout(const Duration(seconds: 10));
  });

  test('a connection the desktop did not save is refused', () async {
    final stranger = ModelConnection(
      id: 'stranger',
      name: 'x',
      baseUrl: 'https://elsewhere.example/v1',
      model: 'm',
    );
    await expectLater(
      DesktopModelProvider(
        phone,
        stranger,
      ).generate(ProviderRequest()).toList(),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403),
      ),
    );
  });

  test('images and workflows come from the desktop', () async {
    final provider = DesktopImageProvider(phone, painter);
    final image = await provider.generate(
      ImageRequest(prompt: '雨夜'),
      references: [
        ImageReference(bytes: Uint8List.fromList([9]), mimeType: 'image/png'),
      ],
    );
    expect(image.bytes, [1, 2, 3]);
    expect(image.revisedPrompt, '改写：雨夜');
    expect(references.single.bytes, [9]);
    expect((await provider.readWorkflow('a.json'))['9'], {
      'class_type': 'SaveImage',
      'file': 'a.json',
    });
  });

  test('files move between phone and desktop by hash', () async {
    final cache = Directory('${desktop.directory.path}/phone-cache');
    final mine = AssetLibrary(
      repository: phone.repository,
      directory: cache,
      mirror: HttpAssetMirror(phone),
    );
    final sent = await mine.prepare(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
    expect(await desktop.assets.readHash(sent.hash), isNotEmpty);
    final theirs = await desktop.assets.prepare(
      Uint8List.fromList(img.encodePng(img.Image(width: 9, height: 9))),
    );
    expect(
      await mine.readHash(theirs.hash),
      await desktop.assets.readHash(theirs.hash),
    );
    await expectLater(
      HttpAssetMirror(phone).upload('notahash.png', Uint8List(4)),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 400),
      ),
    );
  });
}
