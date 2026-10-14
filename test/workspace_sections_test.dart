import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

const _sections = Key('workspace-sections');

Future<(AppServices, Novel)> _openNovel(
  WidgetTester tester, {
  required Size size,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
  );
  addTearDown(services.close);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  final repo = services.repository;
  final novel = await repo.createNovel(title: '雾港来信');
  await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '码头',
    content: ManuscriptContent.plainText('雾从港口升起。'),
  );
  await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '灯塔',
    content: ManuscriptContent.plainText('灯塔熄灭了。'),
  );
  await tester.pumpWidget(SillyDraftApp(services: services));
  await tester.pumpAndSettle();
  await tester.tap(find.text('雾港来信'));
  await tester.pumpAndSettle();
  return (services, novel);
}

Future<void> _section(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(_sections),
      matching: tester.widget(find.byKey(_sections)) is AppBottomBar
          ? find.text(label)
          : findAction(label),
    ),
  );
  await tester.pumpAndSettle();
}

int _selected(WidgetTester tester) {
  final nav = find.byKey(_sections);
  if (tester.widget(nav) is AppBottomBar) {
    return tester.widget<AppBottomBar>(nav).selectedIndex;
  }
  return tester
      .widgetList<IconAction>(
        find.descendant(of: nav, matching: find.byType(IconAction)),
      )
      .toList()
      .indexWhere((action) => action.selected);
}

