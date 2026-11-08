import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/bookshelf/novel_dialog.dart';
import 'package:sillydraft/features/comics/comic_screen.dart';
import 'package:sillydraft/features/comics/comic_editor.dart';
import 'package:sillydraft/features/comics/comic_reader.dart';
import 'package:sillydraft/features/editor/workspace_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

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

  testWidgets('empty original starts with instruction and has no draft', (
    tester,
  ) async {
    final empty = await services.repository.createChapter(
      branchId: novel.activeBranchId,
    );
    await launch(
      tester,
      ComicScreen(branchId: novel.activeBranchId, chapterId: empty.id),
    );
    expect(find.text('编辑故事底稿'), findsNothing);
    expect(find.text('开始画'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('comic-instruction')),
      '雨夜收到短信',
    );
    await tester.tap(find.text('开始画'));
    await tester.pumpAndSettle();
    expect(find.textContaining('配置'), findsWidgets);
    expect(find.text('雨夜收到短信'), findsOneWidget);
    expect(tester.takeException(), isNull);
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
        expect(saved!.complete, isFalse);
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

  testWidgets('comic works open the storyboard with a story draft entry', (
    tester,
  ) async {
    await launch(tester, NovelWorkspace(novelId: novel.id));
    expect(find.byType(ComicScreen), findsOneWidget);
    expect(find.text('编辑故事底稿'), findsOneWidget);
    expect(find.text('检查通过'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source comparison and panel editing invalidate checks without changing prose',
    (tester) async {
      await launch(
        tester,
        ComicScreen(branchId: novel.activeBranchId, chapterId: chapter.id),
      );
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
      await tester.ensureVisible(find.text('查看候选分镜'));
      await tester.tap(find.text('查看候选分镜'));
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
