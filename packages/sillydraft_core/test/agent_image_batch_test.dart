import 'support/image_scene.dart';

import 'dart:async';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
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

Future<GenerationTask> _pending(StoryRepository repo, String id) async {
  for (var i = 0; i < 200; i++) {
    final task = await repo.getTask(id);
    if (!task.isActive || task.result['imageConfirmation'] != null) return task;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('No batch confirmation');
}

void main() {
  test('invalid saved highlight counts do not start a task', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (_) async =>
          fail('Invalid counts must not call a model'),
    );
    addTearDown(runner.close);
    final novel = await repo.createNovel(title: '亮点数量');
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    final connection = ModelConnection(
      id: 'test',
      name: 'test',
      baseUrl: 'http://localhost:1',
      model: 'test',
    );
    final agent = EditorAgent(repository: repo, runner: runner);
    for (final count in [0, 7, '2', 1.5]) {
      await repo.setSetting('chapterHighlights', {'count': count});
      await expectLater(
        agent.send(
          conversationId: conversation,
          connection: connection,
          illustrationBatch: true,
          message: '本章亮点生图',
        ),
        throwsFormatException,
      );
    }
    expect(await repo.listTasks(branchId: novel.activeBranchId), isEmpty);
    expect(await repo.getAgentMessages(conversation), isEmpty);
  });

  for (final count in <int?>[null, 1, 6]) {
    test(
      'highlight count $count is frozen for queued tasks and resends',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '亮点数量');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('红伞过桥。'),
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final connection = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        if (count != null) {
          await repo.setSetting('chapterHighlights', {'count': count});
        }
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            final tool = request.tools.singleWhere(
              (t) => t['function']['name'] == 'generate_images',
            );
            final images =
                tool['function']['parameters']['properties']['images'];
            expect(images['minItems'], count ?? 1);
            expect(images['maxItems'], count ?? 6);
            expect(
              request.messages.first['content'],
              contains(count == null ? '由 AI 根据章节内容决定' : '恰好 $count 个'),
            );
            yield ToolCallReady('batch', 'generate_images', {
              'images': [
                for (var i = 0; i < (count ?? 2); i++)
                  {
                    'name': '画面 $i',
                    ...emptyImageContext,
                    'prompt': 'red umbrella $i',
                    'quote': '红伞过桥。',
                  },
              ],
            });
            yield const GenerationFinished('tool_calls');
          }),
        );
        addTearDown(runner.close);
        final agent = EditorAgent(repository: repo, runner: runner);
        var task = await agent.send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          attachChapterId: chapter.id,
          illustrationBatch: true,
          message: '本章亮点生图',
        );
        expect(task.input['pendingAgent']['illustrationCount'], count);
        await repo.setSetting('chapterHighlights', {
          'count': count == 1 ? 6 : 1,
        });
        for (var attempt = 0; attempt < 2; attempt++) {
          final pending = await _pending(repo, task.id);
          expect(pending.input['illustrationCount'], count);
          final confirmation = pending.result['imageConfirmation'] as Map;
          expect(confirmation['images'], hasLength(count ?? 2));
          await runner.respondToImageConfirmation(
            task.id,
            confirmation['id'] as String,
            approved: false,
          );
          await runner.wait(task.id);
          final source = (await repo.getAgentMessages(conversation))
              .firstWhere((m) => m.role == 'user');
          expect(source.raw['illustrationCount'], count);
          if (attempt == 0) {
            task = await agent.send(
              conversationId: conversation,
              connection: connection,
              imageConnection: connection,
              attachChapterId: chapter.id,
              replaceMessageId: source.id,
              message: '本章亮点生图',
            );
          }
        }
      },
    );
  }

  for (final submitted in [1, 3]) {
    test(
      'fixed highlight count corrects $submitted images before confirmation',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        await repo.setSetting('chapterHighlights', {'count': 2});
        final novel = await repo.createNovel(title: '亮点数量');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('红伞过桥。'),
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final connection = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        var modelCalls = 0;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            modelCalls++;
            if (modelCalls == 2) {
              expect(request.messages.last['role'], 'tool');
              expect(
                request.messages.last['content'],
                contains('image_count_mismatch'),
              );
              expect(
                request.messages.last['content'],
                contains('请一次提交 2 张本章亮点插图'),
              );
              final tasks = await repo.listTasks(
                branchId: novel.activeBranchId,
              );
              expect(tasks, hasLength(1));
              expect(tasks.single.result['imageConfirmation'], isNull);
              expect(await repo.listAssets(novel.id), isEmpty);
            }
            yield ToolCallReady('batch', 'generate_images', {
              'images': [
                for (var i = 0; i < (modelCalls == 1 ? submitted : 2); i++)
                  {
                    'name': '画面 $i',
                    ...emptyImageContext,
                    'prompt': 'red umbrella $i',
                    'quote': '红伞过桥。',
                  },
              ],
            });
            yield const GenerationFinished('tool_calls');
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          attachChapterId: chapter.id,
          illustrationBatch: true,
          message: '本章亮点生图',
        );
        final pending = await _pending(repo, task.id);
        expect(modelCalls, 2);
        final confirmation = pending.result['imageConfirmation'] as Map;
        expect(confirmation['images'], hasLength(2));
        await runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: false,
        );
        await runner.wait(task.id);
        expect((await repo.getTask(task.id)).status, TaskStatus.cancelled);
        expect(await repo.listAssets(novel.id), isEmpty);
      },
    );
  }

  for (final (illustrationBatch, outcome) in [
    for (final outcome in [
      'complete',
      'reject',
      'fail',
      'cancel',
      'invalid',
      'missing quote',
      'ambiguous quote',
      'changed',
    ])
      (true, outcome),
    for (final outcome in ['complete', 'reject', 'fail', 'cancel'])
      (false, outcome),
  ]) {
    test(
      '${illustrationBatch ? 'chapter' : 'chat'} image batch: $outcome, one approval and serial calls',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        if (!illustrationBatch) {
          await repo.setSetting('chapterHighlights', {'count': 1});
        }
        final dir = Directory.systemTemp.createTempSync('image-batch-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final novel = await repo.createNovel(title: '雾港');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          title: '渡口',
          content: ManuscriptContent.plainText('红伞过桥。\n白船靠岸。\n灯塔亮起。\n红伞。红伞。'),
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final connection = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        final prompts = <String>[];
        final entered = Completer<void>(), release = Completer<void>();
        var modelCalls = 0;
        final runner = TaskRunner(
          repository: repo,
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            modelCalls++;
            if (!illustrationBatch && modelCalls == 2) {
              expect(request.messages.last['content'], contains('completed'));
              expect(
                (await repo.getChapter(
                  branchId: chapter.branchId,
                  chapterId: chapter.id,
                )).revisionId,
                chapter.revisionId,
              );
              yield const TextDelta('图片已生成');
              yield const GenerationFinished('stop');
              return;
            }
            final names = [
              for (final tool in request.tools) tool['function']['name'],
            ];
            expect(names, contains('generate_images'));
            expect(
              names,
              illustrationBatch
                  ? isNot(contains('generate_image'))
                  : contains('generate_image'),
            );
            expect(
              names,
              illustrationBatch
                  ? isNot(contains('propose_chapter'))
                  : contains('propose_chapter'),
            );
            expect(request.messages.toString(), contains(chapter.content.text));
            yield ToolCallReady('batch', 'generate_images', {
              'images': [
                for (final prompt in [
                  'red umbrella',
                  'white boat',
                  'lighthouse',
                ])
                  {
                    'name': prompt,
                    'quote': outcome == 'missing quote'
                        ? '不存在的段落'
                        : outcome == 'ambiguous quote'
                        ? '红伞'
                        : switch (prompt) {
                            'red umbrella' => '红伞过桥。',
                            'white boat' => '白船靠岸。',
                            _ => '灯塔亮起。',
                          },
                    ...emptyImageContext,
                    'prompt': outcome == 'invalid' && prompt == 'white boat'
                        ? ''
                        : prompt,
                  },
              ],
            });
            yield const GenerationFinished('tool_calls');
          }),
          imageProviderFactory: (c) async => _Images(c, (request) async {
            prompts.add(request.prompt);
            if (prompts.length == 1) {
              entered.complete();
              await release.future;
            }
            if (outcome == 'fail' && prompts.length == 2) {
              throw const ProviderException('service_error', '第二张失败');
            }
            return GeneratedImage(bytes: testPicture());
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          attachChapterId: chapter.id,
          illustrationBatch: illustrationBatch,
          message: '提取本章亮点并批量生图',
        );
        final pending = await _pending(repo, task.id);
        if (['invalid', 'missing quote', 'ambiguous quote'].contains(outcome)) {
          expect(pending.status, TaskStatus.failed);
          expect(pending.result['imageConfirmation'], isNull);
          expect(prompts, isEmpty);
          expect(await repo.listAssets(novel.id), isEmpty);
          return;
        }
        final confirmation = pending.result['imageConfirmation'] as Map;
        expect(confirmation['images'], hasLength(3));
        expect(prompts, isEmpty);
        expect(
          (await repo.listTasks(branchId: novel.activeBranchId))
              .where((t) => t.kind == TaskKind.illustration),
          isEmpty,
        );
        expect(
          await runner.respondToImageConfirmation(
            task.id,
            confirmation['id'] as String,
            approved: outcome != 'reject',
          ),
          isTrue,
        );
        expect(
          await runner.respondToImageConfirmation(
            task.id,
            confirmation['id'] as String,
            approved: true,
          ),
          isFalse,
        );
        if (outcome != 'reject') {
          await entered.future.timeout(const Duration(seconds: 2));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(prompts, ['red umbrella']);
          expect(
            (await repo.listTasks(branchId: novel.activeBranchId))
                .where((t) => t.kind == TaskKind.illustration),
            hasLength(1),
          );
          if (outcome == 'cancel') await runner.cancel(task.id);
          release.complete();
        }
        final done = await runner.wait(task.id);
        expect(done.status, switch (outcome) {
          'complete' || 'changed' => TaskStatus.completed,
          'fail' => TaskStatus.failed,
          _ => TaskStatus.cancelled,
        });
        expect(prompts.length, switch (outcome) {
          'complete' || 'changed' => 3,
          'fail' => 2,
          'cancel' => 1,
          _ => 0,
        });
        expect(modelCalls, !illustrationBatch && outcome == 'complete' ? 2 : 1);
        final assets = await repo.listAssets(novel.id);
        expect(
          assets.length,
          (outcome == 'complete' || outcome == 'changed')
              ? 3
              : outcome == 'fail'
              ? 1
              : 0,
        );
        if (outcome == 'fail') expect(done.error, contains('第二张失败'));
        if (['complete', 'changed', 'fail'].contains(outcome)) {
          expect(done.result['assetIds'], hasLength(assets.length));
          final messages = await repo.getAgentMessages(conversation);
          final result = messages
              .where((m) => m.raw['tool_name'] == 'generate_images')
              .single;
          for (final asset in assets) {
            expect(result.content, contains(asset.id));
          }
          final source = messages.firstWhere((m) => m.role == 'user');
          if (outcome == 'changed') {
            await repo.saveChapter(
              branchId: chapter.branchId,
              chapterId: chapter.id,
              expectedRevisionId: chapter.revisionId,
              content: ManuscriptContent.plainText('红伞过桥。\n白船已经离岸。'),
            );
            await expectLater(
              repo.insertAgentIllustration(
                branchId: chapter.branchId,
                assetId: assets.first.id,
                source: source,
              ),
              throwsA(isA<RevisionConflict>()),
            );
            return;
          }
          if (outcome == 'complete') {
            final byName = {for (final asset in assets) asset.name: asset.id};
            for (final name in ['white boat', 'red umbrella', 'lighthouse']) {
              await repo.insertAgentIllustration(
                branchId: chapter.branchId,
                assetId: byName[name]!,
                source: source,
              );
            }
            final inserted = await repo.getChapter(
              branchId: chapter.branchId,
              chapterId: chapter.id,
            );
            expect(
              inserted.content.text,
              '红伞过桥。\n\uFFFC\n白船靠岸。\n\uFFFC\n灯塔亮起。\n\uFFFC\n红伞。红伞。\n',
            );
            expect(
              inserted.content.delta
                  .where((op) => op['insert'] is Map)
                  .map((op) => (op['insert'] as Map)['image']),
              [
                'asset:${byName['red umbrella']}',
                'asset:${byName['white boat']}',
                'asset:${byName['lighthouse']}',
              ],
            );
            await expectLater(
              repo.insertAgentIllustration(
                branchId: chapter.branchId,
                assetId: byName['red umbrella']!,
                source: source,
              ),
              throwsFormatException,
            );
            return;
          }
        }
        expect(
          (await repo.getStory(novel.activeBranchId))
              .chapters
              .single
              .content
              .text,
          chapter.content.text,
        );
      },
    );
  }
}
