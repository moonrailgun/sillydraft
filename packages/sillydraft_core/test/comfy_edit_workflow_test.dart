import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

final _nodes = <String, dynamic>{
  '6': {
    'class_type': 'CLIPTextEncode',
    'inputs': {'text': 'scene'},
  },
  '9': {
    'class_type': 'SaveImage',
    'inputs': {
      'images': ['3', 0],
    },
  },
  '10': {
    'class_type': 'LoadImage',
    'inputs': {'image': 'a.png'},
  },
  '11': {
    'class_type': 'LoadImage',
    'inputs': {'image': 'b.png'},
  },
};

ComfyWorkflow _workflow([List<String> images = const []]) => ComfyWorkflow(
  nodes: _nodes,
  promptInput: '6.text',
  outputNode: '9',
  imageInputs: images,
);

ModelConnection _comfy({ComfyWorkflow? edit, List<String> text = const []}) =>
    ModelConnection(
      id: 'c',
      name: 'ComfyUI',
      baseUrl: 'http://127.0.0.1:8188',
      model: 'workflow',
      protocol: ModelProtocol.comfyUI,
      comfyWorkflow: _workflow(text),
      comfyEditWorkflow: edit,
    );

typedef _Studio = ({
  String url,
  List<String> reads,
  List<Map<String, dynamic>> prompts,
  StoryRepository repo,
  StoryAsset first,
  StoryAsset second,
  Future<GenerationTask> Function(ModelConnection, List<String>) draw,
});

/// A ComfyUI serving [graphs] as its saved workflows, naming each upload
/// apart (ref1.png, ref2.png, …) and keeping each graph it is sent, and a
/// book with two portraits that draws through it.
Future<_Studio> _studio(Map<String, Map<String, dynamic>> graphs) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  final dir = await Directory.systemTemp.createTemp('comfy-edit-');
  addTearDown(() => dir.delete(recursive: true));
  final repo = StoryRepository.memory();
  addTearDown(repo.close);
  final reads = <String>[], prompts = <Map<String, dynamic>>[];
  var uploads = 0;
  server.listen((r) async {
    r.response.headers.contentType = ContentType.json;
    final path = r.uri.path;
    if (r.method == 'GET' && path.startsWith('/userdata/')) {
      reads.add(r.uri.pathSegments.last);
      r.response.write(jsonEncode(graphs[r.uri.pathSegments.last]));
    } else if (path == '/upload/image') {
      await r.drain<void>();
      uploads++;
      r.response.write(
        '{"name":"ref$uploads.png","subfolder":"","type":"input"}',
      );
    } else if (path == '/prompt') {
      final body = jsonDecode(await utf8.decoder.bind(r).join());
      prompts.add(body['prompt'] as Map<String, dynamic>);
      r.response.write('{"prompt_id":"p","node_errors":{}}');
    } else if (path == '/history/p') {
      r.response.write(
        jsonEncode({
          'p': {
            'status': {
              'status_str': 'success',
              'completed': true,
              'messages': <Object>[],
            },
            'outputs': {
              '9': {
                'images': [
                  {'filename': 'out.png', 'subfolder': '', 'type': 'output'},
                ],
              },
            },
          },
        }),
      );
    } else if (path == '/view') {
      r.response.add(testPicture());
    } else {
      r.response.statusCode = 404;
    }
    await r.response.close();
  });
  final library = AssetLibrary(repository: repo, directory: dir);
  final runner = TaskRunner(
    repository: repo,
    providerFactory: (_) async => throw StateError('text not expected'),
    imageProviderFactory: (c) async => ComfyUIProvider(config: c),
    assetLibrary: library,
  );
  addTearDown(runner.close);
  final service = IllustrationService(repository: repo, runner: runner);
  final novel = await repo.createNovel(title: '同框');
  Future<StoryAsset> portrait(String name) => library.importImage(
    branchId: novel.activeBranchId,
    name: name,
    bytes: testPicture(),
    purpose: AssetPurpose.reference,
  );
  return (
    url: 'http://127.0.0.1:${server.port}',
    reads: reads,
    prompts: prompts,
    repo: repo,
    first: await portrait('林岚'),
    second: await portrait('沈舟'),
    draw: (ModelConnection connection, List<String> references) async =>
        runner.wait(
          (await service.generate(
            branchId: novel.activeBranchId,
            connection: connection,
            name: '渡口',
            request: ImageRequest(prompt: '两人在渡口'),
            referenceAssetIds: references,
          )).id,
        ),
  );
}

/// A text-to-image graph: prompt, sampler and output, no image input.
final _textGraph = <String, dynamic>{
  '6': _nodes['6'],
  '9': _nodes['9'],
  '3': {
    'class_type': 'KSampler',
    'inputs': {
      'seed': 1,
      'positive': ['6', 0],
    },
  },
};

