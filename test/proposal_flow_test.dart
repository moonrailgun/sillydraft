import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/theme.dart';
import 'package:sillydraft/app/widgets.dart';
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
        content: ManuscriptContent.plainText('原来的正文'),
      );
      final proposal = await repo.createProposal(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        baseRevisionId: chapter.revisionId,
        content: ManuscriptContent.plainText('候选的新正文'),
      );
      Widget app() => ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          builder: (context, child) => FTheme(
            data: appTheme(Brightness.light),
            child: FToaster(child: FTooltipGroup(child: child!)),
          ),
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: [
            ...GlobalMaterialLocalizations.delegates,
            ...FLocalizations.localizationsDelegates,
          ],
          home: ProposalScreen(proposalId: proposal.id),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text.trim(),
        '原来的正文',
      );
      expect(find.text('采纳到正文'), findsOneWidget);
      await repo.saveChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: chapter.revisionId,
        content: ManuscriptContent.plainText('作者刚刚修改的正文'),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<FButton>(find.widgetWithText(FButton, '采纳到正文')).onPress,
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
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text.trim(),
        '作者刚刚修改的正文',
      );
    },
  );
}
