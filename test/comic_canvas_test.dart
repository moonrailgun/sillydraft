import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/comics/comic_canvas.dart';
import 'package:sillydraft/features/comics/comic_reader.dart';
import 'package:sillydraft/features/comics/comic_storyboard.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

/// A checked v1 adaptation, as in comic_flow_test.dart.
ComicDocument fixture(Chapter chapter) {
  var doc = ComicDocument.draft(chapter: chapter);
  doc = doc.edit({
    'facts': [
      for (final u in doc.units.where((u) => u['disposition'] == 'story'))
        {
          'id': 'f${u['id']}',
          'kind': 'action',
          'summary': u['text'],
          'unitIds': [u['id']],
          'evidence': u['text'],
          'dependsOn': <String>[],
        },
    ],
    'panels': [
      for (final u in doc.units.where((u) => u['disposition'] == 'story'))
        {
          'id': 'p${u['id']}',
          'factIds': ['f${u['id']}'],
          'sceneId': 'room',
          'description': u['text'],
          'continuity': '门保持关闭',
          'texts': <dynamic>[],
          'referenceAssetIds': <String>[],
        },
    ],
  });
  return ComicDocument.fromJson({
    ...doc.toJson(),
    'audit': {
      'fingerprint': doc.fingerprint,
      'reviews': [
        for (final scope in doc.reviewScopes.entries)
          {'id': scope.key, 'unitIds': scope.value, 'issues': <String>[]},
      ],
    },
  });
}

const directions = [
  {'title': '回电', 'summary': '她拨回那个号码', 'event': '女孩拨回号码，听见自己的声音'},
  {'title': '下车', 'summary': '她在陌生站台下车', 'event': '地铁停在一个不存在的站，女孩下车'},
  {'title': '删掉', 'summary': '她删掉短信', 'event': '女孩删掉短信，手机又亮了'},
];

