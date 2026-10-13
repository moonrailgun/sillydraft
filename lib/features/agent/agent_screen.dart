import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
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

/// The editing assistant for one story branch: conversation, manuscript
/// candidates awaiting review, and the task history, in one place. It is a
/// section of the novel workspace and sits beside the editor.
class AgentPanel extends ConsumerStatefulWidget {
  const AgentPanel({
    super.key,
    required this.branchId,
    this.chapterId,
    this.focusChapterId,
  });
  final String branchId;

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
  bool _sending = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _selectConversation();
  }

  @override
  void didUpdateWidget(AgentPanel old) {
    super.didUpdateWidget(old);
    if (old.chapterId != widget.chapterId) _moveTo(widget.chapterId);
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _moveTo(String? chapter) {
    setState(() {
      _chapter = chapter;
      _conversation = null;
    });
    _selectConversation();
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

  Future<void> _send() async {
    final text = _input.text;
    if (_sending || text.trim().isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final services = ref.read(servicesProvider),
          connection = await services.connectionFor('editor');
      if (connection == null) throw const FormatException('请先在模型设置里配置编辑助手连接。');
      final conversation = await _ensureConversation();
      if (mounted) setState(() {});
      final profile = await WritingContext.load(services, widget.branchId);
      await services.editor.send(
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
    final confirm = await confirmAction(
      context,
      title: '删除这段编辑会话？',
      message: '会话消息将删除，运行任务会先停止。正文、候选和资料会保留；任务记录中的输入快照也会保留。',
      confirmLabel: '删除会话',
      destructive: true,
    );
    if (!confirm || !mounted) return;
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
        await _selectConversation();
      }
    } catch (e) {
      if (mounted) showError(context, e);
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
    final currentTask =
        conversationTasks.where((t) => t.isActive).firstOrNull ??
        conversationTasks.firstOrNull;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: FTabs(
            expands: true,
            children: [
              FTabEntry(label: const Text('对话'), child: _chat(currentTask)),
              FTabEntry(
                label: Text(pending > 0 ? '候选 · $pending' : '候选'),
                child: _proposals(),
              ),
              FTabEntry(
                label: Text(running > 0 ? '任务 · $running' : '任务'),
                child: _history(),
              ),
            ],
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
      label: Text('技能 · $on'),
      onPress: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SkillsScreen()),
      ),
    );
  }

  /// One-tap requests above the input. Each fills in a message about the
  /// chapter beside the chat, else the chapter at the assistant's position, for
  /// the author to finish or send. The assistant may only write the last
  /// chapter it can see, so continuing or revising another chapter, or asking
  /// about one beyond its position, first moves the position there.
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

    final actions = [
      (
        FLucideIcons.penLine,
        '续写',
        '按当前情节续写，生成追加正文候选',
        () => fill('续写$name：沿当前情节自然推进，生成一段追加正文候选。', edit: true),
      ),
      (
        FLucideIcons.pencil,
        '修改',
        '说明怎么改，助手提出改写候选',
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
      tooltip: '选择与编辑 ST 预设',
      icon: FLucideIcons.slidersHorizontal,
      label: Flexible(
        child: Text(
          name == null
              ? '预设：未选择'
              : off
              ? '预设：$name${customized ? ' · 已自定义' : ''}（未用于对话）'
              : '预设：$name${customized ? ' · 已自定义' : ''}',
          overflow: TextOverflow.ellipsis,
        ),
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

  Widget _chat(GenerationTask? task) {
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              _chip(
                                key: const Key('agent-position'),
                                tooltip: '助手只读取截至此处的正文与资料',
                                icon: FLucideIcons.mapPin,
                                label: Flexible(
                                  child: Text(
                                    _chapter == null
                                        ? '参考范围：分支末尾'
                                        : '参考范围：截至「${chapter == null || chapter.title.isEmpty ? '当前章节' : chapter.title}」',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                onPress: _choosePosition,
                              ),
                              _presetChip(),
                              _skillsChip(),
                              _chip(
                                tooltip: '为参考位置的章节生成正文候选',
                                icon: FLucideIcons.notebookPen,
                                label: const Text('生成正文'),
                                onPress: _generate,
                              ),
                            ],
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
                      ],
                    ),
                  ),
                  AsyncView(
                    value: ref.watch(conversationsProvider(widget.branchId)),
                    builder: (conversations) {
                      final all = conversations
                          .where((c) => c['through_chapter_id'] == _chapter)
                          .toList();
                      if (all.length < 2) return const SizedBox.shrink();
                      String label(int i) =>
                          '${all[i]['title']} · ${all.length - i}';
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: FSelect<String>.rich(
                          hint: '选择会话',
                          control: FSelectControl<String>.lifted(
                            value: all.any((c) => c['id'] == _conversation)
                                ? _conversation
                                : null,
                            onChange: (v) => setState(() => _conversation = v),
                          ),
                          format: (id) {
                            final i = all.indexWhere((c) => c['id'] == id);
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
                        ),
                      );
                    },
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
                    builder: (messages) => Align(
                      alignment: Alignment.topCenter,
                      child: ListView(
                        reverse: true,
                        // ponytail: lays out every message, fine for chat-sized
                        // threads; switch to a builder if threads get huge.
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(20),
                        children: [
                          if (task != null &&
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
                                    if (task.isActive ||
                                        task.partialText.isNotEmpty) ...[
                                      const SizedBox(height: 12),
                                      SelectableText(
                                        task.partialText.isEmpty
                                            ? '编辑助手正在工作…'
                                            : task.partialText,
                                      ),
                                    ],
                                    const SizedBox(height: 8),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: FButton(
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
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          for (final message in messages.reversed)
                            _message(message),
                          if (messages.isEmpty) _starter(),
                        ],
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              children: [
                _quickActions(story),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: bounds.maxHeight * .2),
                  child: SingleChildScrollView(child: _skillSuggestions()),
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
                          if (event is KeyDownEvent && active == null) _send();
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
                      )
                    else
                      IconAction(
                        variant: FButtonVariant.primary,
                        icon: FLucideIcons.arrowUp,
                        tooltip: '发送给编辑助手',
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
        const Text('聊人物、推情节，或让助手生成正文候选。', textAlign: TextAlign.center),
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

  Widget _proposals() => AsyncView(
    value: ref.watch(proposalsProvider(widget.branchId)),
    builder: (proposals) => proposals.isEmpty
        ? Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('生成的正文会先放在这里，等你审阅。', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: _generate,
                    child: const Text('生成正文候选'),
                  ),
                ],
              ),
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: proposals.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Align(
                  alignment: Alignment.centerRight,
                  child: FButton(
                    variant: FButtonVariant.secondary,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _generate,
                    prefix: const Icon(FLucideIcons.notebookPen),
                    child: const Text('生成正文候选'),
                  ),
                );
              }
              final p = proposals[i - 1];
              return FTile(
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
                suffix: const Icon(FLucideIcons.gitCompareArrows),
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ProposalScreen(proposalId: p.id),
                  ),
                ),
              );
            },
          ),
  );

  Widget _history() => AsyncView(
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

  Widget _message(AgentMessage message) {
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
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760),
        margin: const EdgeInsets.only(bottom: 16),
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
            SelectableText(
              message.content,
              style: TextStyle(
                height: 1.6,
                color: mine
                    ? theme.colors.secondaryForeground
                    : theme.colors.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
