import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets(
    'reader bookmarks and restores the current position in a long scene',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '阅读位置测试');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '第一章',
      );
      await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
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
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加当前位置'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listBookmarks(novel.activeBranchId)).single.offset,
        greaterThan(0),
      );
      await tester.tap(find.byTooltip('返回'));
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
