import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft/features/agent/task_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

void main() {
  for (final status in [TaskStatus.failed, TaskStatus.interrupted]) {
    testWidgets('chat retains $status and links to its retry action', (
      tester,
    ) async {
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      final novel = await repo.createNovel(title: '失败提示');
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '这个讲了什么',
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'tool',
        content: '工具已返回正文',
        metadata: {'tool_call_id': 'read-1'},
      );
      final task = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {'conversationId': conversation},
      );
      await repo.updateTask(task.id, status: TaskStatus.running);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在处理…'), findsOneWidget);
      await tester.tap(find.text('查看任务'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<TaskScreen>(find.byType(TaskScreen)).taskId,
        task.id,
      );
      Navigator.of(tester.element(find.byType(TaskScreen))).pop();
      await tester.pumpAndSettle();

      await repo.updateTask(
        task.id,
        status: status,
        error: '模型服务在生成中返回错误：Invalid tool response',
        partialText: status == TaskStatus.failed ? '' : '已收到的部分回复',
      );
      await tester.pumpAndSettle();
      expect(find.text('正在处理…'), findsNothing);
      expect(find.textContaining('Invalid tool response'), findsOneWidget);
      expect(
        find.text('已收到的部分回复'),
        status == TaskStatus.failed ? findsNothing : findsOneWidget,
      );
      expect(findAction('停止编辑回复'), findsNothing);
      expect(findAction('发送给编辑助手'), findsOneWidget);
      await tester.tap(find.text('查看工具与任务'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TaskScreen>(find.byType(TaskScreen)).taskId,
        task.id,
      );
      expect(find.text('重新生成（新任务）'), findsOneWidget);
      Navigator.of(tester.element(find.byType(TaskScreen))).pop();
      await tester.pumpAndSettle();

      final next = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {'conversationId': conversation},
      );
      await repo.updateTask(next.id, status: TaskStatus.completed);
      await tester.pumpAndSettle();
      expect(find.textContaining('Invalid tool response'), findsNothing);
      expect(find.text('已收到的部分回复'), findsNothing);

      final olderFailure = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {'conversationId': conversation},
      );
      await repo.updateTask(
        olderFailure.id,
        status: TaskStatus.failed,
        error: '旧会话失败',
      );
      await tester.pumpAndSettle();
      await tester.tap(findAction('新建编辑会话'));
      await tester.pumpAndSettle();
      expect(find.text('旧会话失败'), findsNothing);
      expect(find.text('查看工具与任务'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
