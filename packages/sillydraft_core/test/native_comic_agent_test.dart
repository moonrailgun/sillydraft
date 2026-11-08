import 'dart:convert';
import 'dart:io';

import 'asset_library_test.dart' show testPicture;
import 'comic_task_test.dart' show ComicImageModel;

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  for (final stale in [false, true]) {
    test(
      'assistant saves original storyboard without prose (stale=$stale)',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(
          title: '漫画',
          workFormat: WorkFormat.comic,
        );
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final config = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        var rounds = 0, plans = 0;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (r, _) async* {
            if (r.tools.isNotEmpty) {
              rounds++;
              if (rounds == 1) {
                final names = r.tools
                    .map((t) => t['function']['name'])
                    .toList();
                expect(
                  names,
                  containsAll([
                    'read_comic',
                    'plan_comic',
                    'edit_comic',
                    'draw_comic',
                    'continue_comic',
                  ]),
                );
                expect(names, isNot(contains('propose_chapter')));
                expect(names, isNot(contains('insert_images')));
                if (stale) {
                  await repo.renameChapter(
                    branchId: novel.activeBranchId,
                    chapterId: chapter.id,
                    name: '已修改',
                  );
                }
                yield ToolCallReady('plan', 'plan_comic', {
                  'chapterId': chapter.id,
                  'instruction': '雨夜收到短信',
                });
                yield const GenerationFinished('tool_calls');
              } else {
                final result =
                    jsonDecode(r.messages.last['content'] as String) as Map;
                if (stale) {
                  expect(result['code'], 'source_changed');
                } else {
                  expect(result['saved'], true);
                  expect(result['revisionId'], isNotNull);
                }
                yield const TextDelta('完成');
                yield const GenerationFinished('stop');
              }
            } else {
              final stage = (r.messages.first['content'] as String)
                  .split('\n')
                  .first;
              if (stage == 'COMIC/original-plan') {
                plans++;
                yield TextDelta(
                  jsonEncode({
                    'panels': [
                      {
                        'id': 'p1',
                        'factIds': <String>[],
                        'sceneId': 'rain',
                        'description': '女孩看手机',
                        'continuity': '蓝衣女孩',
                        'texts': [
                          {'kind': 'dialogue', 'speaker': '女孩', 'text': '谁？'},
                        ],
                        'referenceAssetIds': <String>[],
                      },
                    ],
                    'continuity': '收到短信',
                  }),
                );
              } else {
                expect(stage, 'COMIC/original-audit');
                yield const TextDelta('{"issues":[]}');
              }
              yield const GenerationFinished('stop');
            }
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: config,
          message: '画分镜',
          focusChapterId: chapter.id,
        );
        final done = await runner.wait(task.id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        final comic = await repo.getComic(novel.activeBranchId, chapter.id);
        expect(comic == null, stale);
        expect(plans, stale ? 0 : 1);
        expect(
          (await repo.getChapter(
            branchId: novel.activeBranchId,
            chapterId: chapter.id,
          )).content.text.trim(),
          isEmpty,
        );
      },
    );
  }
  for (final approve in [false, true]) {
    test(
      'assistant plans, edits, draws and continues with approval=$approve',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final dir = await Directory.systemTemp.createTemp('comic-agent-');
        addTearDown(() => dir.delete(recursive: true));
        final novel = await repo.createNovel(
          title: '漫画',
          workFormat: WorkFormat.comic,
        );
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final config = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
          kind: ModelKind.both,
        );
        var targetId = chapter.id;
        var round = 0, images = 0, confirmations = 0;
        final runner = TaskRunner(
          repository: repo,
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          providerFactory: (c) async => ScriptProvider(c, (r, _) async* {
            if (r.tools.isNotEmpty) {
              round++;
              final result = round == 1
                  ? null
                  : jsonDecode(r.messages.last['content'] as String) as Map;
              if (round > 1) expect(result!['saved'], isTrue);
              switch (round) {
                case 1:
                  yield ToolCallReady('plan', 'plan_comic', {
                    'chapterId': targetId,
                    'instruction': '雨夜收到短信',
                  });
                case 2:
                  final panel =
                      ((result!['document'] as Map)['panels'] as List).first
                          as Map;
                  yield ToolCallReady('edit', 'edit_comic', {
                    'chapterId': targetId,
                    'panelId': panel['id'],
                    'description': '女孩抬头看车门',
                  });
                case 3:
                  yield ToolCallReady('draw', 'draw_comic', {
                    'chapterId': targetId,
                  });
                case 4:
                  yield ToolCallReady('continue', 'continue_comic', {
                    'chapterId': targetId,
                    'instruction': '女孩走到车门前',
                  });
                default:
                  yield const TextDelta('已保存');
                  yield const GenerationFinished('stop');
                  return;
              }
              yield const GenerationFinished('tool_calls');
            } else {
              final stage = (r.messages.first['content'] as String)
                  .split('\n')
                  .first;
              final body = switch (stage) {
                'COMIC/original-plan' => {
                  'panels': [
                    {
                      'id': 'p1',
                      'factIds': <String>[],
                      'sceneId': 'rain',
                      'description': '女孩看手机',
                      'continuity': '蓝衣女孩',
                      'texts': [
                        {'kind': 'dialogue', 'speaker': '女孩', 'text': '谁？'},
                      ],
                      'referenceAssetIds': <String>[],
                    },
                  ],
                  'continuity': '收到短信',
                },
                'COMIC/original-audit' => {'issues': <dynamic>[]},
                'COMIC/image-rating' => {'nsfw': false},
                'COMIC/page-prompt' => {'prompt': '完整漫画页，女孩说“谁？”'},
                _ => throw StateError(stage),
              };
              yield TextDelta(jsonEncode(body));
              yield const GenerationFinished('stop');
            }
          }),
          imageProviderFactory: (c) async =>
              ComicImageModel(c, (r, refs) async {
                images++;
                expect(confirmations, images);
                return GeneratedImage(bytes: testPicture());
              }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: config,
          imageConnection: config,
          message: '先出分镜，修改后画出来，再画下一页',
          focusChapterId: chapter.id,
        );
        final seen = <String>{};
        for (var i = 0; i < 1000; i++) {
          final pending = await repo.getTask(task.id);
          if (!pending.isActive) break;
          final confirmation = pending.result['imageConfirmation'] as Map?;
          if (confirmation != null && seen.add(confirmation['id'] as String)) {
            expect(images, confirmations);
            confirmations++;
            await runner.respondToImageConfirmation(
              task.id,
              confirmation['id'] as String,
              approved: approve,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final done = await runner
            .wait(task.id)
            .timeout(const Duration(seconds: 5));
        expect(
          done.status,
          approve ? TaskStatus.completed : TaskStatus.cancelled,
          reason: done.error,
        );
        expect(confirmations, approve ? 2 : 1);
        expect(images, approve ? 2 : 0);
        final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
        expect(head.document.pages, hasLength(approve ? 2 : 1));
        expect(head.document.complete, approve);
        expect(
          (await repo.getChapter(
            branchId: novel.activeBranchId,
            chapterId: chapter.id,
          )).content.text.trim(),
          isEmpty,
        );
        if (approve) {
          final copy = (await repo.exportProject(novel.id)).copy();
          final snapshotJson = copy.snapshot.toJson();
          final tasks =
              (snapshotJson['tables'] as Map)['generation_tasks'] as List;
          tasks.cast<Map>().singleWhere(
            (row) => row['id'] == copy.ids[task.id],
          )['status'] = 'interrupted';
          await repo.restoreProject(
            ProjectSnapshot.fromJson(snapshotJson),
            encryptedSources: {},
          );
          targetId = copy.ids[chapter.id]!;
          final copiedTask = await repo.getTask(copy.ids[task.id]!);
          expect(
            (copiedTask.input['comicSnapshot'] as Map).keys,
            contains(targetId),
          );
          round = 0;
          final replay = await runner
              .wait((await runner.resume(copiedTask.id)).id)
              .timeout(const Duration(seconds: 5));
          expect(replay.status, TaskStatus.completed, reason: replay.error);
          expect(images, 2);
        }
        if (!approve) {
          final calls = (done.result['agentComicCalls'] as Map).values
              .cast<Map>();
          expect(calls.last['result']['cancelled'], isTrue);
        }
      },
    );
  }
}
