import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart' show AppBottomBar, FButton, FItem;
import 'package:sillydraft/features/bookshelf/novel_dialog.dart';
import 'package:sillydraft/features/comics/comic_canvas.dart';
import 'package:sillydraft/features/comics/comic_dialogs.dart';
import 'package:sillydraft/features/comics/comic_screen.dart';
import 'package:sillydraft/features/comics/comic_editor.dart';
import 'package:sillydraft/features/comics/comic_reader.dart';
import 'package:sillydraft/features/comics/comic_storyboard.dart';
import 'package:sillydraft/features/editor/workspace_screen.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

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

void main() {
  late AppServices services;
  late Novel novel;
  late Chapter chapter;
  late ComicRevision head;
  setUp(() async {
    services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    novel = await services.repository.createNovel(
      title: '门外',
      workFormat: WorkFormat.comic,
    );
    chapter = await services.repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    head = await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: fixture(chapter),
      expectedRevisionId: null,
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(page),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('original chapters only point to the comic canvas', (
    tester,
  ) async {
    final empty = await services.repository.createChapter(
      branchId: novel.activeBranchId,
    );
    await launch(
      tester,
      ComicScreen(branchId: novel.activeBranchId, chapterId: empty.id),
    );
    expect(find.text('这一话是原创漫画，请在漫画画布中创作。'), findsOneWidget);
    expect(find.text('开始画'), findsNothing);
    expect(find.byKey(const Key('comic-instruction')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a novel work opens its original comic on a canvas', (
    tester,
  ) async {
    final book = await services.repository.createNovel(title: '雾港来信');
    final episode = await services.repository.createChapter(
      branchId: book.activeBranchId,
    );
    await services.repository.saveComic(
      branchId: book.activeBranchId,
      chapterId: episode.id,
      document: ComicDocument.original(
        chapterId: episode.id,
        instruction: '雨夜',
      ),
      expectedRevisionId: null,
    );
    await launch(
      tester,
      ComicScreen(branchId: book.activeBranchId, chapterId: episode.id),
    );
    expect(find.text('这一话是原创漫画，请在漫画画布中创作。'), findsOneWidget);
    await tester.tap(find.text('打开漫画画布'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicCanvas), findsOneWidget);
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adaptation panel shows one primary action per step', (
    tester,
  ) async {
    await launch(
      tester,
      ComicScreen(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    expect(find.text('编排分镜 → 检查改编 → 绘制'), findsOneWidget);
    expect(find.widgetWithText(FButton, '绘制（1 张图）'), findsOneWidget);
    expect(find.widgetWithText(FButton, '检查改编'), findsNothing);
    expect(find.widgetWithText(FButton, '生成分镜'), findsNothing);
    await services.repository.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document.edit({'style': '水彩'}),
      expectedRevisionId: head.id,
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FButton, '检查改编'), findsOneWidget);
    expect(find.widgetWithText(FButton, '绘制（1 张图）'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('export lists stale original pages', () {
    final panel = {...head.document.panels.first, 'factIds': <String>[]};
    final drawn =
        ComicDocument.original(chapterId: chapter.id, instruction: '短信')
            .edit({
              'panels': [panel],
              'pages': [
                {
                  'id': 'page1',
                  'panelIds': [panel['id']],
                  'referenceAssetIds': <String>[],
                },
              ],
            })
            .withImage('page1', assetId: 'image1', taskId: 'task1');
    expect(comicStaleNotes('第一话', drawn), isEmpty);
    final edited = drawn.editPanels([
      {...panel, 'description': '女孩回头'},
    ]);
    expect(comicStaleNotes('第一话', edited), ['第一话 第 1 页：分镜已改，图未更新']);
    expect(comicStaleNotes('第一话', head.document), isEmpty);
  });

  for (final existing in [false, true]) {
    testWidgets(
      'original dialogue ${existing ? 'edits' : 'adds'} without novel facts',
      (tester) async {
        ComicDocument? saved;
        final panel = <String, dynamic>{
          ...head.document.panels.first,
          'factIds': <String>[],
          'texts': <Map<String, dynamic>>[
            if (existing) {'kind': 'dialogue', 'speaker': '女孩', 'text': '谁？'},
          ],
        };
        final doc =
            ComicDocument.original(chapterId: chapter.id, instruction: '收到短信')
                .edit({
                  'panels': [panel],
                  'pages': [
                    {
                      'id': 'page1',
                      'panelIds': [panel['id']],
                      'referenceAssetIds': <String>[],
                    },
                  ],
                })
                .withImage('page1', assetId: 'image1', taskId: 'task1');
        await launch(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => editComicPanel(
                context,
                document: doc,
                panel: panel,
                save: (value) async {
                  saved = value;
                },
              ),
              child: const Text('打开分镜'),
            ),
          ),
        );
        await tester.tap(find.text('打开分镜'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(existing ? '编辑' : '添加文字'));
        await tester.tap(find.text(existing ? '编辑' : '添加文字'));
        await tester.pumpAndSettle();
        expect(find.text('分镜文字'), findsOneWidget);
        expect(find.text('事实来源'), findsNothing);
        await tester.enterText(find.byKey(const Key('comic-text')), '你是谁？');
        await tester.ensureVisible(find.text('确定'));
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(find.text('这格承载的事实'), findsNothing);
        expect(find.text('文字将在重画后显示在图片内'), findsOneWidget);
        await tester.ensureVisible(find.text('保存分镜'));
        await tester.tap(find.text('保存分镜'));
        await tester.pumpAndSettle();
        final text = (saved!.panels.single['texts'] as List).single as Map;
        expect(text['text'], '你是谁？');
        expect(text.containsKey('factId'), isFalse);
        expect(saved!.pages.single['assetId'], 'image1');
        // Originals stay complete; the edited page is only flagged stale.
        expect(saved!.stalePageIds, ['page1']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('work type persists from the creation dialog', (tester) async {
    await services.repository.setSetting('beta', {'enabled': true});
    await launch(tester, const NovelDialog());
    await tester.enterText(find.byKey(const Key('novel-title')), '新漫画');
    await tester.tap(find.text('小说').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('漫画').last);
    await tester.pumpAndSettle();
    expect(find.text('叙事视角'), findsNothing);
    expect(find.text('目标字数'), findsNothing);
    expect(find.text('画风与视觉设定'), findsOneWidget);
    await tester.ensureVisible(find.text('创建漫画'));
    await tester.tap(find.text('创建漫画'));
    await tester.pumpAndSettle();
    final created = (await services.repository.listNovels()).singleWhere(
      (n) => n.title == '新漫画',
    );
    expect(created.workFormat, WorkFormat.comic);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing an existing comic preserves its type with beta off', (
    tester,
  ) async {
    await launch(tester, NovelDialog(novel: novel));
    await tester.enterText(find.byKey(const Key('novel-title')), '新的漫画名');
    await tester.ensureVisible(find.text('保存修改'));
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    final saved = await services.repository.getNovel(novel.id);
    expect(saved.title, '新的漫画名');
    expect(saved.workFormat, WorkFormat.comic);
    expect(tester.takeException(), isNull);
  });

  /// A comic work whose only episode is empty.
  Future<Novel> emptyComic() async {
    final work = await services.repository.createNovel(
      title: '末班地铁',
      workFormat: WorkFormat.comic,
    );
    await services.repository.createChapter(branchId: work.activeBranchId);
    return work;
  }

  Finder inCanvas(String text) =>
      find.descendant(of: find.byType(ComicCanvas), matching: find.text(text));

  testWidgets('comic work shows canvas in the middle on wide screens', (
    tester,
  ) async {
    final work = await emptyComic();
    await launch(tester, NovelWorkspace(novelId: work.id), width: 1200);
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(find.byType(ReaderScreen), findsNothing);
    expect(findAction('分镜'), findsOneWidget);
    expect(find.text('画好第一页后在这里改分镜'), findsOneWidget);
    expect(find.text('0 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// A comic work whose only episode has two drawn pages, the first of two
  /// panels.
  Future<Novel> drawnComic() async {
    final work = await emptyComic();
    final branch = work.activeBranchId;
    final episode = (await services.repository.getStory(branch))
        .chapters
        .single;
    var doc = ComicDocument.original(chapterId: episode.id, instruction: '雨夜')
        .edit({
          'panels': [
            for (var i = 1; i <= 3; i++)
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
            for (final (i, ids) in [
              ['p1', 'p2'],
              ['p3'],
            ].indexed)
              {
                'id': 'page${i + 1}',
                'panelIds': ids,
                'referenceAssetIds': <String>[],
              },
          ],
        });
    doc = doc.edit({
      'pages': [
        for (final (i, page) in doc.pages.indexed)
          {
            ...page,
            'assetId': (await services.repository.storeAsset(
              branchId: branch,
              name: '页',
              prepared: PreparedAsset(
                hash: '$i'.padLeft(64, '0'),
                thumbnailHash: 'b' * 64,
                width: 1,
                height: 1,
                byteLength: 1,
              ),
            )).id,
            'fingerprint': doc.pageFingerprint(page),
          },
      ],
    });
    await services.repository.saveComic(
      branchId: branch,
      chapterId: episode.id,
      document: doc,
      expectedRevisionId: null,
    );
    return work;
  }

  testWidgets(
    'picking a page shows its storyboard; phones open it full screen',
    (tester) async {
      final work = await drawnComic();
      await launch(tester, NovelWorkspace(novelId: work.id), width: 1200);
      expect(find.text('2 页'), findsOneWidget);
      expect(find.text('第 2 页分镜'), findsOneWidget);
      await tester.tap(find.byKey(const Key('comic-page-page1')));
      await tester.pumpAndSettle();
      expect(find.text('第 1 页分镜'), findsOneWidget);

      await tester.tap(findAction('章节操作'));
      await tester.pumpAndSettle();
      expect(find.text('本话历史版本'), findsOneWidget);
      expect(find.text('导出漫画'), findsOneWidget);
      expect(find.text('创作漫画'), findsNothing);
      expect(find.text('改编为漫画'), findsNothing);
      await tester.tap(find.text('本话历史版本'));
      await tester.pumpAndSettle();
      expect(find.text('漫画历史'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('comic-page-page1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('改分镜'));
      await tester.pumpAndSettle();
      expect(find.byType(ComicStoryboard), findsOneWidget);
      expect(find.text('第 1 页分镜'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('finishing an episode opens the next with the text carried', (
    tester,
  ) async {
    final work = await drawnComic();
    await launch(tester, NovelWorkspace(novelId: work.id), width: 1200);
    await tester.enterText(find.byKey(const Key('comic-instruction')), '第二天早上');
    await tester.ensureVisible(find.text('本话完结，开始第 2 话'));
    await tester.tap(find.text('本话完结，开始第 2 话'));
    await tester.pumpAndSettle();
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('comic-instruction')),
        matching: find.text('第二天早上'),
      ),
      findsOneWidget,
    );
    expect(find.text('0 页'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storyboard drafts survive switching episode and branch', (
    tester,
  ) async {
    final work = await drawnComic();
    final repo = services.repository;
    final a = work.activeBranchId;
    final prose = await repo.createChapter(
      branchId: a,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    final b = await repo.forkBranch(branchId: a, name: '另一种结局');
    await launch(tester, NovelWorkspace(novelId: work.id), width: 1200);
    final first = (await repo.getStory(a)).chapters.first;
    Future<void> open(Chapter chapter) async {
      await tester.tap(find.widgetWithText(FItem, chapter.title));
      await tester.pumpAndSettle();
    }

    Future<void> page1() async {
      await tester.tap(find.byKey(const Key('comic-page-page1')));
      await tester.pumpAndSettle();
      expect(find.text('第 1 页分镜'), findsOneWidget);
    }

    bool reordered() =>
        tester.getTopLeft(find.text('画面：车厢里的第 2 个画面')).dy <
        tester.getTopLeft(find.text('画面：车厢里的第 1 个画面')).dy;
    bool savable() =>
        tester.widget<FButton>(find.widgetWithText(FButton, '只保存')).onPress !=
        null;

    await page1();
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    expect(reordered(), isTrue);

    // The adaptation panel covers the storyboard for a prose episode.
    await open(prose);
    expect(find.byType(ComicScreen), findsOneWidget);
    expect(find.text('第 1 页分镜'), findsNothing);
    await open(first);
    await page1();
    expect(reordered(), isTrue);
    expect(savable(), isTrue);

    // Another branch shows its own storyboard; the draft waits for this one.
    await repo.setActiveBranch(b.id);
    await tester.pumpAndSettle();
    await page1();
    expect(reordered(), isFalse);
    expect(savable(), isFalse);
    await repo.setActiveBranch(a);
    await tester.pumpAndSettle();
    await page1();
    expect(reordered(), isTrue);
    expect(savable(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('storyboard drafts and typed text survive crossing 900 px', (
    tester,
  ) async {
    final work = await drawnComic();
    await launch(tester, NovelWorkspace(novelId: work.id), width: 1200);
    Finder typed() => find.descendant(
      of: find.byKey(const Key('comic-instruction')),
      matching: find.text('第二天早上'),
    );
    bool reordered() =>
        tester.getTopLeft(find.text('画面：车厢里的第 2 个画面')).dy <
        tester.getTopLeft(find.text('画面：车厢里的第 1 个画面')).dy;

    await tester.tap(find.byKey(const Key('comic-page-page1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上移').last);
    await tester.pumpAndSettle();
    expect(reordered(), isTrue);
    await tester.enterText(find.byKey(const Key('comic-instruction')), '第二天早上');
    await tester.pumpAndSettle();

    // A phone-width window remounts the canvas and drops the storyboard.
    tester.view.physicalSize = const Size(390, 900);
    await tester.pumpAndSettle();
    expect(find.byType(ComicStoryboard), findsNothing);
    expect(typed(), findsOneWidget);
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    expect(find.text('第 1 页分镜'), findsOneWidget);
    expect(reordered(), isTrue);
    expect(
      tester.widget<FButton>(find.widgetWithText(FButton, '只保存')).onPress,
      isNotNull,
    );
    expect(typed(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic work adaptations keep the adaptation panel as the tool', (
    tester,
  ) async {
    await launch(tester, NovelWorkspace(novelId: novel.id), width: 1200);
    expect(inCanvas('第 1 格'), findsOneWidget);
    expect(find.byType(ComicScreen), findsOneWidget);
    expect(find.text('编排分镜 → 检查改编 → 绘制'), findsOneWidget);
    expect(find.text('检查通过'), findsOneWidget);
    expect(find.text('2 格'), findsOneWidget);
    await tester.tap(findAction('章节操作'));
    await tester.pumpAndSettle();
    expect(find.text('改编为漫画'), findsOneWidget);
    expect(find.text('创作漫画'), findsNothing);
    await tester.tap(find.text('改编为漫画'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicScreen), findsOneWidget);
    await tester.tap(findAction('作品操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出漫画'));
    await tester.pumpAndSettle();
    expect(find.text('导出漫画 HTML ZIP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow comic work opens canvas from the bottom bar', (
    tester,
  ) async {
    final work = await emptyComic();
    await launch(tester, NovelWorkspace(novelId: work.id));
    const bar = Key('workspace-sections');
    expect(
      [
        for (final d
            in tester.widget<AppBottomBar>(find.byKey(bar)).destinations)
          d.label,
      ],
      ['目录', '漫画', '资料', '助手', '插图'],
    );
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    // Back steps out to the outline and asks nothing: no storyboard edits.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的分镜修改？'), findsNothing);
    expect(find.text('漫画目录'), findsOneWidget);
    expect(find.text('第一页发生了什么？'), findsNothing);
    await tester.tap(
      find.descendant(of: find.byKey(bar), matching: find.text('漫画')),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('novel reader offers comic version', (tester) async {
    final book = await services.repository.createNovel(title: '雾港来信');
    final prose = await services.repository.createChapter(
      branchId: book.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她没有开门。'),
    );
    await services.repository.saveComic(
      branchId: book.activeBranchId,
      chapterId: prose.id,
      document: fixture(prose),
      expectedRevisionId: null,
    );
    await launch(tester, ReaderScreen(branchId: book.activeBranchId));
    expect(find.text('看漫画版'), findsOneWidget);
    await tester.tap(find.text('看漫画版'));
    await tester.pumpAndSettle();
    expect(find.byType(ComicReader), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source comparison and panel editing invalidate checks without changing prose',
    (tester) async {
      await launch(
        tester,
        ComicScreen(branchId: novel.activeBranchId, chapterId: chapter.id),
      );
      await tester.tap(findAction('改编操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('来源与事实'));
      await tester.pumpAndSettle();
      expect(find.text(chapter.content.text), findsWidgets);
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('panel-edit-pu0')));
      await tester.tap(find.byKey(const Key('panel-edit-pu0')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('comic-description')),
        '阿宁把信藏进袖中，门关闭。',
      );
      await tester.ensureVisible(find.text('保存分镜'));
      await tester.tap(find.text('保存分镜'));
      await tester.pumpAndSettle();
      expect(
        (await services.repository.getComic(
          novel.activeBranchId,
          chapter.id,
        ))!.document.checked,
        isFalse,
      );
      expect(
        (await services.repository.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).revisionId,
        chapter.revisionId,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'panel edits survive cancelled closing and concurrent save conflicts',
    (tester) async {
      await launch(
        tester,
        ComicScreen(branchId: novel.activeBranchId, chapterId: chapter.id),
      );
      await tester.ensureVisible(find.byKey(const Key('panel-edit-pu0')));
      await tester.tap(find.byKey(const Key('panel-edit-pu0')));
      await tester.pumpAndSettle();
      const edit = '阿宁将信塞进袖中。';
      await tester.enterText(find.byKey(const Key('comic-description')), edit);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的分镜修改？'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text(edit), findsOneWidget);

      final concurrent = await services.repository.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: head.document.edit({'style': '另一设备的修改'}),
        expectedRevisionId: head.id,
      );
      await tester.ensureVisible(find.text('保存分镜'));
      await tester.tap(find.text('保存分镜'));
      await tester.pumpAndSettle();
      expect(find.text(edit), findsOneWidget);
      expect(find.text('保存分镜'), findsOneWidget);
      expect(
        (await services.repository.getComic(
          novel.activeBranchId,
          chapter.id,
        ))!.id,
        concurrent.id,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reordering invalidates audit and candidate adoption keeps history',
    (tester) async {
      await launch(
        tester,
        ComicScreen(branchId: novel.activeBranchId, chapterId: chapter.id),
      );
      final last = head.document.panels.last['id'];
      await tester.ensureVisible(find.byKey(Key('panel-up-$last')));
      await tester.tap(find.byKey(Key('panel-up-$last')));
      await tester.pumpAndSettle();
      final reordered = (await services.repository.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!;
      expect(reordered.document.panels.first['id'], last);
      expect(reordered.document.checked, isFalse);
      final task = await services.repository.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.comic,
        input: {
          'comicHeads': {chapter.id: reordered.id},
        },
      );
      await services.repository.saveComicTaskDocument(
        task.id,
        head.document,
        candidateOnly: true,
      );
      await services.repository.updateTask(
        task.id,
        status: TaskStatus.completed,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('有未写入的分镜 · 比较'));
      await tester.tap(find.text('有未写入的分镜 · 比较'));
      await tester.pumpAndSettle();
      expect(find.text('当前分镜'), findsOneWidget);
      expect(find.text('候选分镜'), findsOneWidget);
      await tester.ensureVisible(find.text('采用并标记待检查'));
      await tester.tap(find.text('采用并标记待检查'));
      await tester.pumpAndSettle();
      expect(
        (await services.repository.getTask(task.id)).result['comicCandidates'],
        isEmpty,
      );
      final adopted = (await services.repository.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!;
      expect(adopted.parentRevisionId, reordered.id);
      expect(adopted.document.checked, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader keeps full long Chinese dialogue at narrow widths', (
    tester,
  ) async {
    final longText = '这是一句不能被截断的长台词。' * 80;
    final panels = head.document.panels;
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
      chapterId: chapter.id,
      document: head.document.editPanels(panels),
      expectedRevisionId: head.id,
    );
    await launch(
      tester,
      ComicReader(branchId: novel.activeBranchId, chapterId: chapter.id),
    );
    final text = tester.widget<Text>(find.text(longText));
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    expect(tester.takeException(), isNull);
  });
}
