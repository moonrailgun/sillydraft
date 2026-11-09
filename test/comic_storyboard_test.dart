import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/comics/comic_storyboard.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  late AppServices services;
  late Novel novel;
  late Chapter chapter;
  var pictures = 0;
  setUp(() async {
    services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      // Ordered tasks fail at their first model call: nothing is paid for.
      modelProviderFactory: (_) async => throw StateError('测试不调用模型'),
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

  // saveComic only accepts images the novel owns.
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

  /// A drawn original episode; [layout] lists the panels of each page.
  Future<ComicRevision> original(
    List<List<String>> layout, {
    List<String> issues = const [],
  }) async {
    var doc = ComicDocument.original(chapterId: chapter.id, instruction: '雨夜')
        .edit({
          'panels': [
            for (final id in layout.expand((ids) => ids))
              {
                'id': id,
                'factIds': <String>[],
                'sceneId': 'train',
                'description': '画面 $id',
                'continuity': '',
                'texts': <dynamic>[],
                'referenceAssetIds': <String>[],
              },
          ],
          'pages': [
            for (final (i, ids) in layout.indexed)
              {
                'id': 'page${i + 1}',
                'panelIds': ids,
                'referenceAssetIds': <String>[],
              },
          ],
        });
    doc = doc.edit({
      'pages': [
        for (final page in doc.pages)
          {
            ...page,
            'assetId': await picture(),
            'fingerprint': doc.pageFingerprint(page),
          },
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
      chapterId: chapter.id,
      document: doc,
      expectedRevisionId: null,
    );
  }

  Future<List<Map<String, dynamic>>> pages() async =>
      (await services.repository.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document.pages;

  Future<int> revisions() async =>
      (await services.repository.listComicRevisions(
        novel.activeBranchId,
        chapter.id,
      )).length;

  FButton button(WidgetTester tester, String label) =>
      tester.widget<FButton>(find.widgetWithText(FButton, label));

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

  Future<List<GenerationTask>> comicTasks() async => [
    for (final t in await services.repository.listTasks(
      branchId: novel.activeBranchId,
    ))
      if (t.kind == TaskKind.comic) t,
  ];

  void expectReordered(WidgetTester tester) => expect(
    tester.getTopLeft(find.text('画面：画面 p2')).dy,
    lessThan(tester.getTopLeft(find.text('画面：画面 p1')).dy),
  );

  const redraw = '保存并重画本页（1 张图）';

  Widget storyboard([String? pageId, bool embedded = false]) => ComicStoryboard(
    branchId: novel.activeBranchId,
    chapterId: chapter.id,
    pageId: pageId,
    embedded: embedded,
  );

  testWidgets('editing is local until saved', (tester) async {
    await original([
      ['p1', 'p2'],
      ['p3'],
    ]);
    await launch(tester, storyboard('page1'));
    expect(find.text('第 1 页分镜'), findsOneWidget);
    expect(find.text('画面：画面 p3'), findsNothing);
    expect(button(tester, '只保存').onPress, isNull);
    final before = await revisions();
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    expect(await revisions(), before);
    expect(
      tester.getTopLeft(find.text('画面：画面 p2')).dy,
      lessThan(tester.getTopLeft(find.text('画面：画面 p1')).dy),
    );
    expect(button(tester, '只保存').onPress, isNotNull);
    await tester.tap(find.text('只保存'));
    await tester.pumpAndSettle();
    expect(await revisions(), before + 1);
    expect((await pages()).first['panelIds'], ['p2', 'p1']);
    expect(button(tester, '只保存').onPress, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('running task makes storyboard read-only', (tester) async {
    final head = await original([
      ['p1'],
    ]);
    final task = await services.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.comic,
      input: {
        'comicAction': 'images',
        'panelId': 'page1',
        'comicHeads': {chapter.id: head.id},
      },
    );
    await services.repository.updateTask(task.id, status: TaskStatus.running);
    // The right-hand pane; a full-screen header spins while tasks run.
    await launch(tester, storyboard(null, true));
    expect(find.text('正在画第 1 页，画完后可以编辑'), findsOneWidget);
    for (final label in ['只保存', '保存并重画本页（1 张图）', '编辑', '添加一格']) {
      expect(button(tester, label).onPress, isNull, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('add a panel to the selected page', (tester) async {
    await original([
      ['p1'],
      ['p2'],
    ]);
    await launch(tester, storyboard('page1'));
    await tester.ensureVisible(find.text('添加一格'));
    await tester.tap(find.text('添加一格'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('comic-description')),
      '女孩抬头看向车窗',
    );
    await tester.ensureVisible(find.text('保存分镜'));
    await tester.tap(find.text('保存分镜'));
    await tester.pumpAndSettle();
    expect(find.text('画面：女孩抬头看向车窗'), findsOneWidget);
    expect((await pages()).first['panelIds'], ['p1']);
    await tester.tap(find.text('只保存'));
    await tester.pumpAndSettle();
    final saved = await pages();
    expect(saved.first['panelIds'], hasLength(2));
    expect(saved.last['panelIds'], ['p2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('references fold shows automatic default', (tester) async {
    await original(
      [
        ['p1'],
        ['p2'],
      ],
      issues: ['第 2 页：伞的颜色与上一页不同'],
    );
    await launch(tester, storyboard());
    expect(find.text('第 2 页分镜'), findsOneWidget);
    expect(find.text('AI 提示 1'), findsOneWidget);
    await tester.ensureVisible(find.text('本页参考图'));
    await tester.tap(find.text('本页参考图'));
    await tester.pumpAndSettle();
    expect(find.text('自动：角色定妆图 + 上一页'), findsOneWidget);
    // Hints belong to the newest page only.
    await launch(tester, storyboard('page1'));
    expect(find.text('第 1 页分镜'), findsOneWidget);
    expect(find.text('AI 提示 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save and redraw saves once and orders one page image', (
    tester,
  ) async {
    await original([
      ['p1', 'p2'],
      ['p3'],
    ]);
    await launch(tester, storyboard('page1', true));
    final before = await revisions();
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    // No connection: nothing is saved or ordered, and the draft stays.
    await tester.tap(find.text(redraw));
    await tester.pumpAndSettle();
    expect(find.text('还没有分析模型'), findsOneWidget);
    expect(await revisions(), before);
    expect(await comicTasks(), isEmpty);
    expectReordered(tester);
    // Let the toast go so it cannot take the next tap.
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    await connect();
    await tester.tap(find.text(redraw));
    await tester.pumpAndSettle();
    final head = (await services.repository.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!;
    expect(await revisions(), before + 1);
    expect(head.document.pages.first['panelIds'], ['p2', 'p1']);
    final tasks = await comicTasks();
    expect(tasks, hasLength(1));
    expect(tasks.single.input['comicAction'], 'images');
    expect(tasks.single.input['panelId'], 'page1');
    expect((tasks.single.input['comicHeads'] as Map)[chapter.id], head.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a page changed elsewhere is neither overwritten nor redrawn', (
    tester,
  ) async {
    final head = await original([
      ['p1', 'p2'],
      ['p3'],
    ]);
    await connect();
    await launch(tester, storyboard('page1', true));
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    final panels = head.document.panels.take(2).toList();
    panels.first['description'] = '另一台设备改过的画面';
    final other = await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document.editPage('page1', panels),
      expectedRevisionId: head.id,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(redraw));
    await tester.pumpAndSettle();
    expect(find.text(const ComicConflict().toString()), findsOneWidget);
    expect(
      (await services.repository.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.id,
      other.id,
    );
    expect(await comicTasks(), isEmpty);
    expectReordered(tester);
    expect(button(tester, '只保存').onPress, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an embedded storyboard asks only for edits and stays put', (
    tester,
  ) async {
    await original([
      ['p1', 'p2'],
    ]);
    Future<void> open(Widget Function() route) async {
      await launch(
        tester,
        Builder(
          builder: (context) => Center(
            child: FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => route()),
              ),
              child: const Text('打开分镜'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开分镜'));
      await tester.pumpAndSettle();
    }

    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    // The host blocks back for its own reasons, as the phone workspace does.
    var blocked = 0;
    await open(
      () => PopScope(
        canPop: false,
        onPopInvokedWithResult: (popped, _) {
          if (!popped) blocked++;
        },
        child: storyboard(null, true),
      ),
    );
    await back();
    expect(blocked, 1);
    expect(find.text('放弃未保存的分镜修改？'), findsNothing);

    // Discarding inside a host never closes the host's page.
    await open(() => storyboard(null, true));
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    await back();
    await tester.tap(find.text('放弃修改').last);
    await tester.pumpAndSettle();
    expect(find.text('第 1 页分镜'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('画面：画面 p1')).dy,
      lessThan(tester.getTopLeft(find.text('画面：画面 p2')).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving full screen with unsaved edits asks first', (
    tester,
  ) async {
    await original([
      ['p1', 'p2'],
    ]);
    await launch(
      tester,
      Builder(
        builder: (context) => Center(
          child: FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => storyboard()),
            ),
            child: const Text('打开分镜'),
          ),
        ),
      ),
    );
    Future<void> back() async {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }

    // Nothing changed: back just leaves.
    await tester.tap(find.text('打开分镜'));
    await tester.pumpAndSettle();
    await back();
    expect(find.text('放弃未保存的分镜修改？'), findsNothing);
    expect(find.text('第 1 页分镜'), findsNothing);

    await tester.tap(find.text('打开分镜'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    await back();
    expect(find.text('放弃未保存的分镜修改？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('第 1 页分镜'), findsOneWidget);
    expectReordered(tester);
    await back();
    await tester.tap(find.text('放弃修改').last);
    await tester.pumpAndSettle();
    expect(find.text('第 1 页分镜'), findsNothing);
    expect(find.text('打开分镜'), findsOneWidget);
    expect((await pages()).first['panelIds'], ['p1', 'p2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full screen answers only for its own page\'s draft', (
    tester,
  ) async {
    await original([
      ['p1'],
      ['p2', 'p3'],
    ]);
    // The right-hand pane, as the workspace keeps it, with a draft on page 2.
    await launch(
      tester,
      Builder(
        builder: (context) => Column(
          children: [
            FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => storyboard('page1')),
              ),
              child: const Text('打开分镜'),
            ),
            Expanded(child: storyboard('page2', true)),
          ],
        ),
      ),
    );
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    // Page 1 full screen, unchanged: back just leaves.
    await tester.tap(find.text('打开分镜'));
    await tester.pumpAndSettle();
    expect(find.text('第 1 页分镜'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的分镜修改？'), findsNothing);
    expect(find.text('第 1 页分镜'), findsNothing);
    expect(find.text('第 2 页分镜'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('画面：画面 p3')).dy,
      lessThan(tester.getTopLeft(find.text('画面：画面 p2')).dy),
    );
    expect(button(tester, '只保存').onPress, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
