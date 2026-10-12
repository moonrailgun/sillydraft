import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/branches/branch_screen.dart';
import 'package:sillydraft/features/branches/candidate_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

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
      title: '一',
    );
    final scene = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      content: ManuscriptContent.plainText('抵达港口'),
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.branches,
      input: {
        'sourceRevisions': [
          {'sceneId': scene.id, 'revisionId': scene.revisionId},
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
        child: MaterialApp(home: CandidateScreen(taskId: task.id)),
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
      title: '一',
    );
    final scene = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      content: ManuscriptContent.plainText('原来的故事'),
    );
    final branch = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: '另一条路',
    );
    await repo.saveScene(
      branchId: branch.id,
      sceneId: scene.id,
      expectedRevisionId: scene.revisionId,
      content: ManuscriptContent.plainText('新的故事'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(home: BranchScreen(novelId: novel.id)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('compare-${branch.id}')));
    await tester.pumpAndSettle();
    expect(find.textContaining('原来的故事'), findsOneWidget);
    expect(find.textContaining('新的故事'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('activate-${branch.id}')));
    await tester.pumpAndSettle();
    expect((await repo.getNovel(novel.id)).activeBranchId, branch.id);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
