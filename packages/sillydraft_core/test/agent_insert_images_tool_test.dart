import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'task_runner_test.dart' show ScriptProvider;

class _Images implements ImageProvider {
  _Images(this.config);
  @override
  final ModelConnection config;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async => GeneratedImage(bytes: testPicture());
  @override
  void close() {}
}

void main() {
  late StoryRepository repo;
  late Chapter chapter;
  late String conversation;
  final connection = ModelConnection(
    id: 'test',
    name: 'test',
    baseUrl: 'http://localhost:1',
    model: 'test',
  );
  setUp(() async {
    repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '插画');
    chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('红伞过桥。\n白船靠岸。'),
    );
    conversation = await repo.createConversation(branchId: chapter.branchId);
  });
  tearDown(() => repo.close());

  Future<String> image(String branchId) async => (await repo.storeAsset(
    branchId: branchId,
    name: '插画',
    prepared: PreparedAsset(
      hash: 'a' * 64,
      thumbnailHash: 'b' * 64,
      width: 1,
      height: 1,
      byteLength: 1,
    ),
  )).id;
  Future<Chapter> current() =>
      repo.getChapter(branchId: chapter.branchId, chapterId: chapter.id);

  for (final outcome in [
    'complete',
    'invalid quote',
    'foreign asset',
    'foreign chapter',
    'multiline quote',
    'duplicate asset',
    'changed',
  ]) {
    test('insert_images without an image engine: $outcome', () async {
      final other = await repo.createNovel(title: '别的作品');
      final first = await image(
        outcome == 'foreign asset' ? other.activeBranchId : chapter.branchId,
      );
      final second = await image(chapter.branchId);
      final args = {
        'chapterId': outcome == 'foreign chapter' ? 'unseen' : chapter.id,
        'images': [
          {
            'assetId': first,
            'quote': switch (outcome) {
              'invalid quote' => '不存在',
              'multiline quote' => '红伞过桥。\n白船靠岸。',
              _ => '红伞过桥。',
            },
          },
          {
            'assetId': outcome == 'duplicate asset' ? first : second,
            'quote': '红伞过桥。',
          },
        ],
      };
      var calls = 0;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          final names = request.tools.map((t) => t['function']['name']);
          expect(
            names,
            outcome == 'changed' && calls > 0
                ? isNot(contains('insert_images'))
                : contains('insert_images'),
          );
          expect(names, isNot(contains('generate_image')));
          if (calls++ == 0) {
            if (outcome == 'changed') {
              await repo.saveChapter(
                branchId: chapter.branchId,
                chapterId: chapter.id,
                expectedRevisionId: chapter.revisionId,
                content: ManuscriptContent.plainText('红伞过桥。\n正文已编辑。'),
              );
            }
            yield ToolCallReady('insert', 'insert_images', args);
            yield const GenerationFinished('tool_calls');
          } else if (outcome == 'complete' && calls == 2) {
            final result =
                jsonDecode(request.messages.last['content'] as String) as Map;
            expect(result['insertedCount'], 2);
            yield ToolCallReady('repeat', 'insert_images', args);
            yield const GenerationFinished('tool_calls');
          } else {
            final result =
                jsonDecode(request.messages.last['content'] as String) as Map;
            if (outcome == 'complete') {
              expect(result['insertedCount'], 0);
            } else {
              expect(result['error'], isNotNull);
            }
            yield const TextDelta('已处理');
            yield const GenerationFinished('stop');
          }
        }),
      );
      addTearDown(runner.close);
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: connection,
        message: '把两张图片插入正文',
        focusChapterId: chapter.id,
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      final content = (await current()).content;
      expect(
        content.delta
            .where((op) => op['insert'] is Map)
            .map((op) => (op['insert'] as Map)['image']),
        outcome == 'complete' ? ['asset:$first', 'asset:$second'] : isEmpty,
      );
      if (outcome == 'changed') expect(content.text, contains('正文已编辑'));
    });
  }

  for (final batch in [false, true]) {
    test(
      'ordinary chat composes generate_${batch ? 'images' : 'image'} then insert_images',
      () async {
        final dir = Directory.systemTemp.createTempSync('insert-tool-');
        addTearDown(() => dir.deleteSync(recursive: true));
        var calls = 0;
        final runner = TaskRunner(
          repository: repo,
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          imageProviderFactory: (c) async => _Images(c),
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            if (calls++ == 0) {
              final names = request.tools.map((t) => t['function']['name']);
              expect(
                names,
                containsAll([
                  'generate_image',
                  'generate_images',
                  'insert_images',
                ]),
              );
              expect(names, isNot(contains('generate_and_insert_images')));
              yield ToolCallReady(
                'generate',
                batch ? 'generate_images' : 'generate_image',
                batch
                    ? {
                        'images': [
                          {
                            'name': '红伞',
                            'prompt': 'red umbrella',
                            'quote': '红伞过桥。',
                          },
                          {
                            'name': '白船',
                            'prompt': 'white boat',
                            'quote': '白船靠岸。',
                          },
                        ],
                      }
                    : {'name': '红伞', 'prompt': 'red umbrella'},
              );
              yield const GenerationFinished('tool_calls');
            } else if (calls == 2) {
              expect((await current()).content.text, chapter.content.text);
              final result =
                  jsonDecode(request.messages.last['content'] as String) as Map;
              final images = batch ? result['images'] as List : [result];
              yield ToolCallReady('insert', 'insert_images', {
                'chapterId': chapter.id,
                'images': [
                  for (var i = 0; i < images.length; i++)
                    {
                      'assetId': images[i]['assetId'],
                      'quote': i == 0 ? '红伞过桥。' : '白船靠岸。',
                    },
                ],
              });
              yield const GenerationFinished('tool_calls');
            } else {
              expect(
                request.messages.last['content'],
                contains('"insertedCount":${batch ? 2 : 1}'),
              );
              yield const TextDelta('两张插图已插入正文');
              yield const GenerationFinished('stop');
            }
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          attachChapterId: chapter.id,
          message: '生成两张图并插入正文',
        );
        GenerationTask pending = task;
        for (var i = 0; i < 200; i++) {
          pending = await repo.getTask(task.id);
          if (!pending.isActive ||
              pending.result['imageConfirmation'] != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(pending.result['imageConfirmation'], isNotNull);
        await runner.respondToImageConfirmation(
          task.id,
          pending.result['imageConfirmation']['id'] as String,
          approved: true,
        );
        expect((await runner.wait(task.id)).status, TaskStatus.completed);
        expect(calls, 3);
        expect(
          (await current()).content.text,
          batch ? '红伞过桥。\n\uFFFC\n白船靠岸。\n\uFFFC\n\n' : '红伞过桥。\n\uFFFC\n白船靠岸。\n',
        );
      },
    );
  }
}
