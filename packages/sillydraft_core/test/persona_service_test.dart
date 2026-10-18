import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

final class _Text implements ModelProvider {
  _Text(this.config, this.reply, this.requests);
  @override
  final ModelConnection config;
  final String reply;
  final List<ProviderRequest> requests;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    requests.add(request);
    yield TextDelta(reply);
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

final class _Painter implements ImageProvider {
  _Painter(this.config, this.requests);
  @override
  final ModelConnection config;
  final List<ImageRequest> requests;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    requests.add(request);
    return GeneratedImage(
      bytes: Uint8List.fromList(img.encodePng(img.Image(width: 4, height: 4))),
    );
  }

  @override
  void close() {}
}

void main() {
  late StoryRepository repo;
  late AssetLibrary library;
  late List<ProviderRequest> requests;
  late List<ImageRequest> paintings;
  late String reply;
  late PersonaService service;
  final text = ModelConnection(
    id: 'text',
    name: '文本',
    baseUrl: 'http://localhost:1/v1',
    model: 'm',
  );
  final painter = ModelConnection(
    id: 'img',
    name: '生图',
    baseUrl: 'http://localhost:1/v1',
    model: 'gpt-image-1',
  );

  setUp(() async {
    repo = StoryRepository.memory();
    final dir = await Directory.systemTemp.createTemp('persona-service');
    addTearDown(() => dir.delete(recursive: true));
    library = AssetLibrary(repository: repo, directory: dir);
    requests = [];
    paintings = [];
    reply = '{}';
    service = PersonaService(
      repository: repo,
      runner: TaskRunner(
        repository: repo,
        providerFactory: (c) async => _Text(c, reply, requests),
        imageProviderFactory: (c) async => _Painter(c, paintings),
        assetLibrary: library,
      ),
    );
  });
  tearDown(() => repo.close());

  Future<PersonaImage> picture() async => PersonaImage.of(
    await library.prepare(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    ),
  );

  test('reading images sends at most four thumbnails and keeps a written description', () async {
    reply = '```json\n{"appearance": "黑色短发", "outfit": "灰色卫衣", "description": "猜测"}\n```';
    final draft = Persona(
      id: '',
      name: '林舟',
      description: '插画师',
      images: [for (var i = 0; i < 5; i++) await picture()],
    );
    final result = await service.describeImages(text, draft);
    expect(
      (result.appearance, result.outfit, result.description),
      ('黑色短发', '灰色卫衣', '插画师'),
    );
    final content = requests.single.messages.last['content'] as List;
    final urls = [
      for (final part in content)
        if (part['type'] == 'image_url') part['image_url']['url'] as String,
    ];
    expect(urls, hasLength(4));
    expect(urls.first, startsWith('data:image/jpeg;base64,'));
    final blank = await service.describeImages(
      text,
      draft.copyWith(description: ''),
    );
    expect(blank.description, '猜测');
  });

  test(
    'a local command-line model is refused for images before any request',
    () async {
      final cli = ModelConnection(
        id: 'cli',
        name: 'Claude Code',
        baseUrl: '',
        model: 'default',
        protocol: ModelProtocol.claudeCode,
      );
      await expectLater(
        service.describeImages(
          cli,
          Persona(id: '', name: '我', images: [await picture()]),
        ),
        throwsFormatException,
      );
      expect(requests, isEmpty);
    },
  );

  test('refining keeps a written name and fills the rest', () async {
    reply = '{"name": "别名", "description": "二十三岁的插画师", "appearance": "短发", "outfit": "卫衣"}';
    final kept = await service.refine(
      text,
      const Persona(id: 'me', name: '我', description: '插画师'),
    );
    expect(
      (kept.id, kept.name, kept.description, kept.appearance, kept.outfit),
      ('me', '我', '二十三岁的插画师', '短发', '卫衣'),
    );
    expect(
      jsonEncode(requests.first.messages.last['content']),
      contains('插画师'),
    );
    final named = await service.refine(
      text,
      const Persona(id: '', name: '', description: '冷淡的女大学生'),
    );
    expect(named.name, '别名');
  });

  test(
    'replies that are not the requested JSON fail without a result',
    () async {
      for (final bad in [
        '好的，这是人设：{}',
        '[]',
        '{"name": "x", "description": 1, "appearance": "", "outfit": ""}',
        '{"description": "缺字段"}',
      ]) {
        reply = bad;
        await expectLater(
          service.refine(text, const Persona(id: '', name: '林舟')),
          throwsFormatException,
          reason: bad,
        );
      }
    },
  );

  test(
    'image prompts follow the model rather than the workflow transport',
    () async {
      reply = '{"prompt": "solo, short hair"}';
      const draft = Persona(id: '', name: '我', appearance: '短发', outfit: '卫衣');
      final novelAI = ModelConnection(
        id: 'nai',
        name: 'NovelAI',
        baseUrl: 'https://image.novelai.net',
        model: 'nai-diffusion-4-5-full',
        protocol: ModelProtocol.novelAI,
      );
      expect(
        await service.imagePrompt(text, draft, novelAI),
        'solo, short hair',
      );
      await service.imagePrompt(text, draft, painter);
      expect(requests[0].messages.first['content'], contains('Danbooru'));
      expect(
        requests[1].messages.first['content'],
        isNot(contains('Danbooru')),
      );
      final comfy = ModelConnection(
        id: 'comfy',
        name: 'ComfyUI',
        baseUrl: 'http://localhost:1',
        model: 'workflow',
        protocol: ModelProtocol.comfyUI,
        comfyWorkflow: ComfyWorkflow(
          nodes: {
            '1': <String, dynamic>{
              'class_type': 'UNETLoader',
              'inputs': {'unet_name': 'qwen_image.safetensors'},
            },
            '2': <String, dynamic>{
              'class_type': 'CLIPTextEncode',
              'inputs': {'text': ''},
            },
            '3': <String, dynamic>{
              'class_type': 'SaveImage',
              'inputs': <String, dynamic>{},
            },
          },
          promptInput: '2.text',
          outputNode: '3',
        ),
      );
      await service.imagePrompt(text, draft, comfy);
      expect(
        requests[2].messages.first['content'],
        contains('qwen_image.safetensors'),
      );
      expect(requests[2].messages.first['content'], contains('无法确定'));
      expect(requests[2].messages.first['content'], contains('自然语言'));
      await expectLater(
        service.imagePrompt(text, const Persona(id: '', name: '我'), painter),
        throwsFormatException,
      );
    },
  );

  test(
    'a generated reference uses the painter defaults and is stored by hash',
    () async {
      await repo.setSetting(
        'imageDefaults/img/${Uri.encodeComponent('gpt-image-1')}',
        {'size': '1024x1536'},
      );
      final image = await service.generateImage(painter, 'solo, short hair');
      expect(paintings.single.prompt, 'solo, short hair');
      expect(paintings.single.parameters['size'], '1024x1536');
      expect(library.hashFile(image.hash).existsSync(), isTrue);
      expect((image.width, image.height), (4, 4));
    },
  );

  test('remote-executor connections get a job id, others do not', () async {
    ModelConnection remote(String id, String model) => ModelConnection(
      id: id,
      name: id,
      baseUrl: 'http://localhost:1',
      model: model,
      protocol: ModelProtocol.sillyDraftRunner,
    );
    reply = '{"prompt": "solo"}';
    const draft = Persona(id: '', name: '我', appearance: '短发');
    await service.imagePrompt(remote('t', 'm'), draft, painter);
    expect(requests.single.executionId, startsWith('persona-'));
    await service.generateImage(remote('p', 'gpt-image-1'), 'solo');
    expect(paintings.single.executionId, startsWith('persona-'));
    await service.generateImage(painter, 'solo');
    expect(paintings.last.executionId, isNull);
  });
}
