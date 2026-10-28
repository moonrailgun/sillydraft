import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/agent/task_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

Future<({StoryRepository repo, String taskId})> _showTask(
  WidgetTester tester,
  String qualityStatus, {
  TaskStatus status = TaskStatus.running,
}) async {
  final repo = StoryRepository.memory();
  final services = AppServices(repository: repo, secrets: MemorySecrets());
  addTearDown(services.close);
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  final novel = await repo.createNovel(title: '审读状态');
  final task = await repo.createTask(
    branchId: novel.activeBranchId,
    kind: TaskKind.writing,
    input: {},
  );
  await repo.updateTask(
    task.id,
    status: status,
    result: {
      'quality': {'status': qualityStatus},
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(TaskScreen(taskId: task.id)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return (repo: repo, taskId: task.id);
}

void main() {
  for (final (stage, activeMessage) in [
    ('reviewing', '正在自动审读正文…'),
    ('revising', '正在修订发现的问题…'),
    ('checking', '正在复查修订结果…'),
  ]) {
    for (final (status, message) in [
      (TaskStatus.cancelled, '自动审读已取消。'),
      (TaskStatus.interrupted, '自动审读已中断。'),
      (TaskStatus.failed, '自动审读未完成，任务已失败。'),
      (TaskStatus.completed, '自动审读已结束。'),
    ]) {
      testWidgets('$stage stops showing progress when task is $status', (
        tester,
      ) async {
        final task = await _showTask(tester, stage);
        expect(find.text(activeMessage), findsOneWidget);

        await task.repo.updateTask(task.taskId, status: status);
        await tester.pumpAndSettle();

        expect(find.text(activeMessage), findsNothing);
        expect(find.text(message), findsOneWidget);
      });
    }
  }

  for (final (stage, message) in [
    ('passed', '自动审读未发现需要修订的问题。'),
    ('revised', '已自动修订并通过复查。'),
    ('kept_original', '修订稿未通过复查，已保留原稿。'),
  ]) {
    testWidgets('completed task preserves its $stage review result', (
      tester,
    ) async {
      await _showTask(tester, stage, status: TaskStatus.completed);
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
    });
  }
}