void main() {
  late AppServices services;
  late Novel novel;
  late Chapter chapter;
  var pictures = 0;
  // Model calls fail, so nothing is paid for; a test sets [hold] to keep
  // them waiting while it looks at a task that is still running.
  Completer<void>? hold;
  setUp(() async {
    hold = null;
    services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      modelProviderFactory: (_) async {
        await hold?.future;
        throw StateError('测试不调用模型');
      },
      imageProviderFactory: (_) async => throw StateError('测试不调用模型'),
    );
    novel = await services.repository.createNovel(
      title: '末班地铁',
      workFormat: WorkFormat.comic,
    );
    chapter = await services.repository.createChapter(
      branchId: novel.activeBranchId,
    );
  });
  tearDown(() => services.close());

  Future<void> launch(
    WidgetTester tester,
    Widget page, {
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
    });
    // A second launch in one test must rebuild the app's home route.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(page),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<String> picture() async => (await services.repository.storeAsset(
    branchId: novel.activeBranchId,
    name: '页',
    prepared: PreparedAsset(
      hash: (++pictures).toRadixString(16).padLeft(64, '0'),
      thumbnailHash: 'b' * 64,
      width: 1,
      height: 1,
      byteLength: 1,
    ),
  )).id;

  /// An original episode, one panel per page; a null image is an undrawn page.
  /// Page ids are [page] plus the page number.
  Future<ComicRevision> original(
    String chapterId,
    List<String?> images, {
    List<String>? characters,
    bool staleFirst = false,
    List<String> issues = const [],
    String page = 'page',
  }) {
    var doc = ComicDocument.original(chapterId: chapterId, instruction: '雨夜')
        .edit({
          'panels': [
            for (var i = 1; i <= images.length; i++)
              {
                'id': 'p$i',
                'factIds': <String>[],
                'sceneId': 'train',
                'description': '车厢里的第 $i 个画面',
                'continuity': '',
                'texts': <dynamic>[],
                'referenceAssetIds': <String>[],
              },
          ],
          'pages': [
            for (var i = 1; i <= images.length; i++)
              {
                'id': '$page$i',
                'panelIds': ['p$i'],
                'referenceAssetIds': <String>[],
                'characters': ?characters,
              },
          ],
        });
    doc = doc.edit({
      'pages': [
        for (final (i, page) in doc.pages.indexed)
          if (images[i] case final String id)
            {
              ...page,
              'assetId': id,
              'fingerprint': staleFirst && i == 0
                  ? 'stale'
                  : doc.pageFingerprint(page),
            }
          else
            page,
      ],
    });
    if (issues.isNotEmpty) {
      doc = ComicDocument.fromJson({
        ...doc.toJson(),
        'audit': {
          'fingerprint': doc.fingerprint,
          'reviews': [
            {'id': 'original', 'unitIds': <String>[], 'issues': issues},
          ],
        },
      });
    }
    return services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapterId,
      document: doc,
      expectedRevisionId: null,
    );
  }

  Future<GenerationTask> task(
    ComicRevision? head,
    String chapterId,
    Map<String, dynamic> input, {
    required TaskStatus status,
    String? error,
    Map<String, dynamic>? result,
  }) async {
    final created = await services.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.comic,
      input: {
        ...input,
        'comicHeads': {chapterId: head?.id},
      },
    );
    return services.repository.updateTask(
      created.id,
      status: status,
      error: error,
      result: result,
    );
  }

  Future<void> suggest(ComicRevision head) => task(
    head,
    head.chapterId,
    {'comicAction': 'directions'},
    status: TaskStatus.completed,
    result: {'directions': directions},
  );

  Future<List<Map<String, dynamic>>> pages() async =>
      (await services.repository.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document.pages;

  Finder field(String text) => find.descendant(
    of: find.byKey(const Key('comic-instruction')),
    matching: find.text(text),
  );

  Future<void> connect() async {
    await services.saveConnection(
      ModelConnection(
        id: 'text',
        name: '分析',
        baseUrl: 'http://localhost:1/v1',
        model: 'text',
        kind: ModelKind.text,
      ),
    );
    await services.saveConnection(
      ModelConnection(
        id: 'image',
        name: '生图',
        baseUrl: 'http://localhost:1/v1',
        model: 'painter',
        kind: ModelKind.image,
      ),
    );
  }

  /// The connections the canvas freezes into a redraw, or with [compose]
  /// into a compose, as configured now (after [connect]).
  Future<Map<String, dynamic>> frozen({bool compose = false}) async {
    final analysis = (await services.connectionFor('analysis'))!.raw;
    final image = (await services.connectionFor('image'))!.raw;
    return {
      'connection': compose ? analysis : image,
      'promptConnection': analysis,
      if (compose) 'imageConnection': image,
    };
  }

  // A task running in the background settles over a few frames; timed ones
  // also let the buttons' press effects finish.
  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<List<GenerationTask>> tasks() =>
      services.repository.listTasks(branchId: novel.activeBranchId);

  // The field's text as the work's drafts mirror it: a running task hides
  // the field itself.
  String? typed(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(ComicCanvas)))
          .read(comicDraftsProvider(novel.id))
          .instructions['${novel.activeBranchId}/${chapter.id}'];

  /// A compose continue_comic ordered for page `page-<creationId>`, in an
  /// assistant turn that has ended since.
  Future<GenerationTask> assistantCompose(
    String creationId, {
    Map<String, dynamic>? result,
  }) async {
    final repo = services.repository, branch = novel.activeBranchId;
    final turn = await repo.createTask(
      branchId: branch,
      kind: TaskKind.agent,
      input: {
        'conversationId': await repo.createConversation(branchId: branch),
      },
    );
    final head = await repo.getComic(branch, chapter.id);
    final composed = await task(
      head,
      chapter.id,
      {
        'comicAction': 'compose',
        'comicCreationId': creationId,
        'comicInstruction': '助手续画的一页',
        'agentComicCall': {
          'taskId': turn.id,
          'key': 'continue_comic:$creationId',
          'signature': creationId,
          'chapters': [
            for (final c in (await repo.getStory(branch)).chapters)
              {'id': c.id, 'revisionId': c.revisionId, 'title': c.title},
          ],
          'heads': {chapter.id: head?.id},
        },
      },
      status: TaskStatus.failed,
      error: '生图超时，请稍后重试',
      result: result,
    );
    await repo.updateTask(turn.id, status: TaskStatus.completed);
    return composed;
  }

  testWidgets('empty chapter shows opening area', (tester) async {
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(find.text('开始画'), findsOneWidget);
    expect(find.byKey(const Key('comic-character-sheets')), findsOneWidget);
    expect(find.text('自动编排分镜、检查连贯，画成一整页。首次最多 4 张图。'), findsOneWidget);
    for (final old in ['检查连续性', '生成漫画', '编辑故事底稿']) {
      expect(find.text(old), findsNothing);
    }
    await tester.tap(find.text('先画主要角色的定妆图'));
    await tester.pumpAndSettle();
    expect(find.text('自动编排分镜、检查连贯，画成一整页。共 1 张图。'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('comic-instruction')),
      '雨夜收到短信',
    );
    await tester.tap(find.text('开始画'));
    await tester.pumpAndSettle();
    expect(find.text('还没有分析模型 · 去设置'), findsOneWidget);
    expect(field('雨夜收到短信'), findsOneWidget);
    expect(
      await services.repository.listTasks(branchId: novel.activeBranchId),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('drawn last page shows next area and direction fills field', (
    tester,
  ) async {
    await suggest(await original(chapter.id, [await picture()]));
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('接下来'), findsOneWidget);
    expect(find.text('画下一页'), findsOneWidget);
    expect(find.text('点方向只会填进输入框，可以先改再画。每页 1 张图。'), findsOneWidget);
    await tester.tap(find.text('回电'));
    await tester.pumpAndSettle();
    expect(field(directions.first['event']!), findsOneWidget);
    expect(
      await services.repository.listTasks(branchId: novel.activeBranchId),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed last page blocks with retry and delete', (tester) async {
    final head = await original(chapter.id, [await picture(), null]);
    await task(
      head,
      chapter.id,
      {'comicAction': 'compose', 'comicCreationId': 'c2'},
      status: TaskStatus.failed,
      error: '生图超时，请稍后重试',
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第 2 页没画成'), findsOneWidget);
    expect(find.text('生图超时，请稍后重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('删除此页'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(find.text('第 2 页处理好后可以继续画'), findsOneWidget);
    expect(find.text('画下一页'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retry resumes the failed task that owns the page', (
    tester,
  ) async {
    // A compose's page is `page-<creation id>`: this task drew page 2, and
    // its image request is recorded against the head it saved.
    await connect();
    final head = await original(chapter.id, [
      await picture(),
      null,
    ], page: 'page-c');
    final failed = await task(
      head,
      chapter.id,
      {
        'comicAction': 'compose',
        'comicCreationId': 'c2',
        ...await frozen(compose: true),
      },
      status: TaskStatus.interrupted,
      result: {
        'comicHeads': {chapter.id: head.id},
        'comicChildren': {'${chapter.id}/page-c2': 'image-task'},
      },
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第 2 页没画成'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    final tasks = await services.repository.listTasks(
      branchId: novel.activeBranchId,
    );
    expect(tasks.where((t) => t.retryOf == failed.id), hasLength(1));
    expect(tasks.where((t) => t.input['comicAction'] == 'images'), isEmpty);
  });

  testWidgets('retry resumes a redraw that recorded its image request', (
    tester,
  ) async {
    await connect();
    final head = await original(chapter.id, [await picture(), null]);
    // A redraw keeps its head in the input until it saves the image.
    final failed = await task(
      head,
      chapter.id,
      {'comicAction': 'images', 'panelId': 'page2', ...await frozen()},
      status: TaskStatus.interrupted,
      result: {
        'comicChildren': {'${chapter.id}/page2': 'image-task'},
      },
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第 2 页没画成'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await frames(tester);
    final all = await tasks();
    expect(all.where((t) => t.retryOf == failed.id), hasLength(1));
    // No second paid image beside the recorded one.
    expect(all.where((t) => t.id != failed.id && t.retryOf == null), isEmpty);
  });

  testWidgets('retry draws afresh once the previous episode changed', (
    tester,
  ) async {
    await connect();
    final before = await original(chapter.id, [await picture()]);
    final second = await services.repository.createChapter(
      branchId: novel.activeBranchId,
    );
    final head = await original(second.id, [await picture(), null]);
    // Drawn with the previous episode's last page as it was then.
    final failed = await task(
      head,
      second.id,
      {
        'comicAction': 'images',
        'panelId': 'page2',
        'comicPreviousChapterId': chapter.id,
        'comicPreviousRevisionId': before.id,
        ...await frozen(),
      },
      status: TaskStatus.interrupted,
      result: {
        'comicChildren': {'${second.id}/page2': 'image-task'},
      },
    );
    final panels = before.document.panels;
    panels.first['description'] = '改过的上一话画面';
    await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: before.document.editPage('page1', panels),
      expectedRevisionId: before.id,
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: second.id),
    );
    await tester.tap(find.text('重试'));
    await frames(tester);
    final all = await tasks();
    expect(all.where((t) => t.retryOf == failed.id), isEmpty);
    final fresh = all.where(
      (t) => t.input['comicAction'] == 'images' && t.id != failed.id,
    );
    expect(fresh, hasLength(1));
    expect(fresh.single.retryOf, isNull);
  });

  testWidgets('retry draws afresh once the image engine changed', (
    tester,
  ) async {
    await connect();
    final head = await original(chapter.id, [await picture(), null]);
    final failed = await task(
      head,
      chapter.id,
      {
        'comicAction': 'images',
        'panelId': 'page2',
        ...await frozen(),
        // The engine it failed with, replaced in settings since.
        'connection': ModelConnection(
          id: 'image',
          name: '生图',
          baseUrl: 'http://localhost:1/v1',
          model: 'retired',
          kind: ModelKind.image,
        ).raw,
      },
      status: TaskStatus.interrupted,
      result: {
        'comicChildren': {'${chapter.id}/page2': 'image-task'},
      },
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    await tester.tap(find.text('重试'));
    await frames(tester);
    final all = await tasks();
    expect(all.where((t) => t.retryOf == failed.id), isEmpty);
    final fresh = all.where(
      (t) => t.input['comicAction'] == 'images' && t.id != failed.id,
    );
    expect(fresh, hasLength(1));
    expect(fresh.single.retryOf, isNull);
    expect((fresh.single.input['connection'] as Map)['model'], 'painter');
  });

  testWidgets('retry after the comic changed draws the page afresh', (
    tester,
  ) async {
    await connect();
    final drawn = await original(chapter.id, [
      await picture(),
      null,
    ], page: 'page-c');
    final failed = await task(
      drawn,
      chapter.id,
      {'comicAction': 'compose', 'comicCreationId': 'c2'},
      status: TaskStatus.failed,
      error: '生图超时，请稍后重试',
      result: {
        'comicHeads': {chapter.id: drawn.id},
        'comicChildren': {'${chapter.id}/page-c2': 'image-task'},
      },
    );
    // 只保存 on page 1 moves the head past the one the task saved.
    final panels = drawn.document.panels.take(1).toList();
    panels.first['description'] = '改过的第一个画面';
    final head = await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: drawn.document.editPage('page-c1', panels),
      expectedRevisionId: drawn.id,
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    await tester.tap(find.text('重试'));
    await frames(tester);
    final all = await tasks();
    expect(all.where((t) => t.retryOf == failed.id), isEmpty);
    final fresh = all.singleWhere((t) => t.input['comicAction'] == 'images');
    expect(fresh.retryOf, isNull);
    expect(fresh.input['panelId'], 'page-c2');
    expect((fresh.input['comicHeads'] as Map)[chapter.id], head.id);
  });

  testWidgets('retry draws a page the assistant composed afresh', (
    tester,
  ) async {
    await connect();
    final head = await original(chapter.id, [
      await picture(),
      null,
    ], page: 'page-c');
    // Everything a resume would reuse is in place; the assistant's turn,
    // which a resumed call would report to, has ended.
    final failed = await assistantCompose(
      'c2',
      result: {
        'comicHeads': {chapter.id: head.id},
        'comicChildren': {'${chapter.id}/page-c2': 'image-task'},
        'comicDocuments': {chapter.id: head.document.toJson()},
      },
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    await tester.tap(find.text('重试'));
    await frames(tester);
    final all = await tasks();
    expect(all.where((t) => t.retryOf == failed.id), isEmpty);
    final fresh = all.singleWhere((t) => t.input['comicAction'] == 'images');
    expect(fresh.retryOf, isNull);
    expect(fresh.input['agentComicCall'], isNull);
    expect(fresh.input['panelId'], 'page-c2');
  });

  testWidgets('an assistant compose that saved no page leaves no notice', (
    tester,
  ) async {
    await original(chapter.id, [await picture()]);
    await assistantCompose('c2');
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('接下来'), findsOneWidget);
    expect(find.textContaining('上次没画成'), findsNothing);
    expect(field('助手续画的一页'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting the page a failed compose saved leaves no notice', (
    tester,
  ) async {
    final head = await original(chapter.id, [
      await picture(),
      null,
    ], page: 'page-c');
    await task(
      head,
      chapter.id,
      {
        'comicAction': 'compose',
        'comicCreationId': 'c2',
        'comicInstruction': '女孩拨回号码',
      },
      status: TaskStatus.failed,
      error: '生图超时，请稍后重试',
      result: {
        'comicHeads': {chapter.id: head.id},
        'comicDocuments': {chapter.id: head.document.toJson()},
      },
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第 2 页没画成'), findsOneWidget);
    await tester.tap(find.text('删除此页'));
    await tester.pumpAndSettle();
    expect(await pages(), hasLength(1));
    expect(find.text('接下来'), findsOneWidget);
    expect(find.textContaining('上次没画成'), findsNothing);
    expect(field('女孩拨回号码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic directions never toast; 换一批 still reports', (
    tester,
  ) async {
    await services.saveConnection(
      ModelConnection(
        id: 'text',
        name: '分析',
        baseUrl: 'http://localhost:1/v1',
        model: 'text',
        kind: ModelKind.text,
      ),
    );
    // An undrawn earlier page: suggesting directions refuses up front.
    await original(chapter.id, [null, await picture()]);
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('接下来'), findsOneWidget);
    expect(find.textContaining('还没有画好'), findsNothing);
    await tester.tap(find.text('换一批'));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有画好'), findsOneWidget);
  });

  testWidgets('a compose that saved no page says why and keeps its text', (
    tester,
  ) async {
    await connect();
    final drawn = await original(chapter.id, [await picture()]);
    final failed = await task(
      drawn,
      chapter.id,
      {
        'comicAction': 'compose',
        'comicCreationId': 'c2',
        'comicInstruction': '雨夜收到短信',
      },
      status: TaskStatus.failed,
      error: '分镜两次都没有通过检查',
    );
    // Page 1 was deleted since: the episode is back at its opening.
    final head = await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: drawn.document.withoutPage('page1'),
      expectedRevisionId: drawn.id,
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(find.text('上次没画成：分镜两次都没有通过检查'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    expect(field('雨夜收到短信'), findsOneWidget);
    // Its head moved on: the same text is composed afresh, and once ordered
    // it leaves the field, so 画下一页 cannot order it again.
    hold = Completer();
    await tester.tap(find.text('重试'));
    await frames(tester);
    // Look while it runs, then let it fail before any check can stop the
    // test with a task still waiting.
    final text = typed(tester), all = await tasks();
    hold!.complete();
    await frames(tester);
    expect(text, isNull);
    expect(all.where((t) => t.retryOf == failed.id), isEmpty);
    final fresh = all.firstWhere((t) => t.input['comicAction'] == 'compose');
    expect(fresh.id, isNot(failed.id));
    expect(fresh.isActive, isTrue);
    expect(fresh.retryOf, isNull);
    expect(fresh.input['comicInstruction'], '雨夜收到短信');
    expect((fresh.input['comicHeads'] as Map)[chapter.id], head.id);
    // A later compose that finishes clears the notice.
    await task(head, chapter.id, {
      'comicAction': 'compose',
      'comicCreationId': 'c3',
    }, status: TaskStatus.completed);
    await tester.pumpAndSettle();
    expect(find.textContaining('上次没画成'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the notice resumes a compose whose head still holds', (
    tester,
  ) async {
    await connect();
    // A real opening compose that failed at its first model call.
    final failed = await services.comics.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到短信',
      connection: (await services.connectionFor('analysis'))!,
      imageConnection: await services.connectionFor('image'),
    );
    await frames(tester);
    expect(
      (await services.repository.getTask(failed.id)).status,
      TaskStatus.failed,
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.textContaining('上次没画成'), findsOneWidget);
    expect(field('雨夜收到短信'), findsOneWidget);
    // Its plan and check calls are reused rather than paid again.
    hold = Completer();
    await tester.tap(find.text('重试'));
    await frames(tester);
    final text = typed(tester), all = await tasks();
    hold!.complete();
    await frames(tester);
    expect(text, isNull);
    final resumed = all.where((t) => t.retryOf == failed.id);
    expect(resumed, hasLength(1));
    expect(resumed.single.isActive, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the notice composes afresh once the connection changed', (
    tester,
  ) async {
    await connect();
    // It failed with an analysis model the author has since replaced.
    final failed = await services.comics.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到短信',
      connection: ModelConnection(
        id: 'text',
        name: '分析',
        baseUrl: 'http://localhost:1/v1',
        model: 'retired',
        kind: ModelKind.text,
      ),
      imageConnection: await services.connectionFor('image'),
    );
    await frames(tester);
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.textContaining('上次没画成'), findsOneWidget);
    hold = Completer();
    await tester.tap(find.text('重试'));
    await frames(tester);
    final text = typed(tester), all = await tasks();
    hold!.complete();
    await frames(tester);
    expect(text, isNull);
    expect(all.where((t) => t.retryOf == failed.id), isEmpty);
    final fresh = all.firstWhere((t) => t.input['comicAction'] == 'compose');
    expect(fresh.id, isNot(failed.id));
    expect(fresh.retryOf, isNull);
    expect((fresh.input['connection'] as Map)['model'], 'text');
    expect(tester.takeException(), isNull);
  });

  testWidgets('running task shows progress at the new page', (tester) async {
    final running = await task(
      null,
      chapter.id,
      {
        'comicAction': 'compose',
        'comicCreationId': 'c1',
        'comicCharacterSheets': true,
      },
      status: TaskStatus.running,
      result: {
        'comicStage': 'sheets',
        'comicSheets': {'done': 1, 'total': 3},
      },
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('编排分镜'), findsOneWidget);
    expect(find.text('检查连贯'), findsOneWidget);
    expect(find.text('画角色定妆图（1/3）'), findsOneWidget);
    expect(find.text('画第 1 页'), findsOneWidget);
    expect(find.text('离开也会继续'), findsOneWidget);
    expect(find.text('第一页发生了什么？'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      (await services.repository.getTask(running.id)).status,
      TaskStatus.cancelled,
    );
    expect(find.text('第一页发生了什么？'), findsOneWidget);

    // Drawing a page already in the episode shows progress in its place.
    final head = await original(chapter.id, [await picture(), null]);
    await task(head, chapter.id, {
      'comicAction': 'images',
      'panelId': 'page2',
    }, status: TaskStatus.running);
    await tester.pumpAndSettle();
    expect(find.text('画第 2 页'), findsOneWidget);
    expect(find.text('画第 3 页'), findsNothing);
    expect(find.text('第 2 页没画成'), findsNothing);
    expect(find.text('接下来'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('other comic work shows one neutral line, not page progress', (
    tester,
  ) async {
    final adapted = await services.repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    final head = await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: adapted.id,
      document: fixture(adapted),
      expectedRevisionId: null,
      requireCurrentSource: false,
    );
    final checking = await task(head, adapted.id, {
      'comicAction': 'check',
    }, status: TaskStatus.running);
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: adapted.id),
    );
    expect(find.textContaining('画第'), findsNothing);
    expect(find.text('离开也会继续'), findsNothing);
    expect(find.text('正在处理本话…'), findsOneWidget);
    expect(find.text('查看详情'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(
      (await services.repository.getTask(checking.id)).status,
      TaskStatus.cancelled,
    );
    expect(find.text('正在处理本话…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale page and AI hint chips', (tester) async {
    await original(
      chapter.id,
      [await picture(), await picture()],
      staleFirst: true,
      issues: ['第 2 页：伞的颜色与上一页不同'],
    );
    await launch(
      tester,
      ComicCanvas(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        onEditStoryboard: (_) {},
      ),
      width: 1200,
    );
    expect(find.text('分镜已改，图未更新 · 重画'), findsOneWidget);
    expect(find.text('AI 提示 1'), findsOneWidget);
    // Wide screens show the page toolbar on hover.
    expect(find.text('改分镜'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const Key('comic-page-page2'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('改分镜'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete page then undo restores it', (tester) async {
    await original(chapter.id, [await picture(), await picture()]);
    String? selected;
    await launch(
      tester,
      ComicCanvas(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        onSelectPage: (id) => selected = id,
      ),
    );
    expect(await pages(), hasLength(2));
    await tester.tap(find.byKey(const Key('comic-page-page2')));
    await tester.pumpAndSettle();
    expect(selected, 'page2');
    await tester.tap(find.text('删除此页'));
    await tester.pumpAndSettle();
    expect(await pages(), hasLength(1));
    expect(find.text('已删除第 2 页'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(await pages(), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('finishing a chapter carries text and directions', (
    tester,
  ) async {
    await suggest(await original(chapter.id, [await picture()]));
    (String, String?)? opened;
    await launch(
      tester,
      ComicCanvas(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        onOpenChapter: (id, text) => opened = (id, text),
      ),
    );
    await tester.enterText(find.byKey(const Key('comic-instruction')), '第二天早上');
    await tester.tap(find.text('本话完结，开始第 2 话'));
    await tester.pumpAndSettle();
    final chapters = (await services.repository.getStory(novel.activeBranchId))
        .chapters;
    expect(chapters, hasLength(2));
    expect(opened, (chapters.last.id, '第二天早上'));
    await launch(
      tester,
      ComicCanvas(
        branchId: novel.activeBranchId,
        chapterId: opened!.$1,
        initialInstruction: opened!.$2,
      ),
    );
    expect(field('第二天早上'), findsOneWidget);
    for (final d in directions) {
      expect(find.text(d['title']!), findsOneWidget);
    }
    expect(find.byKey(const Key('comic-character-sheets')), findsNothing);
    expect(find.text('自动编排分镜、检查连贯，画成一整页。共 1 张图。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new character chip', (tester) async {
    final entry = await services.repository.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林夏',
      content: '短发，红色雨衣',
      atChapterId: chapter.id,
    );
    await original(chapter.id, [await picture()], characters: ['林夏', '路人']);
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('新角色：林夏 · 画定妆图'), findsOneWidget);
    expect(find.textContaining('路人'), findsNothing);
    await services.repository.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      id: entry.id,
      expectedRevisionId: entry.revisionId,
      name: '林夏',
      content: '短发，红色雨衣',
      atChapterId: chapter.id,
      data: {
        'images': [await picture()],
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('新角色：林夏 · 画定妆图'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a sheet already drawing keeps the chip busy after a rebuild', (
    tester,
  ) async {
    await services.repository.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林夏',
      content: '短发，红色雨衣',
      atChapterId: chapter.id,
    );
    await original(chapter.id, [await picture()], characters: ['林夏']);
    // What drawCharacterSheet leaves in the repository while it runs.
    await services.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.illustration,
      chapterId: chapter.id,
      input: {'name': '林夏 · 参考图', 'purpose': AssetPurpose.reference.name},
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('新角色：林夏 · 画定妆图'), findsNothing);
    final busy = find.widgetWithText(FButton, '正在画林夏的定妆图…');
    expect(busy, findsOneWidget);
    expect(tester.widget<FButton>(busy).onPress, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('canvas renders mixed chapter kinds', (tester) async {
    final repo = services.repository;
    final prose = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    final adapted = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    final doc = fixture(adapted);
    final asset = await picture();
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: adapted.id,
      document: ComicDocument.fromJson({
        ...doc.toJson(),
        'panels': [
          {...doc.panels.first, 'assetId': asset},
          ...doc.panels.skip(1),
        ],
      }),
      expectedRevisionId: null,
      requireCurrentSource: false,
    );
    final drawn = await repo.createChapter(branchId: novel.activeBranchId);
    await original(drawn.id, [await picture()]);
    for (final (id, text) in [
      (chapter.id, '第一页发生了什么？'),
      (prose.id, '本话有小说正文，还没有漫画'),
      (adapted.id, '第 1 格'),
      (drawn.id, '第 1 页'),
    ]) {
      await launch(
        tester,
        ComicCanvas(branchId: novel.activeBranchId, chapterId: id),
      );
      expect(find.text(text), findsOneWidget, reason: text);
      expect(tester.takeException(), isNull);
    }
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: prose.id),
    );
    expect(find.text('阅读正文'), findsOneWidget);
    expect(find.text('改编为漫画'), findsOneWidget);
    expect(find.text('下一话'), findsOneWidget);
  });

  testWidgets('narrow canvas keeps 16 px padding and long dialogue wraps', (
    tester,
  ) async {
    final adapted = await services.repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    final longText = '这是一句不能被截断的长台词。' * 40;
    final doc = fixture(adapted);
    final panels = doc.panels;
    panels.first['texts'] = [
      {
        'kind': 'narration',
        'speaker': '',
        'text': longText,
        'factId': panels.first['factIds'][0],
      },
    ];
    await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: adapted.id,
      document: doc.edit({'panels': panels}),
      expectedRevisionId: null,
      requireCurrentSource: false,
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: adapted.id),
    );
    expect(tester.getTopLeft(find.text(adapted.title)).dx, 16);
    final text = find.text(longText);
    expect(tester.getRect(text).left, greaterThanOrEqualTo(16));
    expect(tester.getRect(text).right, lessThanOrEqualTo(390 - 16));
    expect(tester.widget<Text>(text).maxLines, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('reader shows no check notices for originals', (tester) async {
    final head = await original(chapter.id, [await picture()]);
    final pages = head.document.pages..first['visualReview'] = true;
    await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document.edit({'pages': pages}),
      expectedRevisionId: head.id,
    );
    await launch(
      tester,
      ComicReader(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第 1 页'), findsOneWidget);
    for (final text in [
      '分镜尚未通过检查，以下是创作预览。',
      '依据已过期：这里保留的是先前版本的漫画。',
      '画面衔接待复核。',
    ]) {
      expect(find.text(text), findsNothing, reason: text);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('emptied original offers the opening again', (tester) async {
    final head = await original(chapter.id, [await picture()]);
    await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document.withoutPage('page1'),
      expectedRevisionId: head.id,
    );
    await launch(
      tester,
      ComicCanvas(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(find.text('开始画'), findsOneWidget);
    // Directions still running from before the delete: the store would
    // refuse a drawing, so the button waits.
    await task(head, chapter.id, {
      'comicAction': 'directions',
    }, status: TaskStatus.running);
    await tester.pumpAndSettle();
    expect(
      tester.widget<FButton>(find.widgetWithText(FButton, '开始画')).onPress,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
