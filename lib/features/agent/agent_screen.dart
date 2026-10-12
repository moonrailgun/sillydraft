import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../resources/writing_profile.dart';
import '../settings/settings_screen.dart';
import 'agent_providers.dart';
import 'proposal_screen.dart';
import 'task_screen.dart';
import 'writing_request_screen.dart';

class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key, required this.branchId, this.sceneId});
  final String branchId;
  final String? sceneId;
  @override
  ConsumerState<AgentScreen> createState() => _AgentState();
}

class _AgentState extends ConsumerState<AgentScreen> {
  final _input = TextEditingController();
  String? _conversation;
  bool _sending = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final repo = ref.read(repositoryProvider),
          conversations = await ref
              .read(repositoryProvider)
              .listConversations(widget.branchId);
      final all = conversations
          .where((c) => c['through_scene_id'] == widget.sceneId)
          .toList();
      final id = all.isEmpty
          ? await repo.createConversation(
              branchId: widget.branchId,
              throughSceneId: widget.sceneId,
            )
          : all.first['id'] as String;
      if (mounted) setState(() => _conversation = id);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _newConversation() async {
    try {
      final id = await ref
          .read(repositoryProvider)
          .createConversation(
            branchId: widget.branchId,
            throughSceneId: widget.sceneId,
          );
      if (mounted) setState(() => _conversation = id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _send() async {
    if (_input.text.trim().isEmpty || _conversation == null) return;
    final text = _input.text;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final services = ref.read(servicesProvider),
          connection = await ref.read(servicesProvider).connectionFor('editor');
      if (connection == null) throw const FormatException('请先在模型设置里配置编辑助手连接。');
      final profile = await WritingContext.load(services, widget.branchId);
      await services.editor.send(
        conversationId: _conversation!,
        connection: connection,
        message: text,
        writingConnection: await services.connectionFor('writing'),
        writingPreset: profile.preset,
        card: profile.card,
        userName: profile.userName,
        persona: profile.persona,
        selectedOrderId: profile.selectedOrderId,
        worldBooks: profile.books,
        globalRegex: profile.regex,
      );
      if (mounted) _input.clear();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete() async {
    final id = _conversation;
    if (id == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这段编辑会话？'),
        content: const Text('会话消息将删除，运行任务会先停止。正文、候选和资料会保留；任务记录中的输入快照也会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除会话'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final services = ref.read(servicesProvider);
      for (final task in await services.repository.listTasks(
        branchId: widget.branchId,
        activeOnly: true,
      )) {
        if (task.input['conversationId'] == id) {
          await services.runner.cancel(task.id);
          await services.runner.wait(task.id);
        }
      }
      await services.repository.deleteConversation(id);
      if (mounted) {
        setState(() => _conversation = null);
        await _initialize();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _generate() async {
    try {
      final story = await ref
          .read(repositoryProvider)
          .getStory(widget.branchId);
      if (story.scenes.isEmpty) throw const FormatException('请先在正文目录创建场景。');
      if (!mounted) return;
      Scene? scene = story.scenes
          .where((s) => s.id == widget.sceneId)
          .firstOrNull;
      scene ??= await showModalBottomSheet<Scene>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('选择生成目标场景')),
              for (final s in story.scenes)
                ListTile(
                  title: Text(s.title),
                  onTap: () => Navigator.pop(context, s),
                ),
            ],
          ),
        ),
      );
      if (scene == null || !mounted) return;
      final task = await Navigator.push<GenerationTask>(
        context,
        MaterialPageRoute(builder: (_) => WritingRequestScreen(scene: scene!)),
      );
      if (task != null && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider(widget.branchId)).value ?? [];
    final active = tasks
        .where(
          (t) =>
              t.kind == TaskKind.agent &&
              t.input['conversationId'] == _conversation &&
              t.isActive,
        )
        .firstOrNull;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('创作助手'),
          actions: [
            IconButton(
              tooltip: '角色卡与预设',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      WritingProfileScreen(branchId: widget.branchId),
                ),
              ),
              icon: const Icon(Icons.tune),
            ),
            PopupMenuButton<String>(
              tooltip: '助手设置',
              onSelected: (v) {
                if (v == 'models') {
                  Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(),
                    ),
                  );
                } else {
                  _delete();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'models', child: Text('模型设置')),
                PopupMenuItem(value: 'delete', child: Text('删除当前会话')),
              ],
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '编辑对话'),
              Tab(text: '正文候选'),
              Tab(text: '任务记录'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: TabBarView(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      widget.sceneId == null
                          ? '编辑位置：当前分支末尾'
                          : '编辑位置：${ref.watch(storyProvider(widget.branchId)).value?.scenes.where((s) => s.id == widget.sceneId).firstOrNull?.title ?? '当前场景'} · 仅参考截至此处的资料',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: AsyncView(
                            value: ref.watch(
                              conversationsProvider(widget.branchId),
                            ),
                            builder: (conversations) {
                              final all = conversations
                                  .where(
                                    (c) =>
                                        c['through_scene_id'] == widget.sceneId,
                                  )
                                  .toList();
                              return DropdownButton<String>(
                                isExpanded: true,
                                value: all.any((c) => c['id'] == _conversation)
                                    ? _conversation
                                    : null,
                                hint: const Text('选择会话'),
                                items: [
                                  for (final (i, c) in all.indexed)
                                    DropdownMenuItem(
                                      value: c['id'] as String,
                                      child: Text(
                                        '${c['title']} · ${all.length - i}',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setState(() => _conversation = v),
                              );
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: '新建编辑会话',
                          onPressed: _newConversation,
                          icon: const Icon(Icons.add_comment_outlined),
                        ),
                        IconButton(
                          tooltip: '删除当前会话',
                          onPressed: _delete,
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Text(
                        _error.toString(),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Expanded(
                    child: _conversation == null
                        ? const Center(child: CircularProgressIndicator())
                        : AsyncView(
                            value: ref.watch(messagesProvider(_conversation!)),
                            builder: (messages) => ListView(
                              padding: const EdgeInsets.all(20),
                              children: [
                                if (messages.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 40),
                                    child: Column(
                                      children: [
                                        Icon(
                                          Icons.auto_awesome_outlined,
                                          size: 40,
                                        ),
                                        SizedBox(height: 16),
                                        Text(
                                          '聊人物、推情节，或让助手生成正文候选。',
                                          textAlign: TextAlign.center,
                                        ),
                                        SizedBox(height: 8),
                                        Text(
                                          '这里的对话会独立保存。',
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                                for (final message in messages)
                                  _message(message),
                                if (active != null)
                                  Card(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          const LinearProgressIndicator(),
                                          const SizedBox(height: 12),
                                          SelectableText(
                                            active.partialText.isEmpty
                                                ? '编辑助手正在工作…'
                                                : active.partialText,
                                          ),
                                          const SizedBox(height: 8),
                                          TextButton(
                                            onPressed: () => Navigator.push(
                                              context,
                                              MaterialPageRoute<void>(
                                                builder: (_) => TaskScreen(
                                                  taskId: active.id,
                                                ),
                                              ),
                                            ),
                                            child: const Text('查看工具与任务'),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _generate,
                                icon: const Icon(Icons.edit_note),
                                label: const Text('生成正文候选'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: TextField(
                                key: const Key('agent-input'),
                                controller: _input,
                                minLines: 1,
                                maxLines: 5,
                                decoration: const InputDecoration(
                                  hintText: '向编辑助手描述你的想法…',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (active != null)
                              IconButton.filled(
                                tooltip: '停止编辑回复',
                                onPressed: () async {
                                  try {
                                    await ref
                                        .read(servicesProvider)
                                        .runner
                                        .cancel(active.id);
                                  } catch (e) {
                                    if (context.mounted) showError(context, e);
                                  }
                                },
                                icon: const Icon(Icons.stop),
                              )
                            else
                              IconButton.filled(
                                tooltip: '发送给编辑助手',
                                onPressed: _sending ? null : _send,
                                icon: const Icon(Icons.arrow_upward),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              AsyncView(
                value: ref.watch(proposalsProvider(widget.branchId)),
                builder: (proposals) => proposals.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('生成的正文会先放在这里，等你审阅。'),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _generate,
                              child: const Text('生成正文候选'),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(20),
                        itemCount: proposals.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          final p = proposals[i];
                          return Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(16),
                              title: Text(
                                p.status == ProposalStatus.pending
                                    ? '待审阅正文'
                                    : p.status == ProposalStatus.accepted
                                    ? '已采纳'
                                    : '已拒绝',
                              ),
                              subtitle: Text(
                                p.content.text,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.compare_arrows),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) =>
                                      ProposalScreen(proposalId: p.id),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              AsyncView(
                value: ref.watch(tasksProvider(widget.branchId)),
                builder: (tasks) => tasks.isEmpty
                    ? const Center(child: Text('生成任务会保留输入、进度和结果。'))
                    : ListView.separated(
                        padding: const EdgeInsets.all(20),
                        itemCount: tasks.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, i) {
                          final task = tasks[i];
                          return Card(
                            child: ListTile(
                              title: Text(
                                '${taskKindLabels[task.kind]} · ${taskStatusLabels[task.status]}',
                              ),
                              subtitle: Text(
                                task.error.isNotEmpty
                                    ? task.error
                                    : task.partialText.isNotEmpty
                                    ? task.partialText
                                    : '等待模型输出',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: task.isActive
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(),
                                    )
                                  : const Icon(Icons.chevron_right),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => TaskScreen(taskId: task.id),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message(AgentMessage message) {
    final metadata = message.raw;
    if (message.role == 'tool' || metadata['tool_calls'] != null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ExpansionTile(
          title: Text(message.role == 'tool' ? '工具结果' : '工具调用'),
          subtitle: message.content.isEmpty
              ? null
              : Text(
                  message.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                message.role == 'tool'
                    ? message.content
                    : const JsonEncoder.withIndent('  ').convert(metadata),
              ),
            ),
          ],
        ),
      );
    }
    return Align(
      alignment: message.role == 'user'
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: message.role == 'user'
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.role == 'user' ? '你' : '编辑助手',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(
              message.content,
              style: const TextStyle(height: 1.6),
            ),
          ],
        ),
      ),
    );
  }
}
