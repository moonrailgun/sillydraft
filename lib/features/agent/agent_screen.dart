import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart'
    show
        CupertinoTextSelectionToolbar,
        CupertinoTextSelectionToolbarButton,
        CupertinoTheme,
        CupertinoThemeData;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/services.dart';
import '../../app/theme.dart' show touchPlatform;
import '../../app/widgets.dart';
import '../illustrations/asset_image.dart';
import '../illustrations/illustration_detail.dart';
import '../lore/sidecar.dart';
import '../presets/preset_screen.dart';
import '../skills/skill_providers.dart';
import '../skills/skills_screen.dart';
import '../resources/writing_profile.dart'
    show WritingContext, assistantUsesPresetKey, resourcesProvider;
import '../settings/settings_screen.dart';
import 'agent_providers.dart';
import 'proposal_screen.dart';
import 'task_screen.dart';
import 'writing_request_screen.dart';

/// The assistant as a large floating window over the current page, for
/// phones: the manuscript stays visible above it and a swipe down dismisses it.
Future<void> showAssistantSheet(
  BuildContext context, {
  required String branchId,
  String? chapterId,
}) => showAppSheet<void>(
  context: context,
  mainAxisMaxRatio: null,
  builder: (context) {
    final media = MediaQuery.of(context);
    // Leave a strip of the page visible; the sheet itself rises above the
    // keyboard.
    final height = (media.size.height * .92 - media.viewInsets.bottom).clamp(
      240.0,
      double.infinity,
    );
    return SizedBox(
      key: const Key('assistant-sheet'),
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '助手',
                    style: context.theme.typography.body.lg.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconAction(
                  icon: FLucideIcons.chevronDown,
                  tooltip: '收起助手',
                  onPress: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: AgentPanel(branchId: branchId, chapterId: chapterId),
          ),
        ],
      ),
    );
  },
);

const _starterPrompts = [
  '检查最近几个章节里人物的动机是否一致',
  '梳理目前埋下的伏笔，哪些还没有回收',
  '为下一个章节提出三种不同的发展',
];

/// A message sent to the assistant on the author's behalf, such as "draw this
/// selection" from the reader, with the chapter it came from as context.
/// Each instance is sent once.
final class AgentRequest {
  AgentRequest(
    this.message, {
    this.chapterId,
    this.replace,
    this.illustrationBatch = false,
    this.illustrationAnchor,
  });
  final String message;
  final String? chapterId;
  final bool illustrationBatch;
  final Map<String, dynamic>? illustrationAnchor;

  /// The author's earlier message this one takes the place of, along with
  /// every turn after it.
  final String? replace;
}

/// The editing assistant for one story branch: conversation, manuscript
/// candidates awaiting review, and the task history, in one place. It is a
/// section of the novel workspace and sits beside the editor.
class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({
    super.key,
    required this.branchId,
    this.chapterId,
    this.focusChapterId,
    this.request,
  });
  final String branchId;

  /// Sent as soon as it arrives; see [AgentRequest].
  final AgentRequest? request;

  /// Story position the assistant is limited to; null means the end of the
  /// branch.
  final String? chapterId;

  /// The chapter shown beside the assistant: what "this chapter" and the quick
  /// actions mean.
  final String? focusChapterId;

  @override
  ConsumerState<AgentPanel> createState() => _AgentState();
}

