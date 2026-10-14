import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'task_runner_test.dart' show ScriptProvider;

class _ImageModel implements ImageProvider {
  _ImageModel(this.config, this.requests);
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
    return GeneratedImage(bytes: testPicture());
  }

  @override
  void close() {}
}

Future<GenerationTask> _awaitConfirmation(
  StoryRepository repo,
  String id,
) async {
  for (var i = 0; i < 200; i++) {
    final task = await repo.getTask(id);
    if (!task.isActive || task.result['imageConfirmation'] != null) {
      return task;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('No image confirmation');
}

void main() {
  test(
    'the assistant draws a selection with the configured image engine',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'sillydraft-agent-image-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '雾港');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '渡口',
        content: ManuscriptContent.plainText('雨中的渡口，她撑着红伞。'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      final image = ModelConnection(
        id: 'img',
        name: 'img',
        baseUrl: 'http://localhost:1',
        model: 'painter',
      );
      // What the author last chose on the illustration page.
      await repo.setSetting('imageDefaults/img/painter', {
        'size': '1024x1536',
        'quality': 'high',
        'parameters': {'seed': 7},
        'allowedDownloadHosts': <String>[],
      });
      final requests = <ProviderRequest>[], images = <ImageRequest>[];
      var script = <List<ProviderEvent>>[];
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          requests.add(request);
          for (final e in script.removeAt(0)) {
            yield e;
          }
        }),
        assetLibrary: AssetLibrary(repository: repo, directory: dir),
        imageProviderFactory: (c) async => _ImageModel(c, images),
      );
      addTearDown(runner.close);
      final agent = EditorAgent(repository: repo, runner: runner);
      final editor = ModelConnection(
        id: 't',
        name: 't',
        baseUrl: 'http://localhost:1',
        model: 't',
      );
      List<String> toolNames(ProviderRequest r) => [
        for (final t in r.tools) (t['function'] as Map)['name'] as String,
      ];
      Map<String, dynamic> imageArgs(ProviderRequest r) =>
          ((r.tools.firstWhere(
                        (t) =>
                            (t['function'] as Map)['name'] == 'generate_image',
                      )['function']
                      as Map)['parameters']
                  as Map)['properties']
              as Map<String, dynamic>;

      script = [
        [
          ToolCallReady('a', 'generate_image', {
            'prompt': '雨夜渡口，撑红伞的少女',
            'name': '渡口',
          }),
          const GenerationFinished('tool_calls'),
        ],
        [const TextDelta('已生成'), const GenerationFinished('stop')],
      ];
      final task = await agent.send(
        conversationId: conversation,
        connection: editor,
        message: '为这段正文生成插图：她撑着红伞。',
        imageConnection: image,
        attachChapterId: chapter.id,
      );
      final pending = await _awaitConfirmation(repo, task.id);
      expect(images, isEmpty);
      expect(pending.result['imageConfirmation'], isA<Map<String, dynamic>>());
      final confirmation = pending.result['imageConfirmation'] as Map;
      expect(confirmation['prompt'], '雨夜渡口，撑红伞的少女');
      expect(
        (await repo.listTasks()).where((t) => t.kind == TaskKind.illustration),
        isEmpty,
      );
      expect(
        runner.respondToImageConfirmation(task.id, 'stale', approved: true),
        isFalse,
      );
      expect(
        runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: true,
        ),
        isTrue,
      );
      expect(
        runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: true,
        ),
        isFalse,
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      expect((await repo.getTask(task.id)).result['imageConfirmation'], isNull);

      final first = requests.first;
      expect(toolNames(first), contains('generate_image'));
      // The model learns the engine and the author's defaults, and writes
      // the prompt itself.
      expect(
        first.messages.first['content'],
        allOf(contains('openAICompatible'), contains('painter')),
      );
      expect(first.messages.first['content'], contains('1024x1536'));
      expect(imageArgs(first), isNot(contains('negative_prompt')));
      // The chapter goes to the model; the chat keeps only what was typed.
      expect(first.messages.last['content'], contains('雨中的渡口，她撑着红伞。'));
      final messages = await repo.getAgentMessages(conversation);
      final user = messages.firstWhere((m) => m.role == 'user');
      expect(user.content, '为这段正文生成插图：她撑着红伞。');
      expect(user.raw['attachment'], containsPair('chapterId', chapter.id));
      expect(user.raw['attachment'], containsPair('title', '渡口'));

      expect(images.single.prompt, '雨夜渡口，撑红伞的少女');
      expect(images.single.parameters, {
        'seed': 7,
        'size': '1024x1536',
        'quality': 'high',
      });
      final asset = (await repo.listAssets(novel.id)).single;
      expect(asset.name, '渡口');
      expect(asset.sourceRevisionId, chapter.revisionId);
      final tool = messages.firstWhere((m) => m.role == 'tool');
      expect(tool.raw['tool_name'], 'generate_image');
      expect(tool.content, contains(asset.id));

      // Without an image engine the tool is not offered at all.
      requests.clear();
      script = [
        [const TextDelta('好'), const GenerationFinished('stop')],
      ];
      final plain = await agent.send(
        conversationId: conversation,
        connection: editor,
        message: '继续',
      );
      await runner.wait(plain.id);
      expect(toolNames(requests.first), isNot(contains('generate_image')));
      expect(
        requests.first.messages.first['content'],
        isNot(contains('generate_image')),
      );
      // Later turns still carry the attached chapter.
      expect(
        requests.first.messages.map((m) => '${m['content']}').join(),
        contains('雨中的渡口，她撑着红伞。'),
      );

      // NovelAI takes the model's negative prompt over the saved one.
      final novelAI = ModelConnection(
        id: 'nai',
        name: 'nai',
        baseUrl: 'http://localhost:1',
        model: 'nai-diffusion-4-5-full',
        protocol: ModelProtocol.novelAI,
      );
      await repo.setSetting('imageDefaults/nai/nai-diffusion-4-5-full', {
        'size': '832x1216',
        'parameters': {'negative_prompt': 'lowres', 'steps': 23},
      });
      requests.clear();
      script = [
        [
          ToolCallReady('b', 'generate_image', {
            'prompt': '1girl, red umbrella, rain, stone bridge',
            'negative_prompt': 'lowres, blurry',
            'name': '渡口',
          }),
          const GenerationFinished('tool_calls'),
        ],
        [const TextDelta('已生成'), const GenerationFinished('stop')],
      ];
      final drawn = await agent.send(
        conversationId: conversation,
        connection: editor,
        message: '再画一张',
        imageConnection: novelAI,
      );
      final second =
          (await _awaitConfirmation(repo, drawn.id)).result['imageConfirmation']
              as Map;
      expect(second['negativePrompt'], 'lowres, blurry');
      expect(images, hasLength(1));
      runner.respondToImageConfirmation(
        drawn.id,
        second['id'] as String,
        approved: true,
      );
      expect((await runner.wait(drawn.id)).status, TaskStatus.completed);
      expect(requests.first.messages.first['content'], contains('novelAI'));
      expect(imageArgs(requests.first), contains('negative_prompt'));
      expect(images.last.parameters, {
        'negative_prompt': 'lowres, blurry',
        'steps': 23,
        'size': '832x1216',
      });
    },
  );

  test(
    'closing while the author decides draws nothing and ends the task',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '雾港');
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      final images = <ImageRequest>[];
      var asked = false;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          if (asked) throw StateError('No second round after close');
          asked = true;
          yield ToolCallReady('a', 'generate_image', {
            'prompt': '雨夜',
            'name': '渡口',
          });
          yield const GenerationFinished('tool_calls');
        }),
        imageProviderFactory: (c) async => _ImageModel(c, images),
      );
      final connection = ModelConnection(
        id: 't',
        name: 't',
        baseUrl: 'http://localhost:1',
        model: 't',
      );
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: connection,
        message: '画一张',
        imageConnection: connection,
      );
      final pending = await _awaitConfirmation(repo, task.id);
      expect(pending.result['imageConfirmation'], isNotNull);
      await runner.close().timeout(const Duration(seconds: 5));
      expect((await repo.getTask(task.id)).isActive, isFalse);
      expect(images, isEmpty);
    },
  );
}
