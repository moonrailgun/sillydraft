import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

void main() {
  for (final sameChapter in [false, true]) {
    testWidgets(
      'explicit chapter ${sameChapter ? "restores its own" : "ignores another chapter’s"} progress',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repo = StoryRepository.memory();
        final services = AppServices(
          repository: repo,
          secrets: MemorySecrets(),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          await services.close();
        });
        await repo.setSetting('reader', {
          'autoDirections': false,
          'keepAwake': false,
        });
        final novel = await repo.createNovel(title: '阅读位置');
        final a = await repo.createChapter(branchId: novel.activeBranchId);
        final b = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText(
            List.generate(100, (i) => '第 $i 段：雨落在渡口，远处的灯光渐渐亮起来。').join('\n\n'),
          ),
        );
        await repo.setReadingProgress(
          branchId: novel.activeBranchId,
          chapterId: sameChapter ? b.id : a.id,
          fraction: .8,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(
              ReaderScreen(branchId: novel.activeBranchId, chapterId: b.id),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.descendant(
                of: find.byKey(const Key('reader-page')),
                matching: find.byType(SingleChildScrollView),
              ),
            )
            .controller!;
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        expect(scroll.offset, sameChapter ? greaterThan(0) : isZero);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'reader bookmarks and restores the current position in a long chapter',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '阅读位置测试');
      await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '长夜',
        content: ManuscriptContent.plainText(
          List.generate(100, (i) => '第 $i 段：雨落在渡口，远处的灯光渐渐亮起来。').join('\n\n'),
        ),
      );
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读位置测试'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView).first,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      // Reading hides the bars; a tap in the middle of the page brings them back.
      expect(findAction('阅读设置').hitTestable(), findsNothing);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-page'))),
      );
      await tester.pumpAndSettle();
      await tester.tap(findAction('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(FItem), matching: find.text('书签')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加当前位置'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listBookmarks(novel.activeBranchId)).single.offset,
        greaterThan(0),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final progress = await repo.getReadingProgress(novel.activeBranchId);
      expect(progress?['fraction'], greaterThan(0));
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byType(SingleChildScrollView).first,
          )
          .controller!;
      expect(scroll.offset, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
