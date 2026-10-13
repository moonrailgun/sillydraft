import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

import 'package:sillydraft/app/widgets.dart';

void main() {
  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<({AppServices services, Novel novel, Chapter chapter})> fixture(
    WidgetTester tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await services.close();
    });
    final novel = await services.repository.createNovel(title: '桌面工作区');
    final chapter = await services.repository.createChapter(
      branchId: novel.activeBranchId,
      title: '港口',
      content: ManuscriptContent.plainText('潮声'),
    );
    return (services: services, novel: novel, chapter: chapter);
  }

  Future<void> shortcut(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  testWidgets(
    'desktop Ctrl S saves immediately before autosave and global search is keyboard accessible',
    (tester) async {
      desktop(tester);
      final f = await fixture(tester);
      await tester.pumpWidget(SillyDraftApp(services: f.services));
      await tester.pumpAndSettle();
      await tester.tap(find.text(f.novel.title));
      await tester.pumpAndSettle();
      await editChapter(tester, '港口');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '新写的正文\n',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pump();
      expect(
        (await f.services.repository.getChapter(
          branchId: f.chapter.branchId,
          chapterId: f.chapter.id,
        )).content.text.trim(),
        '潮声',
      );
      await shortcut(tester, LogicalKeyboardKey.keyS);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(
        (await f.services.repository.getChapter(
          branchId: f.chapter.branchId,
          chapterId: f.chapter.id,
        )).content.text.trim(),
        '新写的正文',
      );
      await shortcut(tester, LogicalKeyboardKey.keyF, shift: true);
      await tester.pumpAndSettle();
      expect(find.text('搜索作品与正文'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('global-search-field')),
        '新写的',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('新写的正文'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
  testWidgets(
    'cancellable desktop exit waits for drafts and cancels on persistence failure',
    (tester) async {
      desktop(tester);
      final f = await fixture(tester);
      await tester.pumpWidget(SillyDraftApp(services: f.services));
      await tester.pumpAndSettle();
      final owner = Object();
      var saved = 0;
      addTearDown(() => f.services.unregisterDraft(owner));
      f.services.registerDraft(owner, () async {
        saved++;
        throw const FormatException('测试存储失败');
      });
      expect(
        await tester.binding.handleRequestAppExit(),
        AppExitResponse.cancel,
      );
      expect(saved, 1);
      await tester.pump();
      expect(find.textContaining('测试存储失败'), findsWidgets);
      f.services.registerDraft(owner, () async {
        saved++;
      });
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      expect(saved, 2);
      f.services.unregisterDraft(owner);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
  for (final (pane, dividerKey, drag) in [
    ('outline', 'workspace-divider', 90.0),
    ('tools', 'workspace-tools-divider', -90.0),
  ]) {
    testWidgets(
      'desktop $pane resizes and the chosen width survives reopening',
      (tester) async {
        desktop(tester);
        final f = await fixture(tester);
        await tester.pumpWidget(SillyDraftApp(services: f.services));
        await tester.pumpAndSettle();
        await tester.tap(find.text(f.novel.title));
        await tester.pumpAndSettle();
        final divider = find.byKey(Key(dividerKey)),
            panel = find.byKey(Key('workspace-$pane'));
        expect(divider, findsOneWidget);
        final before = tester.getSize(panel).width;
        // Each pane widens when its divider moves towards the page.
        await tester.drag(divider, Offset(drag, 0));
        await tester.pumpAndSettle();
        expect(tester.getSize(panel).width, greaterThan(before + 60));
        final width = tester.getSize(panel).width;
        await tester.tap(find.byType(AppBackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text(f.novel.title));
        await tester.pumpAndSettle();
        expect(tester.getSize(panel).width, closeTo(width, 1));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant({TargetPlatform.windows}),
    );
  }
  testWidgets(
    'reader Ctrl F searches the open branch without opening global search',
    (tester) async {
      desktop(tester);
      final f = await fixture(tester);
      await tester.pumpWidget(SillyDraftApp(services: f.services));
      await tester.pumpAndSettle();
      await tester.tap(find.text(f.novel.title));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      await shortcut(tester, LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byType(AppDialog), findsOneWidget);
      await tester.enterText(
        find.descendant(
          of: find.byType(AppDialog),
          matching: find.byType(EditableText),
        ),
        '潮声',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(AppDialog),
          matching: find.widgetWithText(FButton, '保存'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('找到 1 个章节'), findsOneWidget);
      expect(find.byKey(const Key('global-search-field')), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );
  testWidgets(
    'paper reader controls remain legible when application uses dark mode',
    (tester) async {
      final f = await fixture(tester);
      await f.services.repository.setSetting('appearance', {'mode': 'dark'});
      await tester.pumpWidget(SillyDraftApp(services: f.services));
      await tester.pumpAndSettle();
      await tester.tap(find.text(f.novel.title));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      final link = find.text('分支与结局');
      final linkColor = FTheme.of(tester.element(link)).colors.primary;
      final background = tester
          .widget<ColoredBox>(find.byKey(const Key('reader-page')))
          .color;
      final a = linkColor.computeLuminance();
      final b = background.computeLuminance();
      final contrast = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
      expect(contrast, greaterThanOrEqualTo(4.5));
    },
  );
  testWidgets(
    'small phone supports double-sized system text through bookshelf and settings',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final f = await fixture(tester);
      await tester.pumpWidget(SillyDraftApp(services: f.services));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.descendant(
          of: find.byType(AppBottomBar),
          matching: find.text('设置'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(
        (await f.services.repository.getSetting('appearance'))?['mode'],
        'dark',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
