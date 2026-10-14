import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';

final tasksProvider = FutureProvider.family<List<GenerationTask>, String>((
  ref,
  branch,
) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listTasks(branchId: branch);
});
final proposalsProvider =
    FutureProvider.family<List<ManuscriptProposal>, String>((ref, branch) {
      ref.watch(repositoryContentChangesProvider);
      return ref.watch(repositoryProvider).listProposals(branch);
    });
final conversationsProvider =
    FutureProvider.family<List<Map<String, Object?>>, String>((ref, branch) {
      ref.watch(repositoryContentChangesProvider);
      return ref.watch(repositoryProvider).listConversations(branch);
    });
final messagesProvider = FutureProvider.family<List<AgentMessage>, String>((
  ref,
  id,
) {
  ref.watch(repositoryContentChangesProvider);
  return ref.watch(repositoryProvider).getAgentMessages(id);
});
final proposalProvider = FutureProvider.family<ManuscriptProposal, String>((
  ref,
  id,
) {
  ref.watch(repositoryContentChangesProvider);
  return ref.watch(repositoryProvider).getProposal(id);
});

/// Candidates waiting for the author's decision on [branchId].
final pendingReviewCountProvider = FutureProvider.family<int, String>((
  ref,
  branchId,
) async {
  ref.watch(repositoryContentChangesProvider);
  final pending = await ref
      .watch(repositoryProvider)
      .listProposals(branchId, status: ProposalStatus.pending);
  return pending.length;
});

const taskStatusLabels = {
  TaskStatus.queued: '等待开始',
  TaskStatus.running: '正在生成',
  TaskStatus.completed: '已完成',
  TaskStatus.failed: '失败',
  TaskStatus.cancelled: '已取消',
  TaskStatus.interrupted: '已中断',
};
const taskKindLabels = {
  TaskKind.writing: '正文生成',
  TaskKind.rewrite: '正文改写',
  TaskKind.agent: '编辑会话',
  TaskKind.branches: '故事走向',
  TaskKind.analysis: '资料整理',
  TaskKind.illustration: '插画生成',
};
