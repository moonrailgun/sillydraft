import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../branches/candidate_screen.dart';
import '../illustrations/asset_image.dart';
import '../illustrations/illustration_detail.dart';
import '../lore/analysis_review_screen.dart';
import '../reader/reader_screen.dart';
import 'agent_providers.dart';
import 'agent_screen.dart';
import 'proposal_screen.dart';

/// A task as it runs, without its request snapshots ([_inputSnapshotProvider]).
final taskProvider = FutureProvider.family<GenerationTask, String>((ref, id) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getTask(id, snapshots: false);
});

final _inputSnapshotProvider = FutureProvider.autoDispose
    .family<String, String>((ref, id) async {
      // Queued agent input is replaced when execution starts.
      ref.watch(taskProvider(id).select((value) => value.value?.status));
      return const JsonEncoder.withIndent('  ')
          .convert((await ref.watch(repositoryProvider).getTask(id)).input);
    });

List<Map> _taskMessages(GenerationTask task, List<AgentMessage> messages) {
  final start = messages.indexWhere(
    (m) => m.id == task.input['sourceMessageId'] && m.role == 'user',
  );
  final owned = messages.where((m) => m.raw['taskId'] == task.id).toList();
  return [
    if (start >= 0) messages[start].toWire(),
    if (task.result['transcript'] case final List transcript)
      ...transcript.whereType<Map>()
    else if (owned.isNotEmpty)
      ...owned.map((m) => m.toWire())
    // Legacy turns lack ownership; a retry cannot reuse their whole history.
    else if (start >= 0 && task.retryOf == null)
      for (final message
          in messages.skip(start + 1).takeWhile((m) => m.role != 'user'))
        if (message.raw['taskId'] == null &&
            (task.isActive || !message.createdAt.isAfter(task.updatedAt)))
          message.toWire(),
  ];
}

Map? _toolResult(Object? content) {
  if (content is Map) return content;
  if (content is! String) return null;
  try {
    final decoded = jsonDecode(content);
    return decoded is Map ? decoded : null;
  } on FormatException {
    return null;
  }
}

typedef _ToolStep = ({String name, Map? result});

List<_ToolStep> _toolSteps(List<Map> messages) => [
  for (final message in messages)
    if (message['tool_calls'] case final List calls)
      for (final call in calls.whereType<Map>())
        if (call['function'] case {'name': final String name})
          (
            name: name,
            result: _toolResult(
              messages
                  .where(
                    (m) =>
                        m['role'] == 'tool' && m['tool_call_id'] == call['id'],
                  )
                  .firstOrNull?['content'],
            ),
          ),
];

const _toolLabels = {
  'read_novel': '读取作品信息',
  'update_novel': '更新作品信息',
  'list_lore': '查找资料',
  'read_lore': '读取资料',
  'propose_lore': '整理资料建议',
  'list_chapters': '查看章节目录',
  'read_chapter': '读取章节',
  'search_story': '搜索正文',
  'create_chapter': '创建章节',
  'rename_chapter': '修改章节名称',
  'delete_chapter': '删除章节',
  'propose_chapter': '生成正文',
  'generate_image': '生成插画',
  'generate_images': '批量生成插画',
  'insert_images': '插入插画',
  'activate_skill': '加载创作技能',
};

Iterable<Map> _toolResults(Map? result) sync* {
  if (result == null) return;
  yield result;
  for (final key in ['images', 'results']) {
    if (result[key] case final List entries) {
      for (final entry in entries.whereType<Map>()) {
        yield* _toolResults(entry);
      }
    }
  }
}

bool _toolFailed(Map? result) => _toolResults(result).any(
  (entry) =>
      entry['error'] != null ||
      ['failed', 'interrupted', 'cancelled'].contains(entry['status']) ||
      entry['cancelled'] == true,
);

String _qualityMessage(GenerationTask task, Map quality) =>
    switch (quality['status']) {
      'reviewing' ||
      'revising' ||
      'checking' when !task.isActive => switch (task.status) {
        TaskStatus.cancelled => '自动审读已取消。',
        TaskStatus.interrupted => '自动审读已中断。',
        TaskStatus.failed => '自动审读未完成，任务已失败。',
        _ => '自动审读已结束。',
      },
      'reviewing' => '正在自动审读正文…',
      'revising' => '正在修订发现的问题…',
      'checking' => '正在复查修订结果…',
      'passed' => '自动审读未发现需要修订的问题。',
      'revised' => '已自动修订并通过复查。',
      'kept_original' => '修订稿未通过复查，已保留原稿。',
      _ => quality['message'] as String? ?? '自动审读已结束。',
    };

