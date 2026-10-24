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