class _AgentState extends ConsumerState<AgentPanel> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  late String? _chapter = widget.chapterId;
  String? _conversation;
  late Future<void> _selecting;
  bool _sending = false;
  Object? _error;

  /// The author's message being rewritten in the input, if any.
  AgentMessage? _editing;

  /// A message's actions on a phone, brought up by a long press.
  final _menu = ContextMenuController();
  @override
  void initState() {
    super.initState();
    _selecting = _selectConversation();
    if (widget.request case final request?) _send(request);
  }

  @override
  void didUpdateWidget(AgentPanel old) {
    super.didUpdateWidget(old);
    if (old.chapterId != widget.chapterId) _moveTo(widget.chapterId);
    if (widget.request case final request? when request != old.request) {
      _send(request);
    }
  }

  @override
  void dispose() {
    _menu.remove();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _moveTo(String? chapter) {
    setState(() {
      _chapter = chapter;
      _conversation = null;
    });
    _selecting = _selectConversation();
  }

  /// Opens the latest conversation at this story position. Nothing is created
  /// until the author sends a message, so browsing never leaves empty chats.
  Future<void> _selectConversation() async {
    try {
      final all = (await ref
          .read(repositoryProvider)
          .listConversations(widget.branchId));
      final here = all.where((c) => c['through_chapter_id'] == _chapter);
      if (mounted) {
        setState(() => _conversation = here.firstOrNull?['id'] as String?);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<String> _ensureConversation() async => _conversation ??= await ref
      .read(repositoryProvider)
      .createConversation(
        branchId: widget.branchId,
        throughChapterId: _chapter,
      );

  Future<void> _newConversation() async {
    try {
      final id = await ref
          .read(repositoryProvider)
          .createConversation(
            branchId: widget.branchId,
            throughChapterId: _chapter,
          );
      if (mounted) setState(() => _conversation = id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// [text] in place of the author's [message], which goes along with every
  /// turn after it.
  AgentRequest _replacing(AgentMessage message, String text) => AgentRequest(
    text,
    chapterId: switch (message.raw['attachment']) {
      {'chapterId': final String id} => id,
      _ => null,
    },
    replace: message.id,
    illustrationBatch: message.raw['illustrationBatch'] == true,
    illustrationAnchor:
        message.raw['illustrationAnchor'] as Map<String, dynamic>?,
  );

  /// Puts the author's [message] back in the input; sending it then asks
  /// that turn again.
  void _edit(AgentMessage message) {
    setState(() {
      _editing = message;
      _input.text = message.content;
      _input.selection = TextSelection.collapsed(
        offset: message.content.length,
      );
    });
    _inputFocus.requestFocus();
  }

  /// Sends what the author typed, or [request] on their behalf.
  Future<void> _send([AgentRequest? request]) async {
    final typed = request == null, editing = _editing;
    if (typed && editing != null && editing.conversationId == _conversation) {
      request = _replacing(editing, _input.text);
    }
    final text = request?.message ?? _input.text;
    if (_sending || text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final services = ref.read(servicesProvider),
          connection = await services.connectionFor('editor');
      if (connection == null) throw const FormatException('请先在模型设置里配置编辑助手连接。');
      await _selecting;
      final conversation = await _ensureConversation();
      if (mounted) setState(() {});
      final profile = await WritingContext.load(services, widget.branchId);
      final task = await services.editor.send(
        conversationId: conversation,
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
        chatPreset: profile.assistantPreset,
        skills: await services.skills.enabled(),
        focusChapterId: widget.focusChapterId ?? _chapter,
        imageConnection: await services.connectionFor('image'),
        attachChapterId: request?.chapterId,
        illustrationBatch: request?.illustrationBatch ?? false,
        illustrationAnchor: request?.illustrationAnchor,
        replaceMessageId: request?.replace,
      );
      unawaited(_sidecarAfterRound(services, task).catchError((Object _) {}));
      if (mounted && typed) {
        _input.clear();
        _editing = null;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  final _insertingImages = <String>{};

  Future<void> _insertImage(String assetId, AgentMessage imageMessage) async {
    if (!_insertingImages.add(assetId)) return;
    setState(() {});
    try {
      final services = ref.read(servicesProvider);
      await services.flushDrafts();
      final messages = await services.repository.getAgentMessages(
        imageMessage.conversationId,
      );
      final source = messages
          .takeWhile((m) => m.id != imageMessage.id)
          .where((m) => m.role == 'user')
          .lastOrNull;
      if (source == null) throw const FormatException('找不到这张图片引用的正文');
      await services.repository.insertAgentIllustration(
        branchId: widget.branchId,
        assetId: assetId,
        source: source,
      );
      if (mounted) toast(context, '已插入引用段落下方');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _insertingImages.remove(assetId);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete() async {
    final id = _conversation;
    if (id == null) return;
    final confirm = await confirmAction(
      context,
      title: '删除这段编辑会话？',
      message: '会话消息将删除，运行任务会先停止。正文和资料会保留；任务记录中的输入快照也会保留。',
      confirmLabel: '删除会话',
      destructive: true,
    );
    if (!confirm || !mounted) return;
    try {
      final services = ref.read(servicesProvider);
      final active =
          (await services.repository.listTasks(
            branchId: widget.branchId,
            activeOnly: true,
          )).where((t) => t.input['conversationId'] == id).toList()..sort(
            (a, b) => (a.status == TaskStatus.running ? 1 : 0).compareTo(
              b.status == TaskStatus.running ? 1 : 0,
            ),
          );
      // Cancel the queue before its running head can release another turn.
      for (final task in active) {
        await services.runner.cancel(task.id);
      }
      for (final task in active) {
        await services.runner.wait(task.id);
      }
      await services.repository.deleteConversation(id);
      if (mounted) {
        setState(() => _conversation = null);
        await _selectConversation();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _retryQueued(GenerationTask task) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final services = ref.read(servicesProvider);
      final retry = await services.runner.resume(task.id);
      unawaited(_sidecarAfterRound(services, retry).catchError((Object _) {}));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<Chapter?> _pickChapter(StorySnapshot story) => showAppSheet<Chapter>(
    context: context,
    title: '选择生成目标章节',
    mainAxisMaxRatio: .7,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: FTileGroup(
        children: [
          for (final s in story.chapters)
            FTile(
              title: Text(s.title.isEmpty ? '未命名章节' : s.title),
              onPress: () => Navigator.pop(context, s),
            ),
        ],
      ),
    ),
  );

  Future<void> _choosePosition() async {
    try {
      final story = await ref
          .read(repositoryProvider)
          .getStory(widget.branchId);
      if (!mounted) return;
      // A record separates "branch end" (chapter: null) from dismissing the sheet.
      final choice = await showAppSheet<({String? chapter})>(
        context: context,
        title: '助手参考到哪个故事位置',
        mainAxisMaxRatio: .7,
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text(
                '只读取截至此处的正文与资料，不会提前看到之后的内容',
                style: context.theme.typography.body.sm.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: FTileGroup(
                  children: [
                    FTile(
                      prefix: Icon(
                        _chapter == null ? FLucideIcons.check : null,
                      ),
                      title: const Text('当前分支末尾'),
                      onPress: () => Navigator.pop(context, (chapter: null)),
                    ),
                    for (final s in story.chapters)
                      FTile(
                        prefix: Icon(
                          _chapter == s.id ? FLucideIcons.check : null,
                        ),
                        title: Text(s.title.isEmpty ? '未命名章节' : s.title),
                        onPress: () => Navigator.pop(context, (chapter: s.id)),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      if (choice != null && mounted && choice.chapter != _chapter) {
        _moveTo(choice.chapter);
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
      if (story.chapters.isEmpty) throw const FormatException('请先在正文目录创建章节。');
      if (!mounted) return;
      Chapter? chapter = story.chapters
          .where((s) => s.id == _chapter)
          .firstOrNull;
      chapter ??= await _pickChapter(story);
      if (chapter == null || !mounted) return;
      final task = await Navigator.push<GenerationTask>(
        context,
        MaterialPageRoute(
          builder: (_) => WritingRequestScreen(chapter: chapter!),
        ),
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

  /// The assistant's image call waits on this card; nothing
  /// reaches the image engine until the author confirms.
  Widget _imageConfirmation(GenerationTask task, Map<String, dynamic> pending) {
    final batch = pending['images'] is List;
    final previews = batch
        ? (pending['images'] as List).cast<Map<String, dynamic>>()
        : [pending];
    final theme = context.theme;
    final engine = ModelConnection.fromJson(
      (task.input['image'] as Map)['connection'] as Map<String, dynamic>,
    );
    final label = theme.typography.body.xs.copyWith(
      color: theme.colors.mutedForeground,
      fontWeight: FontWeight.w600,
    );
    // A remote runner answers over the network, which can fail.
    Future<void> answer(bool approved) async {
      try {
        await ref
            .read(servicesProvider)
            .runner
            .respondToImageConfirmation(
              task.id,
              pending['id'] as String,
              approved: approved,
            );
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }

    return FCard(
      key: const Key('agent-image-confirmation'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(FLucideIcons.image, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    batch
                        ? '生成 ${previews.length} 张本章亮点插图？'
                        : '生成插图「${pending['name']}」？',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('生图引擎', style: label),
            const SizedBox(height: 4),
            Text(imageEngineLabel(engine)),
            if (batch) const Text('确认后按顺序逐张生成；取消或失败会停止后续图片。'),
            for (final (index, preview) in previews.indexed) ...[
              if (batch)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('${index + 1}. ${preview['name']}'),
                ),
              const SizedBox(height: 8),
              Text('提示词', style: label),
              const SizedBox(height: 4),
              SelectableText('${preview['prompt']}'),
              if (preview['negativePrompt'] case final String negative) ...[
                const SizedBox(height: 8),
                Text('负面提示词', style: label),
                const SizedBox(height: 4),
                SelectableText(negative),
              ],
              if (preview['references'] case final List references
                  when references.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('参考图', style: label),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final id in references.cast<String>())
                      ClipRRect(
                        key: Key('agent-image-reference-$id'),
                        borderRadius: theme.style.borderRadius.md,
                        child: AssetImageView(
                          assetId: id,
                          thumbnail: true,
                          width: 64,
                          height: 64,
                          fit: BoxFit.cover,
                        ),
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => answer(false),
                  child: const Text('取消'),
                ),
                FButton(
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => answer(true),
                  child: const Text('确认生成'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(tasksProvider(widget.branchId)).value ?? [];
    final pending =
        ref.watch(pendingReviewCountProvider(widget.branchId)).value ?? 0;
    final running = tasks.where((t) => t.isActive).length;
    final conversationTasks = tasks.where(
      (t) =>
          t.kind == TaskKind.agent &&
          t.input['conversationId'] == _conversation,
    );
    final queued = conversationTasks
        .where((t) => t.status == TaskStatus.queued)
        .toList()
        .reversed
        .toList();
    final currentTask =
        conversationTasks
            .where((t) => t.status == TaskStatus.running)
            .firstOrNull ??
        queued.firstOrNull ??
        conversationTasks.firstOrNull;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _chat(
            currentTask,
            queued: queued,
            pending: pending,
            running: running,
          ),
        ),
      ),
    );
  }

  /// A small outlined action with an icon, optionally explained by a hover
  /// tooltip: the chips above the conversation.
  Widget _chip({
    Key? key,
    String? tooltip,
    required IconData icon,
    required Widget label,
    required VoidCallback? onPress,
  }) {
    final button = FButton(
      key: key,
      variant: FButtonVariant.outline,
      size: FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.min,
      onPress: onPress,
      prefix: Icon(icon),
      child: label,
    );
    if (tooltip == null) return button;
    return FTooltip(tipBuilder: (_, _) => Text(tooltip), child: button);
  }

  Widget _skillsChip() {
    final on = (ref.watch(skillsProvider).value ?? const [])
        .where((e) => e.enabled)
        .length;
    return _chip(
      key: const Key('agent-skills'),
      tooltip: '管理助手技能；对话开头输入 / 可直接启用',
      icon: FLucideIcons.puzzle,
      label: Flexible(child: Text('技能 · $on', overflow: TextOverflow.ellipsis)),
      onPress: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SkillsScreen()),
      ),
    );
  }

  /// One-tap requests above the input. Writing actions fill in a message about the
  /// chapter beside the chat, else the chapter at the assistant's position, for
  /// the author to finish or send. The assistant may only write the last
  /// chapter it can see, so continuing or revising another chapter, or asking
  /// about one beyond its position, first moves the position there. Ending
  /// ideas and image batches also stop there so later events cannot shape them.
  Widget _quickActions(StorySnapshot? story) {
    final chapters = story?.chapters ?? const <Chapter>[];
    final limit = _chapter == null
        ? chapters.length - 1
        : chapters.indexWhere((s) => s.id == _chapter);
    final focus = chapters.indexWhere((s) => s.id == widget.focusChapterId);
    final at = focus >= 0 ? focus : limit;
    final target = at >= 0 ? chapters[at] : null;
    final name = target == null
        ? '当前故事'
        : '「${target.title.isEmpty ? '当前章节' : target.title}」';
    void fill(String text, {bool edit = false}) {
      if (target != null && (edit ? at != limit : at > limit)) {
        _moveTo(at == chapters.length - 1 ? null : target.id);
      }
      setState(() {
        _input.text = text;
        _input.selection = TextSelection.collapsed(offset: text.length);
      });
      _inputFocus.requestFocus();
    }

    final imageConnection = ref.watch(roleConnectionProvider('image')).value;
    final actions = [
      if (target != null && imageConnection != null)
        (
          FLucideIcons.images,
          '本章亮点生图',
          '提取本章亮点，一次确认后逐张生成插图',
          () {
            if (at != limit) {
              _moveTo(at == chapters.length - 1 ? null : target.id);
            }
            _send(
              AgentRequest(
                '提取$name的 3 个不同视觉亮点，每个亮点写成一段生图提示词；内容不足时可减少。'
                '一次提交全部提示词，等我统一确认后逐张生成插图。',
                chapterId: target.id,
                illustrationBatch: true,
              ),
            );
          },
        ),
      (
        FLucideIcons.penLine,
        '续写',
        '按当前情节续写，接在正文末尾',
        () => fill('续写$name：沿当前情节自然推进，写一段追加正文。', edit: true),
      ),
      (
        FLucideIcons.pencil,
        '修改',
        '说明怎么改，助手改写正文',
        () => fill('修改$name：', edit: true),
      ),
      (
        FLucideIcons.fileText,
        '总结',
        '总结情节、人物变化与悬念',
        () => fill('总结$name的主要情节、人物变化和留下的悬念。'),
      ),
      (FLucideIcons.search, '查找', '在正文里查找人物、物品或台词', () => fill('在正文中查找：')),
      (
        FLucideIcons.listTree,
        '归纳',
        '把人物、设定与伏笔整理成资料建议',
        () => fill('归纳目前为止出场的人物、地点、设定和伏笔，整理成资料建议。'),
      ),
      (FLucideIcons.notebookPen, '生成正文', '为参考位置的章节生成正文', _generate),
      (
        FLucideIcons.flag,
        '推演结局',
        '讨论三个可能的结局，保留当前正文',
        () => fill(
          '根据截至$name的故事，推演三个不同的结局，说明人物选择、伏笔回收和最终结果。'
          '这些只是创作方案，不要修改正文或资料。',
          edit: true,
        ),
      ),
    ];
    return SingleChildScrollView(
      key: const Key('agent-quick-actions'),
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (icon, label, tooltip, onPress) in actions)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _chip(
                key: Key('agent-quick-$label'),
                tooltip: tooltip,
                icon: icon,
                label: Text(label),
                onPress: onPress,
              ),
            ),
        ],
      ),
    );
  }

  /// `/` at the start of the message suggests skills to start explicitly.
  Widget _skillSuggestions() {
    final text = _input.text;
    final match = RegExp(r'^/([a-z0-9-]*)$').firstMatch(text);
    if (match == null) return const SizedBox.shrink();
    final skills = [
      for (final e in ref.watch(skillsProvider).value ?? const [])
        if (e.enabled && e.skill.name.startsWith(match.group(1)!)) e.skill,
    ];
    if (skills.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final s in skills)
              _chip(
                key: Key('skill-suggestion-${s.name}'),
                icon: FLucideIcons.puzzle,
                label: Flexible(
                  child: Text(
                    '/${s.name} · ${s.title}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onPress: () => setState(() {
                  _input.text = '/${s.name} ';
                  _input.selection = TextSelection.collapsed(
                    offset: _input.text.length,
                  );
                }),
              ),
          ],
        ),
      ),
    );
  }

  /// Which ST preset shapes this chat, and the way into the preset panel.
  Widget _presetChip() {
    final setting = ref
        .watch(settingProvider('writing/${widget.branchId}'))
        .value;
    final id = setting?['presetId'];
    final name = (ref.watch(resourcesProvider).value ?? const [])
        .where((r) => r.id == id)
        .firstOrNull
        ?.name;
    final off = setting?[assistantUsesPresetKey] == false;
    final customized =
        (setting?['presetOverrides'] as Map?)?.containsKey(id) == true;
    return _chip(
      key: const Key('agent-preset'),
      tooltip:
          'ST 预设${customized ? ' · 已自定义' : ''}${off ? '（未用于对话）' : ''}，点击选择与编辑',
      icon: FLucideIcons.slidersHorizontal,
      label: Flexible(
        child: Text(name ?? '未选择预设', overflow: TextOverflow.ellipsis),
      ),
      onPress: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PresetScreen(branchId: widget.branchId),
        ),
      ),
    );
  }

  Widget _modelBanner() {
    final connections = ref.watch(connectionsProvider).value;
    if (connections == null ||
        connections.any((c) => connectionServes(c, 'editor'))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FAlert(
        icon: const Icon(FLucideIcons.info),
        title: Text(
          connections.isEmpty
              ? '还没有配置模型连接，助手暂时无法回复。'
              : '对话助手需要 OpenAI 兼容连接或本地订阅（Claude Code / Codex）；远程执行器只能用于正文生成。',
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FButton(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: _openSettings,
              child: const Text('去配置'),
            ),
          ),
        ),
      ),
    );
  }

  /// Opens a list the conversation keeps out of the way: candidates or
  /// tasks, built by [body] so it follows changes while open.
  void _openList(String title, Widget Function(WidgetRef ref) body) =>
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PageScaffold(
            title: title,
            body: Consumer(builder: (_, ref, _) => body(ref)),
          ),
        ),
      );

  Widget _chat(
    GenerationTask? task, {
    required List<GenerationTask> queued,
    required int pending,
    required int running,
  }) {
    final active = task?.isActive == true ? task : null;
    final story = ref.watch(storyProvider(widget.branchId)).value;
    final chapter = story?.chapters.where((s) => s.id == _chapter).firstOrNull;
    final colors = context.theme.colors;
    return LayoutBuilder(
      builder: (_, bounds) => Column(
        children: [
          // On a short screen or with large text, the controls above the
          // conversation scroll within part of the height so the messages
          // and the input always keep their place.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: bounds.maxHeight * .4),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _modelBanner(),
                  // Context on one line: the position and the skills are
                  // capped, the preset name takes the rest, all truncate.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: (bounds.maxWidth - 32) * .35,
                          ),
                          child: _chip(
                            key: const Key('agent-position'),
                            tooltip: '参考范围：助手只读取截至此处的正文与资料',
                            icon: FLucideIcons.mapPin,
                            label: Flexible(
                              child: Text(
                                _chapter == null
                                    ? '分支末尾'
                                    : '截至「${chapter == null || chapter.title.isEmpty ? '当前章节' : chapter.title}」',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            onPress: _choosePosition,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(child: _presetChip()),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: (bounds.maxWidth - 32) * .3,
                          ),
                          child: _skillsChip(),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
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
                                    (c) => c['through_chapter_id'] == _chapter,
                                  )
                                  .toList();
                              if (all.isEmpty) return const SizedBox.shrink();
                              String label(int i) =>
                                  '${all[i]['title']} · ${all.length - i}';
                              return FSelect<String>.rich(
                                hint: '选择会话',
                                control: FSelectControl<String>.lifted(
                                  value:
                                      all.any((c) => c['id'] == _conversation)
                                      ? _conversation
                                      : null,
                                  onChange: (v) =>
                                      setState(() => _conversation = v),
                                ),
                                format: (id) {
                                  final i = all.indexWhere(
                                    (c) => c['id'] == id,
                                  );
                                  return i < 0 ? '' : label(i);
                                },
                                children: [
                                  for (final (i, c) in all.indexed)
                                    FSelectItem<String>(
                                      title: Text(
                                        label(i),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      value: c['id'] as String,
                                    ),
                                ],
                              );
                            },
                          ),
                        ),
                        IconAction(
                          icon: FLucideIcons.messageSquarePlus,
                          tooltip: '新建编辑会话',
                          onPress: _newConversation,
                        ),
                        IconAction(
                          icon: FLucideIcons.trash2,
                          tooltip: '删除当前会话',
                          onPress: _conversation == null ? null : _delete,
                        ),
                        MenuAction(
                          tooltip: '任务',
                          entries: [
                            if (pending > 0)
                              menuEntry(
                                '未写入 · $pending',
                                () => _openList('未写入的正文', _proposals),
                                icon: FLucideIcons.gitCompareArrows,
                              ),
                            menuEntry(
                              running > 0 ? '任务 · $running' : '任务',
                              () => _openList('任务', _history),
                              icon: FLucideIcons.listChecks,
                            ),
                          ],
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
                        style: TextStyle(color: colors.error),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _conversation == null
                ? ListView(children: [_starter()])
                : AsyncView(
                    value: ref.watch(messagesProvider(_conversation!)),
                    // Reversed so it opens at the latest message and stays
                    // there as a reply streams in; aligned to the top while
                    // short, like an unreversed list.
                    builder: (messages) {
                      final unsent = task?.input['agentMessage'] as String?;
                      final last = messages
                          .where((m) => m.role == 'user')
                          .lastOrNull;
                      // Asks the last turn again once nothing is answering it.
                      final regenerate =
                          last == null || active != null || _sending
                          ? null
                          : () => _send(_replacing(last, last.content));
                      return Align(
                        alignment: Alignment.topCenter,
                        child: ListView(
                          reverse: true,
                          // ponytail: lays out every message, fine for chat-sized
                          // threads; switch to a builder if threads get huge.
                          shrinkWrap: true,
                          padding: const EdgeInsets.all(20),
                          children: [
                            if (active?.result['imageConfirmation']
                                case final Map<String, dynamic> pending)
                              _imageConfirmation(active!, pending)
                            else if (task != null &&
                                task.status != TaskStatus.completed)
                              FCard(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (task.isActive)
                                        const FProgress()
                                      else
                                        Text(
                                          '编辑回复${taskStatusLabels[task.status]}',
                                          style: TextStyle(color: colors.error),
                                        ),
                                      if (task.error.isNotEmpty) ...[
                                        const SizedBox(height: 8),
                                        SelectableText(task.error),
                                      ],
                                      if (!task.isActive && unsent != null)
                                        SelectableText('待发送：$unsent'),
                                      if (task.isActive ||
                                          task.partialText.isNotEmpty) ...[
                                        const SizedBox(height: 12),
                                        task.partialText.isEmpty
                                            ? const SelectableText('编辑助手正在工作…')
                                            : _markdown(task.partialText),
                                      ],
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          FButton(
                                            variant: FButtonVariant.ghost,
                                            size: FButtonSizeVariant.sm,
                                            mainAxisSize: MainAxisSize.min,
                                            onPress: () => Navigator.push(
                                              context,
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    TaskScreen(taskId: task.id),
                                              ),
                                            ),
                                            child: const Text('查看工具与任务'),
                                          ),
                                          if (!task.isActive &&
                                              (unsent != null ||
                                                  regenerate != null))
                                            FButton(
                                              variant: FButtonVariant.ghost,
                                              size: FButtonSizeVariant.sm,
                                              mainAxisSize: MainAxisSize.min,
                                              onPress: _sending
                                                  ? null
                                                  : unsent == null
                                                  ? regenerate
                                                  : () => _retryQueued(task),
                                              prefix: const Icon(
                                                FLucideIcons.refreshCw,
                                              ),
                                              child: const Text('重试'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            for (final message in messages.reversed)
                              _message(
                                message,
                                regenerate: message == messages.last
                                    ? regenerate
                                    : null,
                                idle: active == null && !_sending,
                              ),
                            if (messages.isEmpty) _starter(),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                if (queued.isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: bounds.maxHeight * .18,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          for (var i = 0; i < queued.length; i++)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '排队 ${i + 1} · ${queued[i].input['agentMessage'] ?? '助手消息'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.theme.typography.body.sm,
                                  ),
                                ),
                                IconAction(
                                  key: ValueKey(
                                    'cancel-queued-${queued[i].id}',
                                  ),
                                  icon: FLucideIcons.x,
                                  tooltip: '取消排队消息',
                                  onPress: () async {
                                    try {
                                      await ref
                                          .read(servicesProvider)
                                          .runner
                                          .cancel(queued[i].id);
                                    } catch (e) {
                                      if (mounted) showError(context, e);
                                    }
                                  },
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                _quickActions(story),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: bounds.maxHeight * .2),
                  child: SingleChildScrollView(child: _skillSuggestions()),
                ),
                if (_editing?.conversationId == _conversation &&
                    _editing != null)
                  Row(
                    children: [
                      Icon(
                        FLucideIcons.pencil,
                        size: 14,
                        color: colors.mutedForeground,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '修改消息：发送后，这条消息之后的对话会被替换',
                          style: context.theme.typography.body.xs.copyWith(
                            color: colors.mutedForeground,
                          ),
                        ),
                      ),
                      IconAction(
                        icon: FLucideIcons.x,
                        tooltip: '取消修改',
                        size: 14,
                        onPress: () => setState(() {
                          _editing = null;
                          _input.clear();
                        }),
                      ),
                    ],
                  ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Focus(
                        canRequestFocus: false,
                        onKeyEvent: (_, event) {
                          if ((event.logicalKey != LogicalKeyboardKey.enter &&
                                  event.logicalKey !=
                                      LogicalKeyboardKey.numpadEnter) ||
                              HardwareKeyboard.instance.isShiftPressed ||
                              !_input.value.composing.isCollapsed) {
                            return KeyEventResult.ignored;
                          }
                          if (event is KeyDownEvent) _send();
                          return KeyEventResult.handled;
                        },
                        child: FTextField(
                          key: const Key('agent-input'),
                          focusNode: _inputFocus,
                          control: FTextFieldControl.managed(
                            controller: _input,
                            onChange: (_) => setState(() {}),
                          ),
                          minLines: 1,
                          maxLines: 5,
                          hint: '向编辑助手描述你的想法…',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (active != null)
                      IconAction(
                        variant: FButtonVariant.primary,
                        icon: FLucideIcons.square,
                        tooltip: '停止编辑回复',
                        onPress: () async {
                          try {
                            await ref
                                .read(servicesProvider)
                                .runner
                                .cancel(active.id);
                          } catch (e) {
                            if (mounted) showError(context, e);
                          }
                        },
                      ),
                    IconAction(
                      variant: FButtonVariant.primary,
                      icon: FLucideIcons.arrowUp,
                      tooltip: active == null ? '发送给编辑助手' : '加入消息队列',
                      onPress: _sending ? null : _send,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Shown before the first message: what the assistant is for, and a few
  /// one-tap openers.
  Widget _starter() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
    child: Column(
      children: [
        Icon(
          FLucideIcons.sparkles,
          size: 40,
          color: context.theme.colors.mutedForeground,
        ),
        const SizedBox(height: 16),
        const Text('聊人物、推情节，或让助手写正文。', textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          '这里的对话会独立保存，不会进入正文。',
          textAlign: TextAlign.center,
          style: TextStyle(color: context.theme.colors.mutedForeground),
        ),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final prompt in _starterPrompts)
              FButton(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.sm,
                mainAxisSize: MainAxisSize.min,
                onPress: () => _input.text = prompt,
                child: Flexible(child: Text(prompt)),
              ),
          ],
        ),
      ],
    ),
  );

  /// Writes the chapter or story state outran, waiting for the author.
  Widget _proposals(WidgetRef ref) => AsyncView(
    value: ref.watch(proposalsProvider(widget.branchId)),
    builder: (all) {
      final proposals = [
        for (final p in all)
          if (p.status == ProposalStatus.pending) p,
      ];
      return proposals.isEmpty
          ? const Center(child: Text('没有未写入的正文。'))
          : ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: proposals.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final p = proposals[i];
                return FTile(
                  title: Text(
                    p.summary.isEmpty ? '未写入的正文' : p.summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    p.content.text,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  suffix: const Icon(FLucideIcons.gitCompareArrows),
                  onPress: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ProposalScreen(proposalId: p.id),
                    ),
                  ),
                );
              },
            );
    },
  );

  Widget _history(WidgetRef ref) => AsyncView(
    value: ref.watch(tasksProvider(widget.branchId)),
    builder: (tasks) => tasks.isEmpty
        ? const Center(child: Text('生成任务会保留输入、进度和结果。'))
        : ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: tasks.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final task = tasks[i];
              return FTile(
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
                suffix: task.isActive
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: FCircularProgress(),
                      )
                    : const Icon(FLucideIcons.chevronRight),
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => TaskScreen(taskId: task.id),
                  ),
                ),
              );
            },
          ),
  );

  /// A collapsed card whose body is revealed on demand: loaded skills and
  /// tool traffic in the conversation.
  Widget _foldedCard({
    Key? key,
    IconData? icon,
    required String title,
    String? subtitle,
    int subtitleLines = 1,
    required Widget child,
  }) {
    final theme = context.theme;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 12),
      child: FCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FAccordion(
            children: [
              FAccordionItem(
                title: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Icon(icon, size: 18),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitle,
                                maxLines: subtitleLines,
                                overflow: TextOverflow.ellipsis,
                                style: theme.typography.body.sm.copyWith(
                                  color: theme.colors.mutedForeground,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The assistant's reply as Markdown, which is what chat models write.
  Widget _markdown(String text, {bool selectable = true}) {
    final theme = context.theme;
    return MarkdownBody(
      data: text,
      selectable: selectable,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(height: 1.6, color: theme.colors.foreground),
        a: TextStyle(color: theme.colors.primary),
      ),
      onTapLink: (_, href, _) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null) launchUrl(uri);
      },
    );
  }

  /// A message's actions in a bubble at [at], like the reader's selection
  /// menu: a phone has no room to show them under every message.
  void _showActions(
    Offset at,
    List<(IconData, String, VoidCallback?)> actions,
  ) => _menu.show(
    context: context,
    contextMenuBuilder: (_) => TapRegion(
      onTapOutside: (_) => _menu.remove(),
      child: CupertinoTheme(
        data: CupertinoThemeData(brightness: context.theme.colors.brightness),
        child: CupertinoTextSelectionToolbar(
          anchorAbove: at,
          anchorBelow: at,
          children: [
            for (final (_, label, onPress) in actions)
              CupertinoTextSelectionToolbarButton.text(
                text: label,
                onPressed: onPress == null
                    ? null
                    : () {
                        _menu.remove();
                        onPress();
                      },
              ),
          ],
        ),
      ),
    ),
  );

  /// One entry of the thread. A text message offers copying it, editing it
  /// when it is the author's, and [regenerate] on the last reply; [idle] is
  /// whether a new turn may start.
  Widget _message(
    AgentMessage message, {
    VoidCallback? regenerate,
    bool idle = true,
  }) {
    final metadata = message.raw;
    if (metadata['skill'] is String) {
      // A skill loaded into this conversation, by the author or the model.
      final name = metadata['skill'] as String;
      final title =
          (ref.watch(skillsProvider).value ?? const [])
              .where((e) => e.skill.name == name)
              .firstOrNull
              ?.skill
              .title ??
          name;
      return _foldedCard(
        key: Key('skill-message-$name'),
        icon: FLucideIcons.puzzle,
        title: message.role == 'system' ? '你启用了技能：$title' : '助手加载了技能：$title',
        subtitle: '本会话之后的回复都会遵循它',
        child: SelectableText(message.content),
      );
    }
    if (message.role == 'system') return const SizedBox.shrink();
    if (metadata['tool_name'] == 'generate_image' ||
        metadata['tool_name'] == 'generate_images') {
      final result = jsonDecode(message.content);
      if (result case {'cancelled': true}) {
        return _foldedCard(
          icon: FLucideIcons.imageOff,
          title: '已取消生图',
          subtitle: '未调用生图引擎',
          child: SelectableText(message.content),
        );
      }
      final ids = <String>[
        if (result case {'assetId': final String id}) id,
        if (result case {'images': final List images})
          for (final image in images)
            if (image case {'assetId': final String id}) id,
      ];
      if (ids.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final id in ids)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    key: Key('agent-image-$id'),
                    onTap: () => showIllustrationDetail(
                      context,
                      assetId: id,
                      branchId: widget.branchId,
                    ),
                    child: ClipRRect(
                      borderRadius: context.theme.style.borderRadius.lg,
                      child: Stack(
                        children: [
                          AssetImageView(assetId: id, height: 280),
                          Positioned(
                            left: 8,
                            bottom: 8,
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.theme.colors.background
                                    .withValues(alpha: .9),
                                borderRadius:
                                    context.theme.style.borderRadius.md,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (metadata['tool_name'] == 'generate_image')
                                    IconAction(
                                      icon: FLucideIcons.filePlus,
                                      tooltip: '插入正文',
                                      onPress: _insertingImages.contains(id)
                                          ? null
                                          : () => _insertImage(id, message),
                                    ),
                                  IconAction(
                                    icon: FLucideIcons.download,
                                    tooltip: '下载到本地',
                                    onPress: () =>
                                        exportIllustration(context, ref, id),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      }
    }
    if (message.role == 'tool' || metadata['tool_calls'] != null) {
      return _foldedCard(
        title: message.role == 'tool' ? '工具结果' : '工具调用',
        subtitle: message.content.isEmpty ? null : message.content,
        subtitleLines: 2,
        child: SelectableText(
          message.role == 'tool'
              ? message.content
              : const JsonEncoder.withIndent('  ').convert(metadata),
        ),
      );
    }
    final theme = context.theme;
    final mine = message.role == 'user';
    final actions = <(IconData, String, VoidCallback?)>[
      (
        FLucideIcons.copy,
        '复制',
        () {
          Clipboard.setData(ClipboardData(text: message.content));
          toast(context, '已复制');
        },
      ),
      if (mine) (FLucideIcons.pencil, '修改', idle ? () => _edit(message) : null),
      if (!mine && regenerate != null)
        (FLucideIcons.refreshCw, '重新生成', regenerate),
    ];
    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 760),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: mine ? theme.colors.secondary : theme.colors.muted,
        borderRadius: theme.style.borderRadius.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            mine ? '你' : '编辑助手',
            style: theme.typography.body.xs.copyWith(
              color: theme.colors.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          // On a phone a long press brings up the actions, not a selection.
          if (mine)
            (touchPlatform ? Text.new : SelectableText.new)(
              message.content,
              style: TextStyle(
                height: 1.6,
                color: theme.colors.secondaryForeground,
              ),
            )
          else
            _markdown(message.content, selectable: !touchPlatform),
          if (metadata['attachment'] case {'title': final String title})
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FLucideIcons.paperclip,
                    size: 14,
                    color: theme.colors.mutedForeground,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '附：${title.isEmpty ? '未命名章节' : title}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.typography.body.xs.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: EdgeInsets.only(
        left: mine ? 32 : 0,
        right: mine ? 0 : 32,
        bottom: 16,
      ),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: touchPlatform
            ? GestureDetector(
                onLongPressStart: (d) =>
                    _showActions(d.globalPosition, actions),
                child: bubble,
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: mine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  bubble,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (icon, label, onPress) in actions)
                        IconAction(
                          icon: icon,
                          tooltip: label,
                          size: 14,
                          onPress: onPress,
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// The image engine as the author set it up: the connection, the ComfyUI
/// workflow file ([workflow] when a run used another), and the model only
/// when it is actually sent.
String imageEngineLabel(ModelConnection connection, {String? workflow}) {
  final file = workflow ?? connection.comfyWorkflow?.filename ?? '';
  return [
    connection.name,
    if (file.isNotEmpty) file,
    ?connection.sentModel,
  ].join(' · ');
}

/// Starts the sidecar on the chapter the assistant wrote in [task] once the
/// round ends, as a chapter written from the reader starts it.
Future<void> _sidecarAfterRound(
  AppServices services,
  GenerationTask task,
) async {
  final done = await services.runner.wait(task.id);
  final id = done.input['editChapterId'], repo = services.repository;
  if (id is! String) return;
  final chapter = await repo.getChapter(branchId: done.branchId, chapterId: id);
  final sources = done.input['sourceRevisions'] as List? ?? const [];
  if (sources.any((s) => s['revisionId'] == chapter.revisionId) ||
      (await repo.getRevision(chapter.revisionId)).sourceProposalId == null) {
    return;
  }
  startSidecarQuietly(services, branchId: done.branchId, chapterId: id);
}