void main() {
  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'desktop' : 'phone'} chapter selection previews before editing and returns to the updated preview',
      (tester) async {
        final (services, novel) = await _openNovel(
          tester,
          size: wide ? const Size(1280, 900) : const Size(390, 844),
        );
        await tester.tap(find.text('灯塔').first);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('reader-page')), findsOneWidget);
        expect(find.byKey(const Key('manuscript-editor')), findsNothing);
        expect(find.byKey(_sections), wide ? findsOneWidget : findsNothing);
        expect(
          find.textContaining('灯塔熄灭了。', findRichText: true),
          findsOneWidget,
        );

        // The pencil edits the chapter currently being read, even after a page turn.
        await tester.tap(findAction('上一章'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('雾从港口升起。', findRichText: true),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('reader-edit-chapter')));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<QuillEditor>(find.byType(QuillEditor))
            .controller;
        expect(controller.document.toPlainText().trim(), '雾从港口升起。');
        controller.replaceText(
          0,
          controller.document.length - 1,
          '雾从港口散去。',
          const TextSelection.collapsed(offset: 0),
        );
        await tester.pump();
        await tester.tap(findAction('保存并返回'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('reader-page')), findsOneWidget);
        expect(find.byKey(const Key('manuscript-editor')), findsNothing);
        expect(find.byKey(_sections), wide ? findsOneWidget : findsNothing);
        expect(
          find.textContaining('雾从港口散去。', findRichText: true),
          findsOneWidget,
        );
        final story = await services.repository.getStory(novel.activeBranchId);
        expect(story.chapters.first.content.text.trim(), '雾从港口散去。');
        expect(story.chapters.last.content.text.trim(), '灯塔熄灭了。');

        if (!wide) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byKey(_sections), findsOneWidget);
          expect(find.byKey(const Key('reader-page')), findsNothing);
          // A new selection wins over the reader's remembered position.
          await tester.tap(find.text('灯塔'));
          await tester.pumpAndSettle();
          expect(
            find.textContaining('灯塔熄灭了。', findRichText: true),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('the full-screen reading shortcut also offers chapter editing', (
    tester,
  ) async {
    await _openNovel(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('open-reader')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader-edit-chapter')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reader-edit-chapter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manuscript-editor')), findsOneWidget);
    await tester.tap(findAction('保存并返回'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reader-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'desktop' : 'phone'} novel workspace keeps manuscript, lore, assistant and images in one place',
      (tester) async {
        final (services, novel) = await _openNovel(
          tester,
          size: wide ? const Size(1280, 900) : const Size(390, 844),
        );
        expect(find.byKey(_sections), findsOneWidget);
        expect(find.byType(AppBottomBar), wide ? findsNothing : findsOneWidget);
        expect(_selected(tester), 0);
        // The old icon soup is gone: reading is the only action beside the menu.
        expect(findAction('故事资料'), findsNothing);
        expect(findAction('创作助手'), findsNothing);
        expect(findAction('阅读'), findsOneWidget);

        await _section(tester, '资料');
        expect(find.text('故事资料'), findsOneWidget);
        expect(find.text('时间线'), findsOneWidget);
        expect(_selected(tester), 1);

        await _section(tester, '助手');
        expect(find.byKey(const Key('agent-input')), findsOneWidget);
        // Opening the section must not leave an empty chat behind.
        expect(
          await services.repository.listConversations(novel.activeBranchId),
          isEmpty,
        );

        // The branch is a choice of story version, shown under the title.
        expect(
          find.descendant(
            of: find.byKey(const Key('workspace-branch')),
            matching: find.text('主线'),
          ),
          findsOneWidget,
        );

        await _section(tester, '插图');
        expect(find.text('插图与素材'), findsOneWidget);
        expect(findAction('导入图片'), findsOneWidget);

        // On a phone back steps out of a section first; only then leaves
        // the novel. Side by side there is no section to step out of.
        if (!wide) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(find.byKey(_sections), findsOneWidget);
          expect(_selected(tester), 0);
        }
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(_sections), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('every section fits a small phone at double text size', (
    tester,
  ) async {
    await _openNovel(tester, size: const Size(360, 800), textScale: 2);
    for (final label in ['资料', '助手', '插图', '正文']) {
      await _section(tester, label);
      expect(tester.takeException(), isNull, reason: label);
    }
  });

  testWidgets('the branch under the title opens branch management', (
    tester,
  ) async {
    await _openNovel(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const Key('workspace-branch')));
    await tester.pumpAndSettle();
    expect(find.text('故事分支'), findsOneWidget);
    expect(find.text('创建独立分支'), findsOneWidget);
    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(_sections), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the assistant section leaves no empty chat and guides to model settings',
    (tester) async {
      final (services, novel) = await _openNovel(
        tester,
        size: const Size(390, 844),
      );
      await _section(tester, '助手');
      expect(find.text('检查最近几个章节里人物的动机是否一致'), findsOneWidget);
      await tester.tap(find.text('梳理目前埋下的伏笔，哪些还没有回收'));
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('agent-input')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '梳理目前埋下的伏笔，哪些还没有回收',
      );
      expect(
        await services.repository.listConversations(novel.activeBranchId),
        isEmpty,
      );
      expect(find.text('还没有配置模型连接，助手暂时无法回复。'), findsOneWidget);
      await tester.tap(find.text('去配置'));
      await tester.pumpAndSettle();
      expect(find.text('添加连接'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending candidates wait in the assistant menu, not the shelf', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    final repo = services.repository;
    final novel = await repo.createNovel(title: '候选测试');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('原来的正文'),
    );
    await repo.createProposal(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('候选的新正文'),
    );
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    expect(find.textContaining('待审'), findsNothing);
    await tester.tap(find.text('候选测试'));
    await tester.pumpAndSettle();
    await _section(tester, '助手');
    await tester.tap(findAction('候选与任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('候选 · 1'));
    await tester.pumpAndSettle();
    expect(find.text('待审阅正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'desktop docks' : 'phone floats'} the assistant from the editor at this chapter',
      (tester) async {
        await _openNovel(
          tester,
          size: wide ? const Size(1400, 900) : const Size(390, 844),
        );
        await editChapter(tester, '灯塔');
        await tester.tap(find.byKey(const Key('editor-assistant')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('agent-input')), findsOneWidget);
        expect(find.text('截至「灯塔」'), findsOneWidget);
        // Docked or floating, the manuscript stays on screen with it.
        expect(find.byKey(const Key('manuscript-editor')), findsOneWidget);
        expect(
          find.byKey(const Key('assistant-sheet')),
          wide ? findsNothing : findsOneWidget,
        );
        if (wide) {
          await tester.tap(find.byKey(const Key('editor-assistant')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('agent-input')), findsNothing);
        } else {
          // A large window: most of the screen, with the page still above it.
          final sheet = tester.getRect(
            find.byKey(const Key('assistant-sheet')),
          );
          expect(sheet.height, greaterThan(844 * .8));
          expect(sheet.top, greaterThan(0));
          await tester.tap(findAction('收起助手'));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('assistant-sheet')), findsNothing);
          expect(find.byKey(const Key('manuscript-editor')), findsOneWidget);
        }
        await tester.tap(findAction('保存并返回'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('chapters number themselves and keep their own names', (
    tester,
  ) async {
    final (services, novel) = await _openNovel(
      tester,
      size: const Size(390, 844),
    );
    Future<List<String>> titles() async => [
      for (final c in (await services.repository.getStory(
        novel.activeBranchId,
      )).chapters)
        c.title,
    ];
    await tester.tap(find.text('新增章节'));
    await tester.pumpAndSettle();
    final titleInput = find.descendant(
      of: find.byType(AppDialog),
      matching: find.byType(EditableText),
    );
    // Only the name is asked for; the number comes from the order.
    expect(tester.widget<EditableText>(titleInput).controller.text, isEmpty);
    await tester.enterText(titleInput, '来信');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manuscript-editor')), findsOneWidget);
    await tester.tap(findAction('保存并返回'));
    await tester.pumpAndSettle();
    final added = await services.repository.getStory(novel.activeBranchId);
    // 码头 and 灯塔 were titled without numbers and stay as written.
    expect(await titles(), ['码头', '灯塔', '第一章 来信']);

    await tester.tap(findAction('章节操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('计入编号'));
    await tester.pumpAndSettle();
    expect(await titles(), ['第一章 码头', '灯塔', '第二章 来信']);
    expect(find.text('第二章 来信'), findsOneWidget);

    await tester.tap(findAction('章节操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名章节'));
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(titleInput).controller.text, '来信');
    await tester.enterText(titleInput, '旧友来信');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final renamed = await services.repository.getStory(novel.activeBranchId);
    expect(renamed.chapters.last.id, added.chapters.last.id);
    expect(await titles(), ['第一章 码头', '灯塔', '第二章 旧友来信']);

    await tester.tap(findAction('作品操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('作品信息'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate((w) => w is FSelect<ChapterNumerals>),
        matching: find.byType(EditableText),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('阿拉伯数字（第6章）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存修改'));
    await tester.pumpAndSettle();
    expect(await titles(), ['第1章 码头', '灯塔', '第2章 旧友来信']);
    expect(find.text('第2章 旧友来信'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a book that skipped a number numbers on from a chapter', (
    tester,
  ) async {
    final (services, novel) = await _openNovel(
      tester,
      size: const Size(390, 844),
    );
    final repo = services.repository, branch = novel.activeBranchId;
    final chapters = (await repo.getStory(branch)).chapters;
    await repo.setChapterNumbered(
      branchId: branch,
      chapterId: chapters.first.id,
      numbered: true,
    );
    // As migration keeps a title past a gap in the old numbering.
    await repo.renameChapter(
      branchId: branch,
      chapterId: chapters.last.id,
      name: '第三章 灯塔',
    );
    await tester.pumpAndSettle();
    expect(find.text('第三章 灯塔'), findsOneWidget);
    await tester.tap(findAction('章节操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('从此章起全部计入编号'));
    await tester.pumpAndSettle();
    expect(find.text('第二章 灯塔'), findsOneWidget);
    // Nothing is left to take in.
    await tester.tap(findAction('章节操作').last);
    await tester.pumpAndSettle();
    expect(find.text('从此章起全部计入编号'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a chapter is deleted from its menu after confirming', (
    tester,
  ) async {
    final (services, novel) = await _openNovel(
      tester,
      size: const Size(1280, 900),
    );
    await tester.tap(findAction('章节操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除章节'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本章会从当前分支删除'), findsOneWidget);
    await tester.tap(find.text('删除章节').last);
    await tester.pumpAndSettle();
    expect(
      (await services.repository.getStory(novel.activeBranchId)).chapters
          .map((c) => c.title),
      ['灯塔'],
    );
    await tester.tap(findAction('章节操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除章节'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除章节').last);
    await tester.pumpAndSettle();
    expect(
      (await services.repository.getStory(novel.activeBranchId)).chapters,
      isEmpty,
    );
    expect(find.text('先创建一个章节，开始你的故事。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
