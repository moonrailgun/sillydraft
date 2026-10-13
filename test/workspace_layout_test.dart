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

String _input(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('agent-input')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

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
      await tester.tap(find.byKey(const Key('agent-quick-修改')));
      await tester.pumpAndSettle();
      expect(_input(tester), '修改「码头」：');
      expect(find.text('参考范围：截至「码头」'), findsOneWidget);
      await tester.tap(find.byKey(const Key('agent-quick-查找')));
      await tester.pumpAndSettle();
      expect(_input(tester), '在正文中查找：');
      await _chapter(tester, '灯塔');
      await tester.tap(find.byKey(const Key('agent-quick-续写')));
      await tester.pumpAndSettle();
      expect(_input(tester), startsWith('续写「灯塔」'));
      expect(find.text('参考范围：分支末尾'), findsOneWidget);
      // Filling in never sends, so nothing was saved.
      expect(await repo.listConversations(novel.activeBranchId), isEmpty);

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
