import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/bookshelf/novel_dialog.dart';
import 'package:sillydraft/features/branches/branch_screen.dart';
import 'package:sillydraft/features/editor/workspace_screen.dart';
import 'package:sillydraft/features/transfer/transfer_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('shelf actions manage the selected work at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await services.close();
      });
      final other = await repo.createNovel(title: '另一部作品');
      final novel = await repo.createNovel(title: '待整理的作品');
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();

      Future<void> openMenu(String title) async {
        final menu = find.descendant(
          of: find.widgetWithText(FCard, title),
          matching: findAction('作品操作'),
        );
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
      }

      await openMenu(novel.title);
      expect(find.text('作品信息'), findsOneWidget);
      expect(find.text('故事分支'), findsOneWidget);
      expect(find.text('导出、备份与同步'), findsOneWidget);
      expect(find.text('归档作品'), findsOneWidget);
      expect(find.text('删除作品'), findsNothing);
      expect(find.byType(NovelWorkspace), findsNothing);
      await tester.tap(find.text('作品信息'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NovelDialog>(find.byType(NovelDialog)).novel?.id,
        novel.id,
      );
      await tester.enterText(find.byKey(const Key('novel-title')), '改过书名的作品');
      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();
      expect(find.byType(NovelDialog), findsNothing);
      expect(find.text('改过书名的作品'), findsOneWidget);
      expect(find.text(novel.title), findsNothing);
      expect((await repo.getNovel(other.id)).title, other.title);

      await openMenu('改过书名的作品');
      await tester.tap(find.text('故事分支'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<BranchScreen>(find.byType(BranchScreen)).novelId,
        novel.id,
      );
      expect(find.text('主线'), findsWidgets);
      await tester.tap(findAction('返回'));
      await tester.pumpAndSettle();

      await openMenu('改过书名的作品');
      await tester.tap(find.text('导出、备份与同步'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TransferScreen>(find.byType(TransferScreen)).novelId,
        novel.id,
      );
      expect(find.text('导出与备份'), findsOneWidget);
      await tester.tap(findAction('返回'));
      await tester.pumpAndSettle();
      expect(find.text('改过书名的作品'), findsOneWidget);
      expect(find.byType(NovelWorkspace), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
