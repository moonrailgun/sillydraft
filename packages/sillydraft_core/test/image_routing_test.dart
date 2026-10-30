import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'support/image_scene.dart';
import 'task_runner_test.dart' show ScriptProvider;

class _Images implements ImageProvider {
  _Images(this.config, this.draw);
  @override
  final ModelConnection config;
  final Future<GeneratedImage> Function(ImageRequest) draw;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) => draw(request);
  @override
  void close() {}
}

class _Workflows extends _Images implements WorkflowSource {
  _Workflows(ModelConnection config, this.read)
    : super(
        config,
        (_) async => throw StateError('No image submission expected'),
      );
  final Future<Map<String, dynamic>> Function(String) read;
  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) => read(filename);
}

void main() {
  final text = ModelConnection(
    id: 'text',
    name: '分析',
    baseUrl: 'http://localhost:1',
    model: 'text',
  );
  final normal = ModelConnection(
    id: 'normal',
    name: '普通',
    baseUrl: 'http://localhost:1',
    model: 'image',
    kind: ModelKind.image,
  );
  final nsfw = ModelConnection(
    id: 'nsfw',
    name: 'NSFW',
    baseUrl: 'http://localhost:1',
    model: 'nai-diffusion-4-5-full',
    protocol: ModelProtocol.novelAI,
  );

  for (final outcome in ['approve', 'reject', 'invalid', 'missing', 'cancel']) {
    test(
      'mixed batch routes each illustration and reference: $outcome',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final dir = await Directory.systemTemp.createTemp('image-routing-');
        addTearDown(() => dir.delete(recursive: true));
        for (final c in [normal, nsfw]) {
          await repo.setSetting('imageDefaults/${c.id}', {
            'parameters': {'negative_prompt': 'avoid ${c.id}'},
          });
        }
        final novel = await repo.createNovel(title: '分流');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('红伞过桥。\n白船靠岸。'),
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final draws = <({String engine, ImageRequest request})>[];
        final classifications = <String>[];
        var formats = 0, agentCalls = 0;
        late TaskRunner runner;
        late String taskId;
        runner = TaskRunner(
          repository: repo,
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          imageProviderFactory: (c) async => _Images(c, (request) async {
            draws.add((engine: c.id, request: request));
            return GeneratedImage(bytes: testPicture());
          }),
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            if (request.executionId?.startsWith('image-prompt-') == true) {
              final system = request.messages.first['content'] as String;
              if (system.contains('内容分类器')) {
                final data = jsonDecode(
                  request.messages.last['content'] as String,
                ) as Map;
                classifications.add(data['description'] as String);
                if (outcome == 'cancel') await runner.cancel(taskId);
                yield TextDelta(
                  outcome == 'invalid'
                      ? 'maybe'
                      : '${data['description'] == 'adult scene'}',
                );
              } else {
                formats++;
                yield TextDelta(
                  system.contains('Danbooru')
                      ? 'adult, tagged'
                      : 'ordinary natural language',
                );
              }
              yield const GenerationFinished('stop');
              return;
            }
            agentCalls++;
            yield ToolCallReady('batch', 'generate_images', {
              'images': [
                for (final adult in [false, true])
                  {
                    ...emptyImageContext,
                    'name': adult ? '成人画面' : '普通画面',
                    'quote': adult ? '白船靠岸。' : '红伞过桥。',
                    'prompt': adult ? 'adult scene' : 'ordinary scene',
                    'subjects': [
                      {
                        'kind': 'character',
                        'name': '阿青',
                        'prompt': 'short dark hair, blue coat',
                      },
                    ],
                  },
              ],
            });
            yield const GenerationFinished('tool_calls');
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: text,
          imageConnection: normal,
          imagePromptConnection: text,
          nsfwImageConnection: outcome == 'missing' ? null : nsfw,
          attachChapterId: chapter.id,
          illustrationBatch: true,
          message: '生成两张插图',
        );
        taskId = task.id;
        GenerationTask pending = task;
        for (var i = 0; i < 400; i++) {
          pending = await repo.getTask(task.id);
          if (!pending.isActive ||
              pending.result['imageConfirmation'] != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(draws, isEmpty, reason: 'No paid image request before approval');
        if (outcome == 'approve' || outcome == 'reject') {
          expect(pending.error, isEmpty);
          final confirmation = pending.result['imageConfirmation'] as Map;
          final previews = (confirmation['images'] as List).cast<Map>();
          expect(previews.map((p) => p['nsfw']), [false, true]);
          expect(previews.map((p) => (p['connection'] as Map)['id']), [
            'normal',
            'nsfw',
          ]);
          final reference =
              (confirmation['newReferences'] as List).single as Map;
          expect(reference['nsfw'], false);
          expect((reference['connection'] as Map)['id'], 'normal');
          expect(classifications, hasLength(3));
          expect(formats, 3);
          await runner.respondToImageConfirmation(
            task.id,
            confirmation['id'] as String,
            approved: outcome == 'approve',
          );
        }
        final done = await runner.wait(task.id);
        expect(
          agentCalls,
          1,
          reason: 'Routing failures must not retry the editor',
        );
        if (outcome == 'approve') {
          expect(done.status, TaskStatus.completed, reason: done.error);
          expect(draws.map((d) => d.engine), ['normal', 'normal', 'nsfw']);
          expect(draws.map((d) => d.request.parameters['negative_prompt']), [
            'avoid normal',
            'avoid normal',
            'avoid nsfw',
          ]);
          expect(draws.last.request.prompt, startsWith('adult, tagged'));
          final assets = await repo.listAssets(novel.id);
          expect(assets, hasLength(3));
          expect(
            assets.singleWhere((a) => a.name == '成人画面').metadata['nsfw'],
            true,
          );
          expect(
            assets
                .singleWhere((a) => a.purpose == AssetPurpose.reference)
                .metadata['nsfw'],
            false,
          );
        } else {
          expect(draws, isEmpty);
          expect(await repo.listAssets(novel.id), isEmpty);
          if (outcome == 'invalid' || outcome == 'missing') {
            expect(done.status, TaskStatus.failed);
            expect(done.error, contains('NSFW'));
          }
          if (outcome == 'cancel') {
            expect(done.status, TaskStatus.cancelled);
            expect(formats, 0);
          }
        }
      },
    );
  }

  test('direct references, personas and regeneration use the routed engine defaults', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final dir = await Directory.systemTemp.createTemp('direct-routing-');
    addTearDown(() => dir.delete(recursive: true));
    await repo.setSetting('imageDefaults/nsfw', {
      'parameters': {'negative_prompt': 'nsfw default'},
    });
    final branch = (await repo.createNovel(title: '参考图')).activeBranchId;
    final draws = <String>[];
    var decision = true;
    final runner = TaskRunner(
      repository: repo,
      assetLibrary: AssetLibrary(repository: repo, directory: dir),
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        yield TextDelta(
          '${request.messages.first['content']}'.contains('内容分类器')
              ? '$decision'
              : 'formatted description',
        );
      }),
      imageProviderFactory: (c) async => _Images(c, (request) async {
        draws.add(c.id);
        expect(request.prompt, 'formatted description');
        expect(
          request.parameters['negative_prompt'],
          c.id == 'nsfw' ? 'nsfw default' : null,
        );
        expect(request.parameters['old_engine_only'], isNull);
        return GeneratedImage(bytes: testPicture());
      }),
    );
    addTearDown(runner.close);
    final service = IllustrationService(repository: repo, runner: runner);
    final task = await service.generate(
      branchId: branch,
      connection: normal,
      name: '参考图',
      purpose: AssetPurpose.reference,
      request: ImageRequest(
        prompt: 'raw description',
        parameters: {'old_engine_only': true},
      ),
      promptConnection: text,
      nsfwConnection: nsfw,
    );
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    await PersonaService(repository: repo, runner: runner).generateImage(
      normal,
      'raw portrait',
      promptConnection: text,
      nsfwConnection: nsfw,
    );
    await repo.setSetting('imageDefaults/nsfw', {
      'parameters': {'negative_prompt': 'new default'},
    });
    final sameEngine = await service.regenerate(
      branchId: branch,
      assetId: done.result['assetId'] as String,
      connection: normal,
      promptConnection: text,
      nsfwConnection: nsfw,
    );
    final sameResult = await runner.wait(sameEngine.id);
    expect(sameResult.status, TaskStatus.completed, reason: sameResult.error);
    decision = false;
    final regenerated = await service.regenerate(
      branchId: branch,
      assetId: done.result['assetId'] as String,
      connection: normal,
      promptConnection: text,
      nsfwConnection: nsfw,
    );
    final result = await runner.wait(regenerated.id);
    expect(result.status, TaskStatus.completed, reason: result.error);
    expect(draws, ['nsfw', 'nsfw', 'nsfw', 'normal']);
  });

  for (final decision in ['false', 'true']) {
    test('$decision selects the engine before formatting its prompt', () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final requests = <ProviderRequest>[];
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          requests.add(request);
          yield TextDelta(
            requests.length == 1 ? ' $decision\n' : 'final prompt',
          );
          yield const GenerationFinished('stop');
        }),
      );
      addTearDown(runner.close);
      final result = await IllustrationService(repository: repo, runner: runner)
          .routePrompt(
            textConnection: text,
            connection: normal,
            nsfwConnection: nsfw,
            description: '画面描述',
            context: {'appearance': '固定外貌'},
          );
      expect(result.nsfw, decision == 'true');
      expect(result.connection.id, decision == 'true' ? 'nsfw' : 'normal');
      expect(result.prompt, 'final prompt');
      expect(requests, hasLength(2));
      expect(requests.first.messages.last['content'], contains('固定外貌'));
      expect(
        requests.last.messages.first['content'],
        contains(decision == 'true' ? 'Danbooru' : '自然语言'),
      );
      expect(requests.last.messages.last['content'], '画面描述');
      expect(requests.first.executionId, isNot(requests.last.executionId));
    });
  }

  test(
    'formats for the latest ComfyUI workflow actually used by references',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      Map<String, dynamic> nodes(String model) => {
        '1': {
          'class_type': 'Loader',
          'inputs': {'unet_name': model},
        },
        '2': {
          'class_type': 'Text',
          'inputs': {'text': ''},
        },
        '3': {
          'class_type': 'Image',
          'inputs': {'image': ''},
        },
        '4': {'class_type': 'SaveImage', 'inputs': <String, dynamic>{}},
      };
      final engine = ModelConnection(
        id: 'comfy',
        name: 'ComfyUI',
        baseUrl: 'http://localhost:1',
        model: 'workflow',
        protocol: ModelProtocol.comfyUI,
        comfyWorkflow: ComfyWorkflow(
          nodes: nodes('old-text'),
          promptInput: '2.text',
          outputNode: '4',
          filename: 'text.json',
        ),
        comfyEditWorkflow: ComfyWorkflow(
          nodes: nodes('old-edit'),
          promptInput: '2.text',
          outputNode: '4',
          filename: 'edit.json',
          imageInputs: ['3.image'],
        ),
      );
      final reads = <String>[];
      final formats = <String>[];
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          final system = '${request.messages.first['content']}';
          if (system.contains('内容分类器')) {
            yield const TextDelta('false');
          } else {
            formats.add(system);
            yield const TextDelta('a quiet scene');
          }
        }),
        imageProviderFactory: (c) async => _Workflows(c, (filename) async {
          reads.add(filename);
          return nodes('latest-$filename');
        }),
      );
      addTearDown(runner.close);
      final service = IllustrationService(repository: repo, runner: runner);
      for (final references in [false, true]) {
        await service.routePrompt(
          textConnection: text,
          connection: engine,
          description: '安静的画面',
          references: references,
        );
      }
      expect(reads, ['text.json', 'edit.json']);
      expect(formats.first, contains('latest-text.json'));
      expect(formats.first, contains('本次不使用参考图'));
      expect(formats.last, contains('latest-edit.json'));
      expect(formats.last, contains('本次使用参考图'));
    },
  );

  for (final reply in [
    'yes',
    '{"nsfw":true}',
    'false because...',
    '',
    '```true```',
  ]) {
    test(
      'rejects ambiguous classification $reply without drafting or drawing',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        var calls = 0;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (_, _) async* {
            calls++;
            yield TextDelta(reply);
          }),
        );
        addTearDown(runner.close);
        await expectLater(
          IllustrationService(repository: repo, runner: runner).routePrompt(
            textConnection: text,
            connection: normal,
            nsfwConnection: nsfw,
            description: '画面描述',
          ),
          throwsA(isA<FormatException>()),
        );
        expect(calls, 1);
      },
    );
  }

  test('NSFW never falls back to an unassigned or deleted engine', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    await repo.setSetting('connections', {
      'items': [normal.raw, text.raw],
    });
    expect(await repo.connectionFor('imageNsfw'), isNull);
    await repo.setSetting('modelRoles', {'imageNsfw': 'deleted'});
    expect(await repo.connectionFor('imageNsfw'), isNull);
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (_, _) async* {
        yield const TextDelta('true');
      }),
    );
    addTearDown(runner.close);
    await expectLater(
      IllustrationService(repository: repo, runner: runner).routePrompt(
        textConnection: text,
        connection: normal,
        description: '画面描述',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('NSFW'),
        ),
      ),
    );
  });
}
