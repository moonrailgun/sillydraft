import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/branches/branch_screen.dart';
import 'package:sillydraft/features/branches/candidate_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

void main() {
  testWidgets('phone selects one candidate without changing its source', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = StoryRepository.memory();
    final services = AppServices(repository: repo, secrets: MemorySecrets());
    addTearDown(services.close);
    final novel = await repo.createNovel(title: '岔路');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('抵达港口'),
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.branches,
      input: {
        'sourceRevisions': [
          {'chapterId': chapter.id, 'revisionId': chapter.revisionId},
        ],
      },
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {
        'candidates': [
          {'title': '远航', 'summary': '搭船前往新大陆', 'opening': '她扬起船帆。'},
          {'title': '归乡', 'summary': '回到村庄', 'opening': '她调转马头。'},
        ],
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(CandidateScreen(taskId: task.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-candidate-0')));
    await tester.pumpAndSettle();
    expect((await repo.listBranches(novel.id)).length, 2);
    final active = await repo.getNovel(novel.id);
    expect(
      (await repo.getStory(active.activeBranchId)).text,
      contains('她扬起船帆。'),
    );
    expect((await repo.getStory(novel.activeBranchId)).text.trim(), '抵达港口');
    expect(
      (await repo.listLore(active.activeBranchId)).single.certainty,
      LoreCertainty.plan,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('branch manager compares and switches the manuscript', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final services = AppServices(repository: repo, secrets: MemorySecrets());
    addTearDown(services.close);
    final novel = await repo.createNovel(title: '比较分支');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('原来的故事'),
    );
    final branch = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: '另一条路',
    );
    await repo.saveChapter(
      branchId: branch.id,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('新的故事'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(BranchScreen(novelId: novel.id)),
      ),
    );
    await tester.pumpAndSettle();
    // The tree marks where the branch left the story.
    expect(find.textContaining('第一章后'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('branch-${branch.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('compare-${branch.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('原来的故事'), findsOneWidget);
    expect(find.textContaining('新的故事'), findsOneWidget);
    await tester.tap(findAction('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('activate-${branch.id}')));
    await tester.pumpAndSettle();
    expect((await repo.getNovel(novel.id)).activeBranchId, branch.id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new branch forks after the chosen chapter and switches to it', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final services = AppServices(repository: repo, secrets: MemorySecrets());
    addTearDown(services.close);
    final novel = await repo.createNovel(title: '新路线');
    await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('第一天'),
    );
    await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('第二天'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(BranchScreen(novelId: novel.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建分支'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText).first, '岔路');
    await tester.tap(find.text('当前故事末尾'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一章').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建分支'));
    await tester.pumpAndSettle();
    final active = await repo.getNovel(novel.id);
    expect(active.activeBranchId, isNot(novel.activeBranchId));
    expect((await repo.getStory(active.activeBranchId)).chapters, hasLength(1));
    expect(find.textContaining('岔路'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
