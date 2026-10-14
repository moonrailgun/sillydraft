import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import 'agent_providers.dart';
import 'proposal_screen.dart';
import '../lore/analysis_review_screen.dart';
import '../branches/candidate_screen.dart';
import '../illustrations/illustration_detail.dart';
import '../illustrations/asset_image.dart';

/// A task as it runs, without its request snapshots ([_inputSnapshotProvider]).
final taskProvider = FutureProvider.family<GenerationTask, String>((ref, id) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getTask(id, snapshots: false);
});

/// A task's whole input, formatted once: it never changes after the task is
/// created, while the task itself is re-read on every streamed save.
final _inputSnapshotProvider = FutureProvider.autoDispose
    .family<String, String>(
      (ref, id) async =>
          const JsonEncoder.withIndent('  ')
              .convert((await ref.watch(repositoryProvider).getTask(id)).input),
    );

class TaskScreen extends ConsumerWidget {
  const TaskScreen({super.key, required this.taskId});
  final String taskId;

  /// One full-width action under the status, spaced from the next.
  static Widget _action(Widget button) =>
      Padding(padding: const EdgeInsets.only(bottom: 8), child: button);

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '生成任务',
    body: AsyncView(
      value: ref.watch(taskProvider(taskId)),
      builder: (task) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '${taskKindLabels[task.kind]} · ${taskStatusLabels[task.status]}',
            style: context.theme.typography.body.xl.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (task.isActive) const FProgress(),
          if (task.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                task.error,
                style: TextStyle(color: context.theme.colors.error),
              ),
            ),
          if (task.status == TaskStatus.interrupted)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                task.isRemote
                    ? '本地连接已中断，任务可能仍在服务端执行。获取远程结果会连接同一任务；重新生成会发起新的模型请求。'
                    : '之前的模型连接已中断。重新生成会创建新任务并再次发起模型请求。',
              ),
            ),
          if (task.isRemote &&
              [TaskStatus.failed, TaskStatus.interrupted].contains(task.status))
            _action(
              FButton(
                onPress: () async {
                  try {
                    await ref
                        .read(servicesProvider)
                        .runner
                        .reconnectRemote(task.id);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                prefix: const Icon(FLucideIcons.cloudDownload),
                child: const Text('获取远程结果'),
              ),
            ),
          const SizedBox(height: 12),
          if (task.kind == TaskKind.illustration && task.isActive)
            Text(
              task.result['stage'] == 'saving' ? '正在保存图片到本地…' : '正在等待生图服务返回图片…',
            ),
          if (task.result['assetId'] case final String assetId) ...[
            AssetImageView(assetId: assetId, height: 280),
            const SizedBox(height: 12),
            _action(
              FButton(
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => IllustrationDetail(
                      assetId: assetId,
                      branchId: task.branchId,
                    ),
                  ),
                ),
                child: const Text('查看插画与使用方式'),
              ),
            ),
          ],
          if (task.result['proposalId'] case final String id)
            _action(
              FButton(
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ProposalScreen(proposalId: id),
                  ),
                ),
                child: const Text('审阅正文候选'),
              ),
            ),
          if (task.kind == TaskKind.analysis &&
              task.status == TaskStatus.completed)
            _action(
              FButton(
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AnalysisReviewScreen(taskId: task.id),
                  ),
                ),
                child: const Text('审阅资料提取'),
              ),
            ),
          if (task.kind == TaskKind.branches &&
              task.status == TaskStatus.completed)
            _action(
              FButton(
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => CandidateScreen(taskId: task.id),
                  ),
                ),
                child: const Text('比较候选走向'),
              ),
            ),
          if (task.isActive ||
              (task.isRemote &&
                  [
                    TaskStatus.failed,
                    TaskStatus.interrupted,
                  ].contains(task.status)))
            _action(
              FButton(
                variant: FButtonVariant.outline,
                onPress: () async {
                  try {
                    await ref.read(servicesProvider).runner.cancel(task.id);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                prefix: const Icon(FLucideIcons.circleStop),
                child: const Text('取消生成'),
              ),
            ),
          if (!task.isActive && task.status != TaskStatus.completed)
            _action(
              FButton(
                variant: FButtonVariant.outline,
                onPress: () async {
                  try {
                    final next = await ref
                        .read(servicesProvider)
                        .runner
                        .resume(task.id);
                    if (context.mounted) {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => TaskScreen(taskId: next.id),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('重新生成（新任务）'),
              ),
            ),
          const SizedBox(height: 24),
          Text(
            task.kind == TaskKind.agent ? '编辑回复' : '模型输出',
            style: context.theme.typography.body.md.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            task.partialText.isEmpty ? '尚未收到内容' : task.partialText,
            style: const TextStyle(height: 1.7),
          ),
          const SizedBox(height: 12),
          FAccordion(
            children: [
              if (task.reasoning.isNotEmpty)
                FAccordionItem(
                  title: const Text('模型返回的推理摘要'),
                  child: SelectableText(task.reasoning),
                ),
              if (task.result.isNotEmpty)
                FAccordionItem(
                  title: const Text('结果记录'),
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(task.result),
                  ),
                ),
              FAccordionItem(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('本次输入快照'),
                    const SizedBox(height: 2),
                    Text(
                      '提示词、版本依据与参数',
                      style: context.theme.typography.body.sm.copyWith(
                        color: context.theme.colors.mutedForeground,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ],
                ),
                child: SelectableText(
                  ref
                      .watch(_inputSnapshotProvider(task.id))
                      .when(
                        data: (json) => json,
                        loading: () => '正在读取…',
                        error: (e, _) => '无法读取输入快照：$e',
                      ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
