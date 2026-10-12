import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/agent/proposal_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets(
    'proposal comparison commits only on acceptance and refuses stale output',
    (tester) async {
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      final novel = await repo.createNovel(title: '候选测试');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '一',
      );
      final scene = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        content: ManuscriptContent.plainText('原来的正文'),
      );
      final proposal = await repo.createProposal(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
        baseRevisionId: scene.revisionId,
        content: ManuscriptContent.plainText('候选的新正文'),
      );
      Widget app() => ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: ProposalScreen(proposalId: proposal.id),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        (await repo.getScene(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
        )).content.text.trim(),
        '原来的正文',
      );
      expect(find.text('采纳到正文'), findsOneWidget);
      await repo.saveScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
        expectedRevisionId: scene.revisionId,
        content: ManuscriptContent.plainText('作者刚刚修改的正文'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '采纳到正文'))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('正文已更新'), findsWidgets);
      await tester.tap(find.text('拒绝候选'));
      await tester.pumpAndSettle();
      expect(
        (await repo.getProposal(proposal.id)).status,
        ProposalStatus.rejected,
      );
      expect(
        (await repo.getScene(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
        )).content.text.trim(),
        '作者刚刚修改的正文',
      );
    },
  );
}