void main() {
  test('a stored single image input reads as a one-item list', () {
    final w = ComfyWorkflow.fromJson({
      'nodes': _nodes,
      'promptInput': '6.text',
      'imageInput': '10.image',
      'outputNode': '9',
    });
    expect(w.imageInputs, ['10.image']);
    expect(w.raw.containsKey('imageInput'), isFalse);
  });

  test('image inputs are distinct from each other and the prompt', () {
    expect(() => _workflow(['10.image', '10.image']), throwsFormatException);
    expect(() => _workflow(['6.text']), throwsFormatException);
  });

  test('an edit workflow needs an image input; the limit follows it', () {
    expect(referenceLimit(_comfy()), 0);
    expect(referenceLimit(_comfy(text: ['10.image'])), 1);
    final both = _comfy(edit: _workflow(['10.image', '11.image']));
    expect(referenceLimit(both), 2);
    // References always run the edit workflow when there is one.
    expect(
      referenceLimit(
        _comfy(text: ['10.image', '11.image'], edit: _workflow(['10.image'])),
      ),
      1,
    );
    expect(ModelConnection.fromJson(both.raw).comfyEditWorkflow!.imageInputs, [
      '10.image',
      '11.image',
    ]);
    expect(() => _comfy(edit: _workflow()), throwsFormatException);
    expect(
      referenceLimit(
        ModelConnection(
          id: 'n',
          name: 'NovelAI',
          baseUrl: 'https://image.novelai.net',
          model: 'nai-diffusion-4-5-full',
          protocol: ModelProtocol.novelAI,
        ),
      ),
      0,
    );
    expect(
      referenceLimit(
        ModelConnection(
          id: 'o',
          name: 'OpenAI',
          baseUrl: 'http://localhost:1',
          model: 'gpt-image-1',
        ),
      ),
      16,
    );
  });

  test(
    'references run the edit workflow, filling its inputs in order',
    () async {
      final s = await _studio({
        'workflows/文生图.json': _textGraph,
        'workflows/图生图.json': _nodes,
      });
      final connection = ModelConnection(
        id: 'comfy',
        name: 'ComfyUI',
        baseUrl: s.url,
        model: 'workflow',
        protocol: ModelProtocol.comfyUI,
        comfyWorkflow: ComfyWorkflow(
          nodes: _textGraph,
          promptInput: '6.text',
          outputNode: '9',
          filename: '文生图.json',
        ),
        comfyEditWorkflow: ComfyWorkflow(
          nodes: _nodes,
          promptInput: '6.text',
          outputNode: '9',
          imageInputs: ['10.image', '11.image'],
          filename: '图生图.json',
        ),
      );
      final prompts = s.prompts;

      final edited = await s.draw(connection, [s.first.id]);
      expect(edited.status, TaskStatus.completed, reason: edited.error);
      expect(
        s.reads,
        containsAll(['workflows/文生图.json', 'workflows/图生图.json']),
      );
      expect(prompts.single['6']['inputs']['text'], '两人在渡口');
      expect(prompts.single['10']['inputs']['image'], 'ref1.png');
      expect(prompts.single['11']['inputs']['image'], 'ref1.png');
      expect(
        (await s.repo.getAsset(edited.result['assetId'] as String))
            .metadata['workflow'],
        '图生图.json',
      );

      final plain = await s.draw(connection, []);
      expect(plain.status, TaskStatus.completed, reason: plain.error);
      expect(prompts.last.containsKey('10'), isFalse);
      expect(
        (await s.repo.getAsset(plain.result['assetId'] as String))
            .metadata['workflow'],
        '文生图.json',
      );

      final over = await s.draw(connection, [
        s.first.id,
        s.first.id,
        s.first.id,
      ]);
      expect(over.status, TaskStatus.failed);
      expect(over.error, contains('最多使用 2 张'));
      expect(prompts, hasLength(2));

      final pair = await s.draw(connection, [s.first.id, s.second.id]);
      expect(pair.status, TaskStatus.completed, reason: pair.error);
      expect(prompts.last['10']['inputs']['image'], 'ref2.png');
      expect(prompts.last['11']['inputs']['image'], 'ref3.png');
    },
  );

  test(
    'the edit workflow keeps its own model on a multi-model connection',
    () async {
      final text = <String, dynamic>{
        ..._textGraph,
        '4': {
          'class_type': 'CheckpointLoaderSimple',
          'inputs': {'ckpt_name': 'a.safetensors'},
        },
      };
      final s = await _studio({
        'workflows/文生图.json': text,
        'workflows/图生图.json': _nodes,
      });
      final edited = await s.draw(
        ModelConnection(
          id: 'comfy',
          name: 'ComfyUI',
          baseUrl: s.url,
          model: 'b.safetensors',
          models: ['a.safetensors', 'b.safetensors'],
          protocol: ModelProtocol.comfyUI,
          comfyWorkflow: ComfyWorkflow(
            nodes: text,
            promptInput: '6.text',
            modelInput: '4.ckpt_name',
            outputNode: '9',
            filename: '文生图.json',
          ),
          comfyEditWorkflow: ComfyWorkflow(
            nodes: _nodes,
            promptInput: '6.text',
            outputNode: '9',
            imageInputs: ['10.image'],
            filename: '图生图.json',
          ),
        ),
        [s.first.id],
      );
      expect(edited.status, TaskStatus.completed, reason: edited.error);
      expect(s.prompts.single.keys, unorderedEquals(_nodes.keys));
      expect(jsonEncode(s.prompts.single), isNot(contains('safetensors')));
      expect(s.prompts.single['10']['inputs']['image'], 'ref1.png');
    },
  );

  test(
    'without an edit workflow, references fill the text workflow\'s inputs',
    () async {
      final s = await _studio({'workflows/文生图.json': _nodes});
      final drawn = await s.draw(
        ModelConnection(
          id: 'comfy',
          name: 'ComfyUI',
          baseUrl: s.url,
          model: 'workflow',
          protocol: ModelProtocol.comfyUI,
          comfyWorkflow: ComfyWorkflow(
            nodes: _nodes,
            promptInput: '6.text',
            outputNode: '9',
            imageInputs: ['10.image'],
            filename: '文生图.json',
          ),
        ),
        [s.first.id],
      );
      expect(drawn.status, TaskStatus.completed, reason: drawn.error);
      expect(s.prompts.single['10']['inputs']['image'], 'ref1.png');
      expect(
        (await s.repo.getAsset(drawn.result['assetId'] as String))
            .metadata['workflow'],
        '文生图.json',
      );
    },
  );
}