class TaskScreen extends ConsumerWidget {
  const TaskScreen({super.key, required this.taskId});
  final String taskId;

  void _open(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => screen));

  Widget _button(String text, VoidCallback onPress, {bool primary = false}) =>
      FButton(
        mainAxisSize: MainAxisSize.min,
        size: FButtonSizeVariant.sm,
        variant: primary ? FButtonVariant.primary : FButtonVariant.outline,
        onPress: onPress,
        child: Text(text),
      );

  Widget _card(List<Widget> children) => FCard(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: context.theme.typography.body.md.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '任务详情',
    body: AsyncView(
      value: ref.watch(taskProvider(taskId)),
      builder: (task) => _details(context, ref, task),
    ),
  );

  Widget _details(BuildContext context, WidgetRef ref, GenerationTask task) {
    final storyValue = ref.watch(storyProvider(task.branchId));
    final story = storyValue.value;
    final conversation = task.input['conversationId'] as String?;
    final messagesValue = conversation == null
        ? null
        : ref.watch(messagesProvider(conversation));
    final messages = _taskMessages(task, messagesValue?.value ?? []);
    final steps = _toolSteps(messages);
    final toolResults = [
      for (final step in steps) ..._toolResults(step.result),
    ];
    final childIds = <String>{
      if (task.result['imageTaskId'] case final String id) id,
      ...(task.result['imageTaskIds'] as List? ?? const []).whereType<String>(),
      for (final result in toolResults)
        if (result['taskId'] case final String id) id,
    };
    final tasksValue =
        task.kind == TaskKind.agent || task.kind == TaskKind.sidecar
        ? ref.watch(tasksProvider(task.branchId))
        : null;
    final children = (tasksValue?.value ?? <GenerationTask>[])
        .where(
          (t) =>
              t.id != task.id &&
              (childIds.contains(t.id) || t.input['parentTaskId'] == task.id),
        )
        .toList();
    final results = [
      task.result,
      ...toolResults,
      ...children.map((t) => t.result),
    ];
    final assetIds = <String>{
      for (final result in results) ...[
        if (result['assetId'] case final String id) id,
        ...(result['assetIds'] as List? ?? const []).whereType<String>(),
      ],
    };
    final proposalIds = <String>{
      for (final result in results)
        if (result['proposalId'] case final String id) id,
    };
    final proposalValues = [
      for (final id in proposalIds) ref.watch(proposalProvider(id)),
    ];
    final proposals = [for (final value in proposalValues) ?value.value];
    final pending = proposals
        .where((p) => p.status == ProposalStatus.pending)
        .toList();
    final writtenIds = <String>{
      if (task.result['writtenChapters'] case final Map written)
        ...written.keys.whereType<String>(),
      for (final proposal in proposals)
        if (proposal.status == ProposalStatus.accepted) proposal.chapterId,
      for (final result in toolResults)
        if (result['accepted'] == true && result['chapterId'] is String)
          result['chapterId'] as String,
    };
    final reviews = [
      for (final t in [task, ...children])
        if (t.kind == TaskKind.analysis && t.status == TaskStatus.completed) t,
    ];
    final failedChildren = children
        .where((t) => !t.isActive && t.status != TaskStatus.completed)
        .toList();
    final waiting = task.isActive && task.result['imageConfirmation'] is Map;
    final unfinished = steps.where((s) => s.result == null).firstOrNull;
    final hadToolErrors = steps.any((s) => _toolFailed(s.result));
    final hasResults = writtenIds.isNotEmpty || assetIds.isNotEmpty;
    final heading = waiting
        ? '等待你确认插画'
        : !task.isActive && pending.isNotEmpty
        ? '正文尚未写入'
        : task.status == TaskStatus.completed && failedChildren.isNotEmpty
        ? '部分操作未完成'
        : task.status == TaskStatus.running && unfinished != null
        ? '正在${_toolLabels[unfinished.name] ?? '执行工具'}'
        : task.status == TaskStatus.completed
        ? '本次任务已完成'
        : taskStatusLabels[task.status]!;
    final request = [
      if (messages.firstOrNull?['role'] == 'user') messages.first['content'],
      task.input['agentMessage'],
      task.input['brief'],
      task.input['name'],
    ].whereType<String>().where((s) => s.trim().isNotEmpty).firstOrNull;
    final chapterId =
        task.chapterId ??
        task.input['editChapterId'] ??
        task.input['throughChapterId'];
    final contextChapter = story?.chapters
        .where((c) => c.id == chapterId)
        .firstOrNull;
    final output = task.result['text'] as String? ?? task.partialText;
    final errors = [
      storyValue.error,
      messagesValue?.error,
      tasksValue?.error,
      ...proposalValues.map((v) => v.error),
    ].whereType<Object>();
    final muted = context.theme.typography.body.sm.copyWith(
      color: context.theme.colors.mutedForeground,
    );
    final canReconnect =
        task.isRemote &&
        [TaskStatus.failed, TaskStatus.interrupted].contains(task.status);

    void openConversation() => _open(
      context,
      PageScaffold(
        title: '助手',
        body: AgentPanel(branchId: task.branchId, conversationId: conversation),
      ),
    );

    final actions = <Widget>[
      if (waiting && conversation != null)
        _button('前往确认', openConversation, primary: true),
      if (canReconnect)
        _button('获取远程结果', () async {
          try {
            await ref.read(servicesProvider).runner.reconnectRemote(task.id);
          } catch (e) {
            if (context.mounted) showError(context, e);
          }
        }, primary: true),
      if (!task.isActive && task.status != TaskStatus.completed)
        _button('重新生成（新任务）', () async {
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
        }),
      if (!waiting && conversation != null) _button('回到创作会话', openConversation),
      if (task.isActive || canReconnect)
        FButton(
          variant: FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          size: FButtonSizeVariant.sm,
          onPress: () async {
            try {
              await ref.read(servicesProvider).runner.cancel(task.id);
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          child: const Text('取消生成'),
        ),
    ];

    return ContentLayout(
      maxWidth: 920,
      builder: (_, inset) => SingleChildScrollView(
        padding: inset + const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              [
                if (story != null) ...[story.novel.title, story.branch.name],
                if (contextChapter != null) contextChapter.title,
                taskKindLabels[task.kind]!,
              ].join(' / '),
              style: muted,
            ),
            const SizedBox(height: 8),
            Text(
              request ?? taskKindLabels[task.kind]!,
              style: context.theme.typography.body.xl.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            _card([
              Semantics(
                liveRegion: true,
                child: Text(
                  heading,
                  style: context.theme.typography.body.lg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                waiting
                    ? '插画方案已准备好，请在原会话中确认后继续。'
                    : pending.isNotEmpty
                    ? '生成的正文已保留，请查看后决定如何处理。'
                    : failedChildren.isNotEmpty && hasResults
                    ? '已保存的内容仍可查看，下方保留了未完成任务的入口。'
                    : task.status == TaskStatus.completed && hadToolErrors
                    ? '执行过程中曾有工具失败，原因保留在下方记录中。'
                    : switch (task.status) {
                        TaskStatus.queued => '轮到本任务后会自动开始。',
                        TaskStatus.running => '可以离开此页继续创作，请保持应用运行。',
                        TaskStatus.completed =>
                          hasResults ? '已保存的内容可在下方打开。' : '可查看下方回复和执行记录。',
                        TaskStatus.failed =>
                          hasResults
                              ? '任务未全部完成，已保存的内容仍可查看。'
                              : '查看错误原因后，可以重新生成。',
                        TaskStatus.cancelled => '生成已停止，已保存的内容会保留。',
                        TaskStatus.interrupted =>
                          task.isRemote
                              ? '本地连接已中断，任务可能仍在服务端执行。获取远程结果会连接同一任务；重新生成会发起新的模型请求。'
                              : '之前的模型连接已中断。重新生成会创建新任务并再次发起模型请求。',
                      },
              ),
              if (task.isActive && !waiting) ...[
                const SizedBox(height: 12),
                const FProgress(),
              ],
              if (task.kind == TaskKind.illustration && task.isActive) ...[
                const SizedBox(height: 12),
                Text(
                  task.result['stage'] == 'saving'
                      ? '正在保存图片到本地…'
                      : '正在等待生图服务返回图片…',
                ),
              ],
              if (task.result['quality'] case final Map quality) ...[
                const SizedBox(height: 12),
                Text(_qualityMessage(task, quality)),
              ],
              if (task.error.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(
                  task.error,
                  style: TextStyle(color: context.theme.colors.error),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ]),
            if (errors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text('部分详情暂不可用：${errors.first}', style: muted),
              ),
            if (pending.isNotEmpty ||
                hasResults ||
                reviews.isNotEmpty ||
                failedChildren.isNotEmpty ||
                (task.kind == TaskKind.branches &&
                    task.status == TaskStatus.completed))
              _section(context, '本次产物', [
                for (final proposal in pending)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _card([
                      Text(
                        story?.chapters
                                .where((c) => c.id == proposal.chapterId)
                                .firstOrNull
                                ?.title ??
                            '生成的正文',
                      ),
                      const SizedBox(height: 4),
                      Text('已保留，尚未写入章节', style: muted),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _button(
                          '处理未写入的正文',
                          () => _open(
                            context,
                            ProposalScreen(proposalId: proposal.id),
                          ),
                          primary: true,
                        ),
                      ),
                    ]),
                  ),
                for (final id in writtenIds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _card([
                      Text(
                        story?.chapters
                                .where((c) => c.id == id)
                                .firstOrNull
                                ?.title ??
                            '已写入的章节',
                      ),
                      const SizedBox(height: 4),
                      Text('正文已写入 · 打开章节查看当前版本', style: muted),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _button(
                          '查看正文',
                          () => _open(
                            context,
                            ReaderScreen(
                              branchId: task.branchId,
                              chapterId: id,
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                if (assetIds.isNotEmpty)
                  LayoutBuilder(
                    builder: (context, bounds) {
                      final columns = MediaQuery.sizeOf(context).width >= 900
                          ? 2
                          : 1;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final id in assetIds)
                            SizedBox(
                              width:
                                  (bounds.maxWidth - (columns - 1) * 12) /
                                  columns,
                              child: _card([
                                AssetImageView(
                                  assetId: id,
                                  height: 160,
                                  thumbnail: true,
                                ),
                                const SizedBox(height: 12),
                                _button(
                                  '查看插画与使用方式',
                                  () => showIllustrationDetail(
                                    context,
                                    assetId: id,
                                    branchId: task.branchId,
                                  ),
                                ),
                              ]),
                            ),
                        ],
                      );
                    },
                  ),
                for (final review in reviews)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _button(
                        '审阅资料提取',
                        () => _open(
                          context,
                          AnalysisReviewScreen(taskId: review.id),
                        ),
                      ),
                    ),
                  ),
                if (task.kind == TaskKind.branches &&
                    task.status == TaskStatus.completed)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _button(
                      '比较候选走向',
                      () => _open(context, CandidateScreen(taskId: task.id)),
                    ),
                  ),
                for (final child in failedChildren)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _card([
                      Text(
                        '${child.input['name'] ?? taskKindLabels[child.kind]} · ${taskStatusLabels[child.status]}',
                      ),
                      if (child.error.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(child.error),
                      ],
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: _button(
                          '查看任务',
                          () => _open(context, TaskScreen(taskId: child.id)),
                        ),
                      ),
                    ]),
                  ),
              ]),
            if (steps.isNotEmpty)
              _section(context, '执行过程', [
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _toolFailed(steps[i].result)
                              ? FLucideIcons.circleAlert
                              : steps[i].result?['accepted'] == false
                              ? FLucideIcons.clock
                              : steps[i].result != null
                              ? FLucideIcons.check
                              : FLucideIcons.clock,
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _toolLabels[steps[i].name] ??
                                    '工具 · ${steps[i].name}',
                              ),
                              for (final result in _toolResults(
                                steps[i].result,
                              ))
                                if (result['error'] case final error?) ...[
                                  const SizedBox(height: 4),
                                  Text(error.toString(), style: muted),
                                ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _toolFailed(steps[i].result)
                              ? '未完成'
                              : steps[i].result?['accepted'] == false
                              ? '未采纳'
                              : steps[i].result != null
                              ? '已完成'
                              : !task.isActive
                              ? '未完成'
                              : waiting &&
                                    [
                                      'generate_image',
                                      'generate_images',
                                    ].contains(steps[i].name)
                              ? '等待确认'
                              : i == steps.indexWhere((s) => s.result == null)
                              ? '进行中'
                              : '等待执行',
                          style: muted,
                        ),
                      ],
                    ),
                  ),
              ]),
            if (output.trim().isNotEmpty)
              _section(context, task.kind == TaskKind.agent ? '编辑回复' : '模型输出', [
                _card([
                  SelectableText(output, style: const TextStyle(height: 1.7)),
                ]),
              ]),
            const SizedBox(height: 24),
            FAccordion(
              children: [
                FAccordionItem(
                  title: const Text('诊断信息'),
                  child: FAccordion(
                    children: [
                      if (messages.isNotEmpty)
                        FAccordionItem(
                          title: const Text('模型输出与工具记录'),
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ')
                                .convert(messages),
                          ),
                        ),
                      if (task.reasoning.isNotEmpty)
                        FAccordionItem(
                          title: const Text('模型返回的推理摘要'),
                          child: SelectableText(task.reasoning),
                        ),
                      if (task.result.isNotEmpty)
                        FAccordionItem(
                          title: const Text('结果记录'),
                          child: SelectableText(
                            const JsonEncoder.withIndent('  ')
                                .convert(task.result),
                          ),
                        ),
                      FAccordionItem(
                        title: const Text('本次输入快照'),
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
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
