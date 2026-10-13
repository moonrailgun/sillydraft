import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets(
    'phone flow creates a novel and opens a real manuscript workspace',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-novel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-blank')).last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('novel-title')), '雾港来信');
      await tester.tap(find.text('创建小说'));
      await tester.pumpAndSettle();
      expect((await services.repository.listNovels()).single.title, '雾港来信');
      expect(find.text('第一章'), findsWidgets);
      expect(find.text('第一幕'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop reader shows manuscript independently of agent conversation',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '独立作品');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '第一章',
      );
      await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '渡口',
        content: ManuscriptContent.plainText('雨落在空无一人的渡口。'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: '不属于正文的编辑日志',
      );
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('独立作品'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      expect(find.textContaining('雨落在空无一人的渡口。'), findsWidgets);
      expect(find.textContaining('不属于正文的编辑日志'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
