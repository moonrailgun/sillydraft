import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

void main() {
  testWidgets(
    'Chinese composition commits to the manuscript and survives leaving editor',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '中文输入测试');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '第一章',
      );
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中文输入测试'));
      await tester.pumpAndSettle();
      await editChapter(tester, '第一章');
      expect(tester.testTextInput.hasAnyClients, isTrue);
      // An IME inserts at the current cursor; it does not remove Quill's existing
      // final paragraph separator when composing in an empty document.
      final suffix = tester.testTextInput.editingState!['text'] as String;
      expect(suffix, '\n');
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: 'yu$suffix',
          selection: const TextSelection.collapsed(offset: 2),
          composing: const TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '雨落在渡口。$suffix',
          selection: const TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      await tester.tap(findAction('保存并返回'));
      await tester.pumpAndSettle();
      final saved = await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      );
      expect(saved.content.text.trim(), '雨落在渡口。');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('6 字'), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      expect(find.textContaining('雨落在渡口。', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('the toolbar bolds the selection and keeps it selected', (
    tester,
  ) async {
    final (repo, chapter) = await _openEditor(
      tester,
      content: ManuscriptContent.plainText('雨落在渡口。'),
    );
    final controller = _quill(tester);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 2),
      ChangeSource.local,
    );
    await tester.pump();
    expect(tester.widget<IconAction>(findAction('加粗')).selected, isFalse);

    await tester.tap(findAction('加粗'));
    await tester.pump();
    expect(
      controller.document.collectStyle(0, 2).attributes,
      contains(Attribute.bold.key),
    );
    expect(
      controller.document.collectStyle(2, 4).attributes,
      isNot(contains(Attribute.bold.key)),
    );
    // The selection stays, and the toolbar shows bold as on for it.
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    expect(tester.widget<IconAction>(findAction('加粗')).selected, isTrue);

    await tester.tap(findAction('保存并返回'));
    await tester.pumpAndSettle();
    final saved = await repo.getChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
    );
    expect(saved.content.delta.first, {
      'insert': '雨落',
      'attributes': {'bold': true},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('history compares with saved current text without restoring it', (
    tester,
  ) async {
    final (repo, chapter) = await _openEditor(
      tester,
      content: ManuscriptContent.plainText('旧段\n共同结尾'),
    );
    _quill(tester).document = Document.fromJson(
      ManuscriptContent.plainText('新段\n共同结尾').delta,
    );
    await tester.pump();
    await tester.tap(findAction('正文版本'));
    await tester.pumpAndSettle();
    final current = await repo.getChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
    );
    final revisions = await repo.listRevisions(
      branchId: chapter.branchId,
      chapterId: chapter.id,
    );
    await tester.tap(find.text('比较').first);
    await tester.pumpAndSettle();
    expect(find.text('删除 · 历史版本'), findsOneWidget);
    expect(find.text('新增 · 当前正文'), findsOneWidget);
    expect(find.text('旧段'), findsOneWidget);
    expect(find.text('新段'), findsOneWidget);
    expect(find.text('共同结尾'), findsNothing);
    expect(
      (await repo.getChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      )).revisionId,
      current.revisionId,
    );
    expect(
      await repo.listRevisions(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      ),
      hasLength(revisions.length),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the toolbar undoes and redoes typing', (tester) async {
    await _openEditor(tester);
    final controller = _quill(tester);
    expect(tester.widget<IconAction>(findAction('撤销')).onPress, isNull);
    expect(tester.widget<IconAction>(findAction('重做')).onPress, isNull);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '潮声\n',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    expect(controller.document.toPlainText(), '潮声\n');
    expect(tester.widget<IconAction>(findAction('撤销')).onPress, isNotNull);

    await tester.tap(findAction('撤销'));
    await tester.pump();
    expect(controller.document.toPlainText(), '\n');
    expect(tester.widget<IconAction>(findAction('重做')).onPress, isNotNull);

    await tester.tap(findAction('重做'));
    await tester.pump();
    expect(controller.document.toPlainText(), '潮声\n');

    await tester.tap(findAction('保存并返回'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('heading and find work on the manuscript from the toolbar', (
    tester,
  ) async {
    final (repo, chapter) = await _openEditor(
      tester,
      size: const Size(1280, 900),
      content: ManuscriptContent.plainText('雾起。\n雾散。'),
    );
    final controller = _quill(tester);

    // Heading: the menu button names the current level and applies the
    // chosen one to the line.
    expect(
      find.descendant(of: findAction('标题样式'), matching: find.text('正文')),
      findsOneWidget,
    );
    await tester.tap(findAction('标题样式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标题 2').last);
    await tester.pumpAndSettle();
    expect(
      controller.getSelectionStyle().attributes[Attribute.header.key],
      Attribute.h2,
    );
    expect(controller.document.toDelta().toJson()[1], {
      'insert': '\n',
      'attributes': {'header': 2},
    });
    // The menu closed and its button now names the level in use.
    expect(
      find.descendant(of: findAction('标题样式'), matching: find.text('标题 2')),
      findsOneWidget,
    );

    // Find selects each match in turn.
    await tester.tap(findAction('查找'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '雾');
    await tester.pump();
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 1),
    );
    expect(find.text('1/2'), findsOneWidget);
    await tester.tap(findAction('下一个'));
    await tester.pump();
    expect(
      controller.selection,
      const TextSelection(baseOffset: 4, extentOffset: 5),
    );
    expect(find.text('2/2'), findsOneWidget);
    await tester.tap(findAction('关闭查找'));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 4, extentOffset: 5),
    );

    await tester.tap(findAction('保存并返回'));
    await tester.pumpAndSettle();
    final saved = await repo.getChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
    );
    expect(saved.content.text.trim(), '雾起。\n雾散。');
    expect(tester.takeException(), isNull);
  });
}

QuillController _quill(WidgetTester tester) =>
    tester.widget<QuillEditor>(find.byType(QuillEditor)).controller;

/// Opens the editor on the only chapter of a new novel.
Future<(StoryRepository, Chapter)> _openEditor(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  ManuscriptContent? content,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = StoryRepository.memory();
  final novel = await repo.createNovel(title: '工具栏测试');
  final chapter = await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '第一章',
    content: content,
  );
  final services = AppServices(repository: repo, secrets: MemorySecrets());
  addTearDown(services.close);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(SillyDraftApp(services: services));
  await tester.pumpAndSettle();
  await tester.tap(find.text('工具栏测试'));
  await tester.pumpAndSettle();
  await editChapter(tester, '第一章');
  return (repo, chapter);
}
