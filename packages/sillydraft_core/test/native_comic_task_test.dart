import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'comic_export_test.dart' show checkedComic;
import 'comic_store_test.dart' show comicFixture;
import 'comic_task_test.dart' show ComicTextModel, ComicImageModel;

void main() {
  late StoryRepository repo;
  late TaskRunner runner;
  late ComicService service;
  late Novel novel;
  late Chapter chapter;
  late ModelConnection connection;
  late AssetLibrary library;
  late List<ProviderRequest> requests;
  var images = 0;
  // Planned characters; null keeps the plan output without the field.
  List<String>? cast;
  // Reference count each image request received.
  var imageRefs = <int>[];
  // Gate only this image (1-based); null gates every image.
  int? gatedImage;
  var failAudit = false;
  var auditIssues = <String>[];
  List<String>? stages;
  Completer<void>? imageGate, imageStarted;
  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '漫画', workFormat: WorkFormat.comic);
    chapter = await repo.createChapter(branchId: novel.activeBranchId);
    connection = ModelConnection(
      id: 'test',
      name: 'test',
      baseUrl: 'http://localhost:1',
      model: 'test',
      kind: ModelKind.both,
      maxOutputTokens: 8192,
    );
    requests = [];
    images = 0;
    failAudit = false;
    auditIssues = [];
    stages = null;
    cast = null;
    imageRefs = [];
    gatedImage = null;
    imageGate = imageStarted = null;
    final directory = await Directory.systemTemp.createTemp('native-comic-');
    addTearDown(() => directory.delete(recursive: true));
    // Records the running comic task's stage whenever a model is opened.
    Future<void> recordStage() async {
      if (stages == null) return;
      for (final t in await repo.listTasks(activeOnly: true)) {
        final stage = t.result['comicStage'];
        if (t.kind == TaskKind.comic &&
            stage is String &&
            stages!.lastOrNull != stage) {
          stages!.add(stage);
        }
      }
    }

    library = AssetLibrary(repository: repo, directory: directory);
    runner = TaskRunner(
      repository: repo,
      assetLibrary: library,
      providerFactory: (c) async {
        await recordStage();
        return ComicTextModel(c, (r) {
          requests.add(r);
          final stage = (r.messages.first['content'] as String)
              .split('\n')
              .first;
          switch (stage) {
            case 'COMIC/original-plan':
              return jsonEncode({
                'panels': [
                  {
                    'id': 'p1',
                    'factIds': <String>[],
                    'sceneId': 'train',
                    'description': '女孩看手机',
                    'continuity': '蓝衣女孩',
                    'texts': [
                      {'kind': 'dialogue', 'speaker': '女孩', 'text': '谁？'},
                    ],
                    'referenceAssetIds': <String>[],
                  },
                  {
                    'id': 'p2',
                    'factIds': <String>[],
                    'sceneId': 'train',
                    'description': '手机发亮',
                    'continuity': '蓝衣女孩',
                    'texts': <dynamic>[],
                    'referenceAssetIds': <String>[],
                  },
                ],
                'continuity': '女孩收到短信',
                if (cast != null)
                  'characters': [
                    for (final name in cast!)
                      {'name': name, 'prompt': '$name的固定外观'},
                  ],
              });
            case 'COMIC/original-audit':
              if (failAudit) throw StateError('audit offline');
              return jsonEncode({'issues': auditIssues});
            case 'COMIC/directions':
              return jsonEncode({
                'directions': List.generate(
                  3,
                  (i) => {
                    'title': '方向$i',
                    'summary': '查看车厢$i',
                    'event': '女孩走向车厢$i',
                  },
                ),
              });
            case 'COMIC/image-rating':
              return '{"nsfw":false}';
            case 'COMIC/page-prompt':
              return '{"prompt":"完整漫画页，两格，气泡对白：谁？"}';
            default:
              throw StateError(stage);
          }
        });
      },
      imageProviderFactory: (c) async {
        await recordStage();
        return ComicImageModel(c, (r, refs) async {
          final n = ++images;
          imageRefs.add(refs.length);
          if (gatedImage == null || gatedImage == n) {
            if (imageStarted?.isCompleted == false) imageStarted!.complete();
            await imageGate?.future;
          }
          if (!r.prompt.startsWith('Single character reference')) {
            expect(r.prompt, contains('谁？'));
          }
          return GeneratedImage(bytes: testPicture());
        });
      },
    );
    service = ComicService(repository: repo, runner: runner);
  });
  tearDown(() async {
    await runner.close();
    await repo.close();
  });
  Future<GenerationTask> compose({
    bool draw = true,
    String? head,
    bool sheets = false,
  }) async => runner.wait(
    (await service.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到未来短信',
      connection: connection,
      imageConnection: draw ? connection : null,
      expectedRevisionId: head,
      characterSheets: sheets,
    )).id,
  );
  Future<LoreEntry> character(String name) async => (await repo.listLore(
    novel.activeBranchId,
    kind: LoreKind.character,
  )).singleWhere((e) => e.name == name);
  Future<List<String>> pageRefs(Map<String, dynamic> page) async => [
    for (final ref
        in (await repo.getTask(page['imageTaskId'] as String))
                .input['references']
            as List)
      ref['id'] as String,
  ];
  // Opening with four characters, then a page adding a fifth.
  Future<void> twoPages() async {
    cast = ['林夏', '周野', '老陈', '小满'];
    final first = await compose(sheets: true);
    expect(first.status, TaskStatus.completed, reason: first.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    cast = ['林夏', '周野', '阿杰'];
    final next = await compose(head: head.id, sheets: true);
    expect(next.status, TaskStatus.completed, reason: next.error);
  }

  test('opening draws up to three sheets then the page', () async {
    cast = ['林夏', '周野', '老陈', '小满'];
    stages = [];
    final task = await compose(sheets: true);
    expect(task.status, TaskStatus.completed, reason: task.error);
    expect(images, 4);
    final lore = await repo.listLore(
      novel.activeBranchId,
      kind: LoreKind.character,
    );
    expect(lore.map((e) => e.name), unorderedEquals(cast!));
    final sheets = [
      for (final name in cast!.take(3))
        ((await character(name)).data['images'] as List).single as String,
    ];
    final extra = await character('小满');
    expect(extra.data['images'], isNull);
    expect(extra.data['referencePrompt'], '小满的固定外观');
    expect(extra.certainty, LoreCertainty.inference);
    final page = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document.pages.single;
    expect(page['characters'], cast);
    expect(await pageRefs(page), sheets);
    expect(imageRefs.last, 3);
    expect(imageRefs.last, lessThanOrEqualTo(referenceLimit(connection)));
    expect(stages, ['plan', 'check', 'sheets', 'page']);
  });
  test('later pages reuse sheets and never draw new ones', () async {
    await twoPages();
    expect(images, 5);
    final newcomer = await character('阿杰');
    expect(newcomer.data['images'], isNull);
    expect(
      await repo.listLore(novel.activeBranchId, kind: LoreKind.character),
      hasLength(5),
    );
    final pages = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document.pages;
    expect(await pageRefs(pages.last), [
      ((await character('林夏')).data['images'] as List).single,
      ((await character('周野')).data['images'] as List).single,
      pages.first['assetId'],
    ]);
  });
  test('manual page references override automatic ones', () async {
    await twoPages();
    final gallery = await library.importImage(
      branchId: novel.activeBranchId,
      name: '插图',
      bytes: testPicture(),
    );
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final json = head.document.toJson();
    (json['pages'] as List).last['referenceAssetIds'] = [gallery.id];
    final saved = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: ComicDocument.fromJson(json),
      expectedRevisionId: head.id,
    );
    final draw = await runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
        panelId: saved.document.lastPageId,
        expectedRevisionId: saved.id,
      )).id,
    );
    expect(draw.status, TaskStatus.completed, reason: draw.error);
    expect(images, 6);
    final refs = await pageRefs(
      (await repo.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document.pages.last,
    );
    expect(refs.first, gallery.id);
    final sheets = {
      for (final e in await repo.listLore(
        novel.activeBranchId,
        kind: LoreKind.character,
      ))
        ...(e.data['images'] as List? ?? []),
    };
    expect(sheets, hasLength(3));
    expect(refs.where(sheets.contains), isEmpty);
  });
  test('sheet resume reuses finished child', () async {
    cast = ['林夏', '周野', '老陈'];
    gatedImage = 1;
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    addTearDown(() {
      if (!imageGate!.isCompleted) imageGate!.complete();
    });
    final task = await service.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到未来短信',
      connection: connection,
      imageConnection: connection,
      characterSheets: true,
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    // Two same-named entries make saving the finished sheet fail.
    final duplicates = [
      for (var i = 0; i < 2; i++)
        await repo.saveLoreEntry(
          branchId: novel.activeBranchId,
          kind: LoreKind.character,
          name: '林夏',
          content: '短发',
        ),
    ];
    imageGate!.complete();
    final failed = await runner.wait(task.id);
    expect(failed.status, TaskStatus.failed);
    expect(images, 1);
    final child = await repo.getTask(
      (failed.result['comicSheetChildren'] as Map)['林夏'] as String,
    );
    final asset = child.result['assetId'] as String;
    expect(
      (await repo.listLore(
        novel.activeBranchId,
        kind: LoreKind.character,
      )).where((e) => e.data['images'] != null),
      isEmpty,
    );
    await repo.deleteLoreEntry(
      branchId: novel.activeBranchId,
      id: duplicates.last.id,
      expectedRevisionId: duplicates.last.revisionId,
    );
    final resumed = await runner.wait((await runner.resume(task.id)).id);
    expect(resumed.status, TaskStatus.completed, reason: resumed.error);
    // The finished sheet is saved, not ordered again: two sheets and the page.
    expect(images, 4);
    expect((await character('林夏')).data['images'], [asset]);
  });
  test('copied work remaps sheet children', () async {
    cast = ['林夏', '周野'];
    final task = await compose(sheets: true);
    expect(task.status, TaskStatus.completed, reason: task.error);
    final children = task.result['comicSheetChildren'] as Map;
    expect(children, hasLength(2));
    final copy = (await repo.exportProject(novel.id)).copy();
    final restored = await repo.restoreProject(
      copy.snapshot,
      encryptedSources: {},
    );
    expect(
      (await repo.getTask(copy.ids[task.id]!)).result['comicSheetChildren'],
      {for (final e in children.entries) e.key: copy.ids[e.value]},
    );
    // The copy's character sheets point at the copy's own assets.
    final sheets = [
      for (final e in await repo.listLore(
        restored.activeBranchId,
        kind: LoreKind.character,
      ))
        ...(e.data['images'] as List? ?? []),
    ];
    expect(sheets, hasLength(2));
    expect(sheets.every(copy.ids.values.contains), isTrue);
  });
  test(
    'sheet resume keeps saved sheets and redraws the cancelled one',
    () async {
      cast = ['林夏', '周野', '老陈', '小满'];
      gatedImage = 2;
      imageGate = Completer<void>();
      imageStarted = Completer<void>();
      addTearDown(() {
        if (!imageGate!.isCompleted) imageGate!.complete();
      });
      final task = await service.compose(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        instruction: '雨夜收到未来短信',
        connection: connection,
        imageConnection: connection,
        characterSheets: true,
      );
      await imageStarted!.future.timeout(const Duration(seconds: 5));
      final first = ((await character('林夏')).data['images'] as List).single;
      await runner.cancel(task.id);
      imageGate!.complete();
      final cancelled = await runner.wait(task.id);
      expect(cancelled.status, TaskStatus.cancelled);
      expect(images, 2);
      final resumed = await runner.wait((await runner.resume(task.id)).id);
      expect(resumed.status, TaskStatus.completed, reason: resumed.error);
      // Only the cancelled sheet, the third sheet and the page are drawn.
      expect(images, 5);
      expect((await character('林夏')).data['images'], [first]);
      expect(
        (resumed.result['comicSheetChildren'] as Map)['林夏'],
        (cancelled.result['comicSheetChildren'] as Map)['林夏'],
      );
      expect(resumed.result['comicSheets'], {'done': 3, 'total': 3});
      for (final name in ['周野', '老陈']) {
        expect((await character(name)).data['images'], hasLength(1));
      }
    },
  );
  test('sheet with unknown state is never ordered again', () async {
    cast = ['林夏', '周野', '老陈'];
    gatedImage = 2;
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    addTearDown(() {
      if (!imageGate!.isCompleted) imageGate!.complete();
    });
    final task = await service.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到未来短信',
      connection: connection,
      imageConnection: connection,
      characterSheets: true,
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    // A sheet ordered by an earlier run that no runner is watching.
    final orphan = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.illustration,
      input: {},
    );
    final running = await repo.getTask(task.id);
    await repo.updateTask(
      task.id,
      status: TaskStatus.running,
      result: {
        'comicSheetChildren': {
          ...running.result['comicSheetChildren'] as Map,
          '老陈': orphan.id,
        },
      },
    );
    await runner.cancel(task.id);
    imageGate!.complete();
    await runner.wait(task.id);
    final resumed = await runner.wait((await runner.resume(task.id)).id);
    expect(resumed.status, TaskStatus.failed);
    expect(resumed.error, contains('角色定妆图状态未知'));
    // Only the cancelled sheet is redrawn; the unknown one is not reordered.
    expect(images, 3);
    expect(
      (await repo.listLore(
        novel.activeBranchId,
        kind: LoreKind.character,
      )).where((e) => e.name == '老陈' && e.data['images'] != null),
      isEmpty,
    );
  });
  test('drawCharacterSheet adds an image to a later character', () async {
    await twoPages();
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final id = await service.drawCharacterSheet(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      name: '阿杰',
      connection: connection,
    );
    expect(((await character('阿杰')).data['images'] as List).first, id);
    expect(images, 6);
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      head.id,
    );
    await expectLater(
      service.drawCharacterSheet(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        name: '无名',
        connection: connection,
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          '找不到角色资料：无名',
        ),
      ),
    );
  });

  test('opening draws one page without writing prose; three directions continue once', () async {
    final first = await compose();
    expect(first.status, TaskStatus.completed, reason: first.error);
    var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.complete, isTrue);
    expect(head.document.pages.length, 1);
    expect(images, 1);
    expect(
      (await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text.trim(),
      isEmpty,
    );
    final directions = await runner.wait(
      (await service.suggestDirections(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(directions.status, TaskStatus.completed, reason: directions.error);
    expect(directions.result['directions'], hasLength(3));
    expect(images, 1);
    final next = await compose(head: head.id);
    expect(next.status, TaskStatus.completed, reason: next.error);
    head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.pages, hasLength(2));
    expect(head.document.complete, isTrue);
    expect(images, 2);
    expect(
      requests.every(
        (r) => !(r.messages.first['content'] as String).contains('COMIC/facts'),
      ),
      isTrue,
    );
  });
  test('storyboard-only works without image configuration; incomplete pages block continuation', () async {
    final task = await compose(draw: false);
    expect(task.status, TaskStatus.completed, reason: task.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.checked, isTrue);
    expect(head.document.complete, isFalse);
    expect(images, 0);
    await expectLater(compose(head: head.id), throwsFormatException);
    final draw = await runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(draw.status, TaskStatus.completed, reason: draw.error);
    expect(images, 1);
  });
  test('missing image names the page', () async {
    final task = await compose(draw: false);
    expect(task.status, TaskStatus.completed, reason: task.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    await expectLater(
      compose(head: head.id),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('第 1 页还没有画好'),
        ),
      ),
    );
  });
  test('emptied episode keeps the previous episode page', () async {
    final first = await compose();
    expect(first.status, TaskStatus.completed, reason: first.error);
    final last = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document.pages.last;
    final next = await repo.createChapter(branchId: novel.activeBranchId);
    Future<GenerationTask> composeNext(String? head) async => runner.wait(
      (await service.compose(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        instruction: '下一话',
        connection: connection,
        expectedRevisionId: head,
      )).id,
    );
    final planned = await composeNext(null);
    expect(planned.status, TaskStatus.completed, reason: planned.error);
    final head = (await repo.getComic(novel.activeBranchId, next.id))!;
    // The author deletes the failed first page of episode 2.
    final emptied = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: next.id,
      document: head.document.withoutPage(head.document.lastPageId!),
      expectedRevisionId: head.id,
    );
    final again = await composeNext(emptied.id);
    expect(again.status, TaskStatus.completed, reason: again.error);
    expect(again.input['comicPreviousPanel'], last);
  });
  test('legacy stuck original can continue', () async {
    final first = await compose();
    expect(first.status, TaskStatus.completed, reason: first.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    // Data written by the old rules: page flagged and audit issues kept.
    final json = head.document.toJson();
    (json['pages'] as List).first['visualReview'] = true;
    json['audit']['reviews'][0]['issues'] = ['人物衣服颜色前后不一致'];
    final stuck = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: ComicDocument.fromJson(json),
      expectedRevisionId: head.id,
    );
    expect(stuck.document.checked, isFalse);
    final next = await compose(head: stuck.id);
    expect(next.status, TaskStatus.completed, reason: next.error);
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.document.pages,
      hasLength(2),
    );
    // The flagged page 1 is not redrawn; only the new page is.
    expect(images, 2);
  });
  test(
    'whole-document draw skips a flagged but current original page',
    () async {
      final first = await compose();
      expect(first.status, TaskStatus.completed, reason: first.error);
      final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      // Legacy flag on a page whose fingerprint is still current.
      final json = head.document.toJson();
      (json['pages'] as List).first['visualReview'] = true;
      final flagged = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: ComicDocument.fromJson(json),
        expectedRevisionId: head.id,
      );
      expect(flagged.document.pages.first['visualReview'], isTrue);
      expect(flagged.document.stalePageIds, isEmpty);
      // The assistant's draw_comic orders a draw without a page id.
      final draw = await runner.wait(
        (await service.generateImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          promptConnection: connection,
          expectedRevisionId: flagged.id,
        )).id,
      );
      expect(draw.status, TaskStatus.completed, reason: draw.error);
      expect(images, 1);
    },
  );
  // Chapter 1 is an adaptation; returns chapter 2, an original with a page.
  Future<Chapter> afterAdaptation({required bool finished}) async {
    final adapted = await repo.saveChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('阿宁藏起信。'),
    );
    var doc = comicFixture(adapted).asPages();
    if (finished) {
      final image = await library.importImage(
        branchId: novel.activeBranchId,
        name: '改编页',
        bytes: testPicture(),
      );
      doc = checkedComic(doc);
      doc = ComicDocument.fromJson({
        ...doc.toJson(),
        'pages': [
          for (final p in doc.pages)
            {...p, 'assetId': image.id, 'fingerprint': doc.pageFingerprint(p)},
        ],
      });
      expect(doc.checked && doc.complete, isTrue);
    }
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: doc,
      expectedRevisionId: null,
    );
    final next = await repo.createChapter(branchId: novel.activeBranchId);
    final opening = await runner.wait(
      (await service.compose(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        instruction: '原创下一话',
        connection: connection,
        imageConnection: connection,
      )).id,
    );
    expect(opening.status, TaskStatus.completed, reason: opening.error);
    expect(
      [for (final c in opening.input['comicContext'] as List) c['chapterId']],
      [if (finished) chapter.id],
    );
    return next;
  }

  List<Object?> contextIds(GenerationTask task) => [
    for (final c in task.input['comicContext'] as List) c['chapterId'],
  ];
  test('an unfinished adaptation does not block a later original', () async {
    final next = await afterAdaptation(finished: false);
    final head = (await repo.getComic(novel.activeBranchId, next.id))!;
    final directions = await runner.wait(
      (await service.suggestDirections(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        connection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(directions.status, TaskStatus.completed, reason: directions.error);
    expect(contextIds(directions), [next.id]);
    final page = await runner.wait(
      (await service.compose(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        instruction: '下一页',
        connection: connection,
        imageConnection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(page.status, TaskStatus.completed, reason: page.error);
    expect(contextIds(page), [next.id]);
    expect(
      (await repo.getComic(novel.activeBranchId, next.id))!.document.pages,
      hasLength(2),
    );
  });
  test('a finished adaptation stays in a later original\'s context', () async {
    final next = await afterAdaptation(finished: true);
    final head = (await repo.getComic(novel.activeBranchId, next.id))!;
    final directions = await runner.wait(
      (await service.suggestDirections(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        connection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(directions.status, TaskStatus.completed, reason: directions.error);
    expect(contextIds(directions), [chapter.id, next.id]);
  });
  test('sheets and page references are capped at 16, sheets first', () async {
    cast = ['林夏'];
    final first = await compose(sheets: true);
    expect(first.status, TaskStatus.completed, reason: first.error);
    final sheet = ((await character('林夏')).data['images'] as List).single;
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final page = head.document.lastPageId!;
    // Legacy panels carrying 16 author references, plus one sheet.
    final panels = head.document.panels;
    panels.first['referenceAssetIds'] = [
      for (var i = 0; i < 16; i++)
        (await library.importImage(
          branchId: novel.activeBranchId,
          name: '插图$i',
          bytes: testPicture(),
        )).id,
    ];
    final saved = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document.editPage(page, panels),
      expectedRevisionId: head.id,
    );
    final draw = await runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
        panelId: page,
        expectedRevisionId: saved.id,
      )).id,
    );
    expect(draw.status, TaskStatus.completed, reason: draw.error);
    final refs = await pageRefs(
      (await repo.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document.pages.single,
    );
    expect(refs, hasLength(16));
    expect(refs.first, sheet);
  });
  test('compose draws only the new page', () async {
    final first = await compose();
    expect(first.status, TaskStatus.completed, reason: first.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final page = head.document.pages.single['id'] as String;
    final panels = head.document.panels;
    panels.first['description'] = '女孩皱眉看手机';
    final edited = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document.editPage(page, panels),
      expectedRevisionId: head.id,
    );
    expect(edited.document.stalePageIds, [page]);
    final next = await compose(head: edited.id);
    expect(next.status, TaskStatus.completed, reason: next.error);
    expect(images, 2);
    final doc = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document;
    expect(doc.stalePageIds, [page]);
    expect(doc.pages.last['assetId'], isNotNull);
  });
  test('audit issues do not block drawing originals', () async {
    auditIssues = ['台词顺序不清'];
    final task = await compose();
    expect(task.status, TaskStatus.completed, reason: task.error);
    expect(images, 1);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.auditIssues, contains('台词顺序不清'));
    expect(head.document.complete, isTrue);
    expect(
      requests.where(
        (r) => (r.messages.first['content'] as String).startsWith(
          'COMIC/original-plan',
        ),
      ),
      hasLength(2),
    );
  });
  test('compose reports stages in order', () async {
    stages = [];
    final task = await compose();
    expect(task.status, TaskStatus.completed, reason: task.error);
    expect(stages, ['plan', 'check', 'page']);
  });
  test('check-first drawing of an original keeps going past issues', () async {
    auditIssues = ['台词顺序不清'];
    final plan = await compose(draw: false);
    expect(plan.status, TaskStatus.completed, reason: plan.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.checked, isFalse);
    final draw = await runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
        checkFirst: true,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(draw.status, TaskStatus.completed, reason: draw.error);
    expect(images, 1);
    final drawn = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(drawn.document.auditIssues, contains('台词顺序不清'));
    expect(drawn.document.complete, isTrue);
  });
  test('next episode draws on from an original with open issues', () async {
    final first = await compose();
    expect(first.status, TaskStatus.completed, reason: first.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final json = head.document.toJson();
    json['audit']['reviews'][0]['issues'] = ['人物衣服颜色前后不一致'];
    final open = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: ComicDocument.fromJson(json),
      expectedRevisionId: head.id,
    );
    final next = await repo.createChapter(branchId: novel.activeBranchId);
    final plan = await runner.wait(
      (await service.compose(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        instruction: '下一话',
        connection: connection,
      )).id,
    );
    expect(plan.status, TaskStatus.completed, reason: plan.error);
    final draw = await runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: next.id,
        connection: connection,
        promptConnection: connection,
      )).id,
    );
    expect(draw.status, TaskStatus.completed, reason: draw.error);
    expect(draw.input['comicPreviousPanel'], open.document.pages.last);
  });
  test('stale direction selection cannot append or call a model', () async {
    await compose();
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document,
      expectedRevisionId: head.id,
    );
    final count = requests.length;
    await expectLater(compose(head: head.id), throwsA(isA<ComicConflict>()));
    expect(requests.length, count);
  });
  test('concurrent opening requests create only one drawing task', () async {
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    addTearDown(() {
      if (!imageGate!.isCompleted) imageGate!.complete();
    });
    final attempts = await Future.wait(
      List.generate(2, (_) async {
        try {
          return await service.compose(
            branchId: novel.activeBranchId,
            chapterId: chapter.id,
            instruction: '雨夜收到短信',
            connection: connection,
            imageConnection: connection,
          );
        } catch (error) {
          return error;
        }
      }),
    );
    final tasks = attempts.whereType<GenerationTask>().toList();
    expect(tasks, hasLength(1));
    expect(
      attempts.where((v) => v is FormatException || v is ComicConflict),
      hasLength(1),
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    imageGate!.complete();
    final done = await runner.wait(tasks.single.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(images, 1);
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.document.pages,
      hasLength(1),
    );
  });
  test('cancelled original retains storyboard and reuses late image on explicit resume', () async {
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    addTearDown(() {
      if (!imageGate!.isCompleted) imageGate!.complete();
    });
    final task = await service.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到短信',
      connection: connection,
      imageConnection: connection,
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    final planned = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    await runner.cancel(task.id);
    imageGate!.complete();
    final cancelled = await runner.wait(task.id);
    expect(cancelled.status, TaskStatus.cancelled);
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      planned.id,
    );
    expect(planned.document.checked, isTrue);
    expect(planned.document.complete, isFalse);
    final callCount = requests.length;
    final resumed = await runner.wait((await runner.resume(task.id)).id);
    expect(resumed.status, TaskStatus.completed, reason: resumed.error);
    expect(
      (await repo.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document.complete,
      isTrue,
    );
    expect(images, 1);
    expect(requests.length, callCount);
  });
  test(
    'retry preserves generated panel IDs and completed planning call',
    () async {
      failAudit = true;
      final failed = await compose(draw: false);
      expect(failed.status, TaskStatus.failed);
      final audit = requests.last;
      failAudit = false;
      final done = await runner.wait((await runner.resume(failed.id)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(
        requests.where(
          (r) => (r.messages.first['content'] as String).startsWith(
            'COMIC/original-plan',
          ),
        ),
        hasLength(1),
      );
      expect(
        requests.last.messages.last['content'],
        audit.messages.last['content'],
      );
    },
  );
  test(
    'rechecking original after previous head changes restores continuation',
    () async {
      await compose();
      final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final next = await repo.createChapter(branchId: novel.activeBranchId);
      final task = await runner.wait(
        (await service.compose(
          branchId: novel.activeBranchId,
          chapterId: next.id,
          instruction: '下一话',
          connection: connection,
          imageConnection: connection,
        )).id,
      );
      expect(task.status, TaskStatus.completed, reason: task.error);
      var head = (await repo.getComic(novel.activeBranchId, next.id))!;
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: first.document,
        expectedRevisionId: first.id,
      );
      // Originals never go stale from earlier episodes changing.
      expect(
        await repo.comicSourcesCurrent(novel.activeBranchId, head.document),
        isTrue,
      );
      final check = await runner.wait(
        (await service.check(
          branchId: novel.activeBranchId,
          chapterId: next.id,
          connection: connection,
          expectedRevisionId: head.id,
        )).id,
      );
      expect(check.status, TaskStatus.completed, reason: check.error);
      head = (await repo.getComic(novel.activeBranchId, next.id))!;
      expect(
        await repo.comicSourcesCurrent(novel.activeBranchId, head.document),
        isTrue,
      );
      expect(head.document.checked, isTrue);
    },
  );
  test('late page image cannot overwrite an author edit', () async {
    final plan = await compose(draw: false);
    expect(plan.status, TaskStatus.completed);
    final before = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    final draw = await service.generateImages(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: connection,
      promptConnection: connection,
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    final edited = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: before.document,
      expectedRevisionId: before.id,
    );
    imageGate!.complete();
    final done = await runner.wait(draw.id);
    expect(done.result['comicCandidates'], contains(chapter.id));
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      edited.id,
    );
  });
}
