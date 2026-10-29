import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'support/image_scene.dart';
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
  late Novel novel;
  late String conversation;

  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '原书名', synopsis: '原简介');
    conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
  });
  tearDown(() => repo.close());

  Future<StoryAsset> image(String branchId, {Chapter? chapter}) =>
      repo.storeAsset(
        branchId: branchId,
        name: '封面候选',
        sourceChapterId: chapter?.id,
        sourceRevisionId: chapter?.revisionId,
        prepared: PreparedAsset(
          hash: 'a' * 64,
          thumbnailHash: 'b' * 64,
          width: 600,
          height: 800,
          byteLength: 1,
        ),
      );

  Future<List<Map<String, dynamic>>> run(
    List<ToolCallReady> calls, {
    Future<void> Function(int)? beforeCall,
  }) async {
    var round = 0;
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        final names = request.tools.map((t) => t['function']['name']);
        expect(names, containsAll(['read_novel', 'update_novel']));
        expect(names, isNot(contains('generate_image')));
        if (round < calls.length) {
          await beforeCall?.call(round);
          yield calls[round++];
          yield const GenerationFinished('tool_calls');
        } else {
          yield const TextDelta('已处理');
          yield const GenerationFinished('stop');
        }
      }),
    );
    addTearDown(runner.close);
    final task = await EditorAgent(repository: repo, runner: runner).send(
      conversationId: conversation,
      connection: ModelConnection(
        id: 'test',
        name: 'test',
        baseUrl: 'http://localhost:1',
        model: 'test',
      ),
      message: '修改书名、简介和封面',
    );
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    return [
      for (final m in await repo.getAgentMessages(conversation))
        if (m.role == 'tool') jsonDecode(m.content) as Map<String, dynamic>,
    ];
  }

  test('reads current metadata and only visible cover candidates', () async {
    final first = await repo.createChapter(branchId: novel.activeBranchId);
    final later = await repo.createChapter(branchId: novel.activeBranchId);
    conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
      throughChapterId: first.id,
    );
    final visible = await image(novel.activeBranchId, chapter: first);
    final unscoped = await image(novel.activeBranchId);
    await repo.setCover(novel.id, visible.id);
    await image(novel.activeBranchId, chapter: later);
    final archived = await image(novel.activeBranchId);
    await repo.archiveAsset(archived.id, archived: true);
    final fork = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: '另一分支',
    );
    await image(fork.id);
    final other = await repo.createNovel(title: '其他作品');
    await image(other.activeBranchId);

    final result = (await run([ToolCallReady('read', 'read_novel', {})]))
        .single;
    expect(result['title'], '原书名');
    expect(result['synopsis'], '原简介');
    expect(result['coverAssetId'], visible.id);
    expect(
      (result['coverCandidates'] as List).map((a) => a['assetId']),
      unorderedEquals([visible.id, unscoped.id]),
    );
  });

  test('partial updates preserve fresh unrelated metadata and cover', () async {
    final cover = await image(novel.activeBranchId);
    final fork = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: '另一分支',
    );
    final results = await run(
      [
        ToolCallReady('update', 'update_novel', {
          'title': ' 新书名 ',
          'synopsis': '新简介',
        }),
        ToolCallReady('read', 'read_novel', {}),
      ],
      beforeCall: (round) async {
        if (round != 0) return;
        await repo.updateNovel(
          (await repo.getNovel(novel.id)).copyWith(
            genre: '悬疑',
            style: '简洁',
            language: 'en',
            pointOfView: '第一人称',
            activeBranchId: fork.id,
            coverAssetId: cover.id,
            chapterNumerals: ChapterNumerals.arabic,
            archived: true,
          ),
        );
      },
    );
    expect(results.first['updated'], true);
    expect(results.last['title'], '新书名');
    expect(results.last['synopsis'], '新简介');
    expect(results.last['coverAssetId'], cover.id);
    final saved = await repo.getNovel(novel.id);
    expect(saved.genre, '悬疑');
    expect(saved.style, '简洁');
    expect(saved.language, 'en');
    expect(saved.pointOfView, '第一人称');
    expect(saved.activeBranchId, fork.id);
    expect(saved.chapterNumerals, ChapterNumerals.arabic);
    expect(saved.archived, true);
  });

  test('sets and clears cover and allows empty synopsis', () async {
    final cover = await image(novel.activeBranchId);
    final results = await run([
      ToolCallReady('cover', 'update_novel', {'coverAssetId': cover.id}),
      ToolCallReady('title', 'update_novel', {'title': '新书名'}),
      ToolCallReady('clear', 'update_novel', {
        'coverAssetId': null,
        'synopsis': '',
      }),
    ]);
    expect(results[0]['coverAssetId'], cover.id);
    expect(results[0]['title'], '原书名');
    expect(results[1]['coverAssetId'], cover.id);
    expect(results[1]['synopsis'], '原简介');
    expect(results[2]['updated'], true);
    final saved = await repo.getNovel(novel.id);
    expect(saved.title, '新书名');
    expect(saved.synopsis, isEmpty);
    expect(saved.coverAssetId, isNull);
  });

  for (final setAsCover in [false, true]) {
    test(
      'generated image becomes cover only through update_novel: $setAsCover',
      () async {
        final dir = Directory.systemTemp.createTempSync('novel-cover-tool-');
        addTearDown(() => dir.deleteSync(recursive: true));
        conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
          title: '封面',
        );
        var round = 0;
        String? assetId;
        final runner = TaskRunner(
          repository: repo,
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          imageProviderFactory: (c) async => _Images(c),
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            if (round++ == 0) {
              yield ToolCallReady('generate', 'generate_image', {
                ...emptyImageContext,
                'name': '封面',
                'prompt': 'red umbrella',
              });
              yield const GenerationFinished('tool_calls');
              return;
            }
            if (round == 2) {
              final result =
                  jsonDecode(request.messages.last['content'] as String) as Map;
              expect(result['status'], 'completed');
              assetId = result['assetId'] as String;
              if (setAsCover) {
                yield ToolCallReady('cover', 'update_novel', {
                  'coverAssetId': assetId,
                });
                yield const GenerationFinished('tool_calls');
                return;
              }
            }
            yield const TextDelta('已完成');
            yield const GenerationFinished('stop');
          }),
        );
        addTearDown(runner.close);
        final connection = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          message: setAsCover ? '生成一张图并设为封面' : '生成一张图',
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
        expect(await repo.listAssets(novel.id), isEmpty);
        expect((await repo.getNovel(novel.id)).coverAssetId, isNull);
        await runner.respondToImageConfirmation(
          task.id,
          pending.result['imageConfirmation']['id'] as String,
          approved: true,
        );
        final done = await runner.wait(task.id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect(round, setAsCover ? 3 : 2);
        expect(assetId, isNotNull);
        expect((await repo.listAssets(novel.id)).single.id, assetId);
        expect(
          (await repo.getNovel(novel.id)).coverAssetId,
          setAsCover ? assetId : isNull,
        );
      },
    );
  }

  for (final foreign in [false, true]) {
    test(
      'invalid cover leaves all fields unchanged (foreign=$foreign)',
      () async {
        final current = await image(novel.activeBranchId);
        await repo.setCover(novel.id, current.id);
        final other = await repo.createNovel(title: '其他作品');
        final cover = await image(other.activeBranchId);
        final result = (await run([
          ToolCallReady('update', 'update_novel', {
            'title': '不应保存',
            'synopsis': '不应保存',
            'coverAssetId': foreign ? cover.id : 'missing',
          }),
        ])).single;
        expect(result['error'], isNotNull);
        expect(result['updated'], isNot(true));
        final saved = await repo.getNovel(novel.id);
        expect(saved.title, novel.title);
        expect(saved.synopsis, novel.synopsis);
        expect(saved.coverAssetId, current.id);
        expect((await repo.getNovel(other.id)).coverAssetId, isNull);
      },
    );
  }

  for (final args in <Map<String, dynamic>>[
    {},
    {'title': ''},
    {'title': '   '},
    {'title': null},
    {'title': 123},
    {'title': '不应保存', 'synopsis': null},
    {'title': '不应保存', 'synopsis': <String>[]},
    {'title': '不应保存', 'coverAssetId': ''},
    {'title': '不应保存', 'coverAssetId': 42},
    {'title': '不应保存', 'novelId': 'other'},
    {'title': '不应保存', 'activeBranchId': 'other'},
  ]) {
    test('rejects invalid update arguments: $args', () async {
      final result = (await run([ToolCallReady('bad', 'update_novel', args)]))
          .single;
      expect(result['code'], 'invalid_arguments');
      expect((await repo.getNovel(novel.id)).title, novel.title);
      expect((await repo.getNovel(novel.id)).synopsis, novel.synopsis);
    });
  }
}
