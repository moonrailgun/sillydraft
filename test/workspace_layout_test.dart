import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

const _rail = Key('workspace-sections');

Future<void> _tool(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byKey(_rail), matching: findAction(label)),
  );
  await tester.pumpAndSettle();
}

EditableText _editable(WidgetTester tester) => tester.widget<EditableText>(
  find.descendant(
    of: find.byKey(const Key('agent-input')),
    matching: find.byType(EditableText),
  ),
);

String _input(WidgetTester tester) => _editable(tester).controller.text;

/// Picks a quick action from the menu beside the input; it fills the input
/// and leaves the cursor there.
Future<void> _quick(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const Key('agent-quick-actions')));
  await tester.pumpAndSettle();
  final action = find.byKey(Key('agent-quick-$label'));
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  await tester.tap(action);
  await tester.pumpAndSettle();
  expect(_editable(tester).focusNode.hasFocus, isTrue);
}

/// Picks a chapter in the outline pane.
Future<void> _chapter(WidgetTester tester, String title) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const Key('workspace-outline')),
      matching: find.text(title),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _page(String text) => find.descendant(
  of: find.byKey(const Key('reader-page')),
  matching: find.textContaining(text, findRichText: true),
);

void main() {
  testWidgets(
    'window resizing preserves the reader bounds and reading position when space allows',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await services.close();
      });
      final repo = services.repository;
      await repo.setSetting('workspaceLayout', {
        'toolsWidth': 460.0,
        'outlineWidth': 320.0,
      });
      final novel = await repo.createNovel(title: '缩放时继续阅读');
      await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '长夜',
        content: ManuscriptContent.plainText(
          List.generate(100, (i) => '第 $i 段：雨落在渡口，远处的灯光渐渐亮起来。').join('\n\n'),
        ),
      );
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text(novel.title));
      await tester.pumpAndSettle();

      final reader = find.byKey(const Key('reader-page'));
      final outline = find.byKey(const Key('workspace-outline'));
      final tools = find.byKey(const Key('workspace-tools'));
      final viewport = find.descendant(
        of: reader,
        matching: find.byType(SingleChildScrollView),
      );
      await tester.drag(viewport, const Offset(0, -600));
      await tester.pumpAndSettle();
      final scroll = tester.widget<SingleChildScrollView>(viewport).controller!;
      final offset = scroll.offset;
      final page = tester.getRect(reader);
      expect(offset, greaterThan(0));
      expect(tester.getSize(outline).width, 320);
      expect(tester.getSize(tools).width, 460);

      Future<void> resize(double width, [double height = 900]) async {
        tester.view.physicalSize = Size(width, height);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      for (final width in [1600.0, 2200.0, 1250.0, 1400.0]) {
        await resize(width);
        expect(tester.getRect(reader), page);
        expect(scroll.offset, offset);
      }
      await resize(1600, 1000);
      expect(tester.getRect(reader).topLeft, page.topLeft);
      expect(tester.getSize(reader).width, page.width);
      expect(scroll.offset, offset);

      // Narrowing may squeeze the reader, but must not replace its preference.
      await resize(950);
      expect(tester.getSize(reader).width, lessThan(page.width));
      await resize(1400);
      expect(tester.getRect(reader), page);
      expect(scroll.offset, offset);

      // Drag from the divider's visible position after the window grew.
      await resize(1600);
      await tester.drag(
        find.byKey(const Key('workspace-tools-divider')),
        const Offset(-60, 0),
      );
      await tester.pumpAndSettle();
      final resized = tester.getRect(reader);
      expect(resized.left, page.left);
      expect(resized.width, closeTo(page.width - 60, 1));
      await resize(1800);
      expect(tester.getRect(reader), resized);

      await tester.drag(
        find.byKey(const Key('workspace-divider')),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();
      final shifted = tester.getRect(reader);
      expect(shifted.left, closeTo(resized.left + 40, 1));
      expect(shifted.width, closeTo(resized.width - 40, 1));
      await resize(1900);
      expect(tester.getRect(reader), shifted);

      // Folding still deliberately gives the page the released space.
      await tester.tap(find.byKey(const Key('workspace-tools-toggle')));
      await tester.pumpAndSettle();
      expect(tester.getSize(reader).width, greaterThan(shifted.width));
      await tester.tap(find.byKey(const Key('workspace-tools-toggle')));
      await tester.pumpAndSettle();
      expect(tester.getRect(reader), shifted);
    },
  );
  testWidgets(
    'wide screens keep the outline on the left, the page in the middle and folding tools on the right',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
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
      final novel = await repo.createNovel(title: '雾港来信');
      for (final (title, text) in [('码头', '雾从港口升起。'), ('灯塔', '灯塔熄灭了。')]) {
        await repo.createChapter(
          branchId: novel.activeBranchId,
          title: title,
          content: ManuscriptContent.plainText(text),
        );
      }
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('雾港来信'));
      await tester.pumpAndSettle();

      // Left to right: the outline, the page, the assistant, the icon rail.
      final tools = tester.getRect(find.byKey(const Key('workspace-tools')));
      final page = tester.getRect(find.byKey(const Key('reader-page')));
      final outline = tester.getRect(
        find.byKey(const Key('workspace-outline')),
      );
      expect(outline.right, lessThan(page.left));
      expect(page.right, lessThan(tools.left));
      final rail = tester.getRect(find.byKey(_rail));
      expect(tools.right, lessThanOrEqualTo(rail.left));
      expect(rail.right, 1400);
      expect(rail.width, 56);
      expect(find.byKey(const Key('agent-input')), findsOneWidget);
      expect(find.text('正文目录'), findsOneWidget);
      // The rail offers tools only; the manuscript is always on the page.
      expect(
        find.descendant(of: find.byKey(_rail), matching: find.text('正文')),
        findsNothing,
      );
      for (final label in ['助手', '资料', '插图']) {
        expect(
          find.descendant(of: find.byKey(_rail), matching: findAction(label)),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byKey(_rail), matching: find.text(label)),
          findsNothing,
        );
      }

      // Picking a chapter in the outline shows it on the page.
      await _chapter(tester, '码头');
      expect(_page('雾从港口升起。'), findsOneWidget);

      // Switching tools leaves the page as it is.
      await _tool(tester, '资料');
      expect(find.text('故事资料'), findsOneWidget);
      expect(_page('雾从港口升起。'), findsOneWidget);
      await _tool(tester, '插图');
      expect(find.text('插图与素材'), findsOneWidget);
      expect(_page('雾从港口升起。'), findsOneWidget);

      // The tool already open folds its pane; the page widens.
      await _tool(tester, '插图');
      expect(find.text('插图与素材'), findsNothing);
      expect(tester.getRect(find.byKey(_rail)), rail);
      expect(
        tester.getRect(find.byKey(const Key('reader-page'))).width,
        greaterThan(page.width + 200),
      );
      await _tool(tester, '助手');
      expect(find.byKey(const Key('agent-input')), findsOneWidget);

      // Quick actions act on the chapter in view. Revising one before the end
      // moves the assistant there, as it may only write the last chapter it
      // can see.
      await _quick(tester, '修改');
      expect(_input(tester), '修改「码头」：');
      expect(findAction('参考范围：截至「码头」'), findsOneWidget);
      await _quick(tester, '查找');
      expect(_input(tester), '在正文中查找：');
      await _chapter(tester, '灯塔');
      await _quick(tester, '续写');
      expect(_input(tester), startsWith('续写「灯塔」'));
      expect(findAction('参考范围：分支末尾'), findsOneWidget);
      await _quick(tester, '推演结局');
      expect(_input(tester), contains('截至「灯塔」'));
      expect(_input(tester), contains('三个不同的结局'));
      expect(_input(tester), contains('不要修改正文或资料'));
      await _chapter(tester, '码头');
      await _quick(tester, '推演结局');
      expect(_input(tester), contains('截至「码头」'));
      expect(findAction('参考范围：截至「码头」'), findsOneWidget);
      // Filling in never sends, so nothing was saved.
      expect(await repo.listConversations(novel.activeBranchId), isEmpty);

      // The tools fold on their own, leaving the outline as it is.
      await tester.tap(find.byKey(const Key('workspace-tools-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agent-input')), findsNothing);
      expect(find.text('正文目录'), findsOneWidget);
      expect((await repo.getSetting('workspacePanes'))?['tools'], isFalse);
      await tester.tap(findAction('显示助手'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('agent-input')), findsOneWidget);

      // The outline folds away and stays folded.
      await tester.tap(find.byKey(const Key('workspace-outline-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('正文目录'), findsNothing);
      expect((await repo.getSetting('workspacePanes'))?['outline'], isFalse);
      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('雾港来信'));
      await tester.pumpAndSettle();
      expect(find.text('正文目录'), findsNothing);
      expect(find.byKey(const Key('reader-page')), findsOneWidget);
      await tester.tap(find.byKey(const Key('workspace-outline-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('正文目录'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
