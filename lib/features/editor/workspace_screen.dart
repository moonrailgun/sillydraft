import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../bookshelf/novel_dialog.dart';
import '../reader/reader_screen.dart';
import 'editor_screen.dart';
import 'resizable_workspace.dart';
import '../agent/agent_providers.dart';
import '../agent/agent_screen.dart';
import '../lore/lore_screen.dart';
import '../branches/branch_screen.dart';
import '../illustrations/illustration_gallery.dart';
import '../presets/preset_screen.dart';
import '../resources/writing_profile.dart';
import '../transfer/transfer_screen.dart';

final novelProvider = FutureProvider.family<Novel, String>((ref, id) {
  ref.watch(repositoryContentChangesProvider);
  return ref.watch(repositoryProvider).getNovel(id);
});

/// The parts of a novel workspace, in navigation order.
enum WorkspaceSection {
  manuscript(FLucideIcons.listTree, '正文'),
  lore(FLucideIcons.package, '资料'),
  agent(FLucideIcons.sparkles, '助手'),
  gallery(FLucideIcons.images, '插图');

  const WorkspaceSection(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// The sections a wide workspace offers as tools beside the page.
const _tools = [
  WorkspaceSection.agent,
  WorkspaceSection.lore,
  WorkspaceSection.gallery,
];

/// Everything about one novel: its manuscript, lore, assistant and images are
/// sections of this page. The branch being written is shown under the title
/// and picked from there, because it decides what every section shows.
///
/// On a phone the sections take turns. A wide screen is laid out as
/// outline | page | tools: the outline on the left, the chapter being read
/// always in the middle, and the assistant, lore or images on the right.
/// Either side folds away and stays as the author left it.
class NovelWorkspace extends ConsumerStatefulWidget {
  const NovelWorkspace({super.key, required this.novelId});
  final String novelId;
  @override
  ConsumerState<NovelWorkspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<NovelWorkspace> {
  String? _selected;
  var _section = WorkspaceSection.manuscript;

  /// The tool on the right of a wide screen: the assistant until another is
  /// picked.
  var _tool = WorkspaceSection.agent;

  /// Whether the side panes of a wide screen are open; null until changed
  /// here, which keeps the stored choice.
  bool? _toolsOpen, _outlineOpen;

  /// The latest request for the assistant from the reader.
  AgentRequest? _agentRequest;

  // Sections are built on first visit and then kept alive, so a half-typed
  // message or a scroll position survives switching and nothing runs early.
  late final _visited = {_section};
  void _go(WorkspaceSection section) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _section = section;
      _visited.add(section);
      if (section != WorkspaceSection.manuscript) _tool = section;
    });
    if (section != WorkspaceSection.manuscript) _panes(tools: true);
  }

  ({bool tools, bool outline}) get _open {
    final saved = ref.watch(settingProvider('workspacePanes')).value;
    return (
      tools: _toolsOpen ?? saved?['tools'] as bool? ?? true,
      outline: _outlineOpen ?? saved?['outline'] as bool? ?? true,
    );
  }

  /// Opens or folds the side panes and remembers the choice.
  void _panes({bool? tools, bool? outline}) {
    final open = _open;
    if ((tools ?? open.tools) == open.tools &&
        (outline ?? open.outline) == open.outline) {
      return;
    }
    setState(() {
      _toolsOpen = tools ?? open.tools;
      _outlineOpen = outline ?? open.outline;
    });
    unawaited(
      ref
          .read(repositoryProvider)
          .setSetting('workspacePanes', {
            'tools': _toolsOpen,
            'outline': _outlineOpen,
          })
          .catchError((Object e) {
            if (mounted) showError(context, e);
          }),
    );
  }

  /// A tool picked on the rail: opens it, or folds the pane when it is the
  /// one already showing.
  void _pickTool(WorkspaceSection tool) {
    if (tool == _tool && _open.tools) {
      _panes(tools: false);
    } else {
      _go(tool);
    }
  }

  Future<void> _push(Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

  void _edit(Chapter chapter) => _push(EditorScreen(chapter: chapter));

  /// Hands a selection to the assistant, which draws it with its image tool.
  /// A reader opened on top of the workspace closes so the reply is in view.
  void _illustrate(Chapter chapter, String selection, int? endOffset) {
    final here = ModalRoute.of(context);
    Navigator.popUntil(context, (route) => route == here);
    setState(
      () => _agentRequest = AgentRequest(
        '为这段正文生成一张插图：\n\n${selection.trim()}',
        chapterId: chapter.id,
        illustrationAnchor: endOffset == null
            ? null
            : {
                'chapterId': chapter.id,
                'revisionId': chapter.revisionId,
                'endOffset': endOffset,
              },
      ),
    );
    _go(WorkspaceSection.agent);
  }

  Future<void> _addChapter(StorySnapshot story) async {
    // The number comes from the order; only the name is asked for.
    final name = await askText(
      context,
      title: '新增章节',
      label: '章节名（可留空）',
      allowEmpty: true,
    );
    if (name == null || !mounted) return;
    try {
      final chapter = await ref
          .read(repositoryProvider)
          .createChapter(branchId: story.branch.id, name: name);
      if (mounted) {
        setState(() => _selected = chapter.id);
        _edit(chapter);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AsyncView(
    value: ref.watch(novelProvider(widget.novelId)),
    builder: (novel) => AsyncView(
      value: ref.watch(storyProvider(novel.activeBranchId)),
      builder: _buildStory,
    ),
  );

  Widget _buildStory(StorySnapshot story) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final selected =
        story.chapters.where((s) => s.id == _selected).firstOrNull ??
        story.chapters.firstOrNull;
    final pending =
        ref.watch(pendingReviewCountProvider(story.branch.id)).value ?? 0;
    final destinations = <NavDestination>[
      for (final s in WorkspaceSection.values)
        (
          icon: s.icon,
          label: s.label,
          badge: s == WorkspaceSection.agent ? pending : 0,
        ),
    ];
    final branchKey = story.branch.id;
    Widget page(WorkspaceSection section) => switch (section) {
      // A plain SafeArea rather than a nested scaffold: the workspace's
      // scaffold already makes room for the keyboard.
      WorkspaceSection.manuscript => SafeArea(
        top: false,
        child: _outline(story, selected, wide),
      ),
      WorkspaceSection.lore => LoreScreen(
        key: ValueKey('lore:$branchKey'),
        branchId: branchKey,
        embedded: true,
      ),
      WorkspaceSection.agent => AgentPanel(
        key: ValueKey('agent:$branchKey'),
        branchId: branchKey,
        focusChapterId: wide ? selected?.id : null,
        request: _agentRequest,
      ),
      WorkspaceSection.gallery => IllustrationGallery(
        key: ValueKey('gallery:$branchKey'),
        branchId: branchKey,
        embedded: true,
      ),
    };
    final theme = context.theme;
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    final open = _open;
    if (wide && open.tools) _visited.add(_tool);
    // One floating button per section: only the visible section may take
    // part in route hero animations.
    Widget kept(WorkspaceSection s, bool visible) => _visited.contains(s)
        ? TickerMode(
            enabled: visible,
            child: HeroMode(enabled: visible, child: page(s)),
          )
        : const SizedBox.shrink();
    return PopScope(
      // Side by side there is no section to step out of first.
      canPop: wide || _section == WorkspaceSection.manuscript,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(WorkspaceSection.manuscript);
      },
      child: AppScaffold(
        header: FHeader.nested(
          // Like an app bar title: legible at large text, never huge.
          title: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.34,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  story.novel.title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 2),
                FTooltip(
                  tipBuilder: (_, _) => const Text('故事分支'),
                  child: FTappable(
                    key: const Key('workspace-branch'),
                    semanticsLabel: '故事分支：${story.branch.name}',
                    onPress: () => _push(BranchScreen(novelId: story.novel.id)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            FLucideIcons.gitBranch,
                            size: 13,
                            color: theme.colors.mutedForeground,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              story.branch.name,
                              overflow: TextOverflow.ellipsis,
                              style: theme.typography.body.xs.copyWith(
                                color: theme.colors.mutedForeground,
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            FLucideIcons.chevronDown,
                            size: 14,
                            color: theme.colors.mutedForeground,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Each pane's toggle sits above it, at its own edge: the outline's
          // on the left, the tools' on the right. The divider is solid while
          // the pane shows and dashed once it folds.
          prefixes: [
            if (canPop) const AppBackButton(),
            if (wide)
              HeaderIconAction(
                key: const Key('workspace-outline-toggle'),
                icon: open.outline
                    ? FLucideIcons.panelLeft
                    : FLucideIcons.panelLeftDashed,
                tooltip: open.outline ? '收起目录' : '显示目录',
                onPress: () => _panes(outline: !open.outline),
              ),
          ],
          suffixes: [
            HeaderIconAction(
              key: const Key('open-reader'),
              icon: FLucideIcons.bookOpen,
              tooltip: '阅读',
              onPress: () => _push(
                ReaderScreen(
                  branchId: branchKey,
                  onEdit: _edit,
                  onIllustrate: _illustrate,
                ),
              ),
            ),
            MenuAction(
              header: true,
              tooltip: '作品操作',
              entries: [
                menuEntry(
                  '作品信息',
                  () => showNovelDialog(context, novel: story.novel),
                  icon: FLucideIcons.info,
                ),
                menuEntry(
                  '预设',
                  () => _push(PresetScreen(branchId: branchKey)),
                  icon: FLucideIcons.slidersHorizontal,
                ),
                menuEntry(
                  '角色卡与世界书',
                  () => _push(WritingProfileScreen(branchId: branchKey)),
                  icon: FLucideIcons.bookUser,
                ),
                menuEntry(
                  '故事分支',
                  () => _push(BranchScreen(novelId: story.novel.id)),
                  icon: FLucideIcons.gitBranch,
                ),
                menuEntry(
                  '导出、备份与同步',
                  () => _push(TransferScreen(novelId: story.novel.id)),
                  icon: FLucideIcons.share2,
                ),
              ],
            ),
            if (wide)
              HeaderIconAction(
                key: const Key('workspace-tools-toggle'),
                icon: open.tools
                    ? FLucideIcons.panelRight
                    : FLucideIcons.panelRightDashed,
                tooltip: '${open.tools ? '收起' : '显示'}${_tool.label}',
                onPress: () => _panes(tools: !open.tools),
              ),
          ],
        ),
        footer: wide
            ? null
            : AppBottomBar(
                key: const Key('workspace-sections'),
                selectedIndex: _section.index,
                onSelect: (i) => _go(WorkspaceSection.values[i]),
                destinations: destinations,
              ),
        child: wide
            ? Row(
                children: [
                  Expanded(
                    // A plain SafeArea rather than a nested scaffold: the
                    // workspace's scaffold already makes room for the
                    // keyboard.
                    child: SafeArea(
                      top: false,
                      child: ResizableWorkspace(
                        toolsOpen: open.tools,
                        outlineOpen: open.outline,
                        tools: IndexedStack(
                          index: _tools.indexOf(_tool),
                          children: [
                            for (final t in _tools)
                              kept(t, open.tools && _tool == t),
                          ],
                        ),
                        content: _page(story, selected),
                        outline: _outline(story, selected, wide),
                      ),
                    ),
                  ),
                  Container(
                    key: const Key('workspace-sections'),
                    width: 56,
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: theme.colors.border),
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          spacing: 8,
                          children: [
                            for (final t in _tools)
                              CountBadge(
                                count: destinations[t.index].badge,
                                child: IconAction(
                                  icon: t.icon,
                                  tooltip: t.label,
                                  size: 20,
                                  selected: open.tools && _tool == t,
                                  onPress: () => _pickTool(t),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : IndexedStack(
                index: _section.index,
                children: [
                  for (final s in WorkspaceSection.values)
                    kept(s, _section == s),
                ],
              ),
      ),
    );
  }

  Future<void> _renameChapter(StorySnapshot story, Chapter chapter) async {
    final name = await askText(
      context,
      title: '章节名称',
      initial: chapter.name,
      label: '章节名',
      allowEmpty: true,
    );
    if (name == null) return;
    try {
      await ref
          .read(repositoryProvider)
          .renameChapter(
            branchId: story.branch.id,
            chapterId: chapter.id,
            name: name,
          );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _numberFrom(StorySnapshot story, Chapter chapter) async {
    try {
      await ref
          .read(repositoryProvider)
          .numberChaptersFrom(branchId: story.branch.id, chapterId: chapter.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _toggleNumbered(StorySnapshot story, Chapter chapter) async {
    try {
      await ref
          .read(repositoryProvider)
          .setChapterNumbered(
            branchId: story.branch.id,
            chapterId: chapter.id,
            numbered: !chapter.numbered,
          );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteChapter(StorySnapshot story, Chapter chapter) async {
    final confirm = await confirmAction(
      context,
      title: '删除“${chapter.title}”？',
      message:
          '本章会从当前分支删除，连同它的候选、书签、变量记录和编辑会话，不能撤销。'
          '本章里记下的资料会保留，改挂到上一章末尾；其他分支不受影响。',
      confirmLabel: '删除章节',
      destructive: true,
    );
    if (!confirm || !mounted) return;
    try {
      final services = ref.read(servicesProvider), branchId = story.branch.id;
      for (final task in await services.repository.activeChapterTasks(
        branchId: branchId,
        chapterId: chapter.id,
      )) {
        await services.runner.cancel(task.id);
        await services.runner.wait(task.id);
      }
      await services.repository.deleteChapter(
        branchId: branchId,
        chapterId: chapter.id,
      );
      if (mounted && _selected == chapter.id) {
        setState(() => _selected = null);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// The page of a wide screen: the reader itself, with every reading
  /// feature, kept in step with the outline on both sides.
  Widget _page(StorySnapshot story, Chapter? selected) => selected == null
      ? const Center(child: Text('选择一个章节'))
      : ReaderScreen(
          key: ValueKey('reader:${story.branch.id}'),
          branchId: story.branch.id,
          embedded: true,
          chapterId: _selected,
          onChapterChanged: (chapter) {
            if (_selected != chapter.id) setState(() => _selected = chapter.id);
          },
          onEdit: _edit,
          onIllustrate: _illustrate,
        );

  /// The table of contents. On wide screens picking a chapter shows it on the
  /// page beside it.
  Widget _outline(StorySnapshot story, Chapter? selected, bool wide) {
    final theme = context.theme;
    // Whether a chapter, or one after it, still reads 第N章 outside the
    // numbering: there, numbering on from it closes an old gap.
    final kept = List.filled(story.chapters.length + 1, false);
    for (var i = story.chapters.length - 1; i >= 0; i--) {
      kept[i] = kept[i + 1] || story.chapters[i].keptOldNumber;
    }
    final muted = theme.typography.body.xs.copyWith(
      color: theme.colors.mutedForeground,
    );
    final goal =
        ref.watch(settingProvider('goal/${story.novel.id}')).value?['words']
            as int? ??
        0;
    final outline = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          story.novel.genre,
          style: theme.typography.body.sm.copyWith(
            color: theme.colors.primary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${countCharacters(story.text)} 字 · ${story.chapters.length} 章',
          style: muted,
        ),
        if (goal > 0) ...[
          const SizedBox(height: 12),
          FDeterminateProgress(
            value: (int.parse(countCharacters(story.text)) / goal)
                .clamp(0, 1)
                .toDouble(),
            semanticsLabel: '写作目标进度',
          ),
          const SizedBox(height: 6),
          Text('目标 $goal 字', style: muted),
        ],
        if (story.novel.synopsis.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              story.novel.synopsis,
              style: theme.typography.body.sm.copyWith(
                height: 1.6,
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
        const SizedBox(height: 20),
        Text(
          '正文目录',
          style: theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colors.foreground,
          ),
        ),
        if (story.chapters.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('先创建一个章节，开始你的故事。'),
          ),
        for (final (i, chapter) in story.chapters.indexed)
          FItem(
            selected: wide && selected?.id == chapter.id,
            prefix: const Icon(FLucideIcons.fileText),
            title: Text(chapter.title.isEmpty ? '未命名章节' : chapter.title),
            subtitle: Text('${countCharacters(chapter.content.text)} 字'),
            suffix: MenuAction(
              tooltip: '章节操作',
              entries: [
                menuEntry(
                  '重命名章节',
                  () => _renameChapter(story, chapter),
                  icon: FLucideIcons.pencil,
                ),
                menuEntry(
                  chapter.numbered ? '不计入编号' : '计入编号',
                  () => _toggleNumbered(story, chapter),
                  icon: FLucideIcons.hash,
                ),
                if (kept[i])
                  menuEntry(
                    '从此章起全部计入编号',
                    () => _numberFrom(story, chapter),
                    icon: FLucideIcons.listOrdered,
                  ),
                menuEntry(
                  '删除章节',
                  () => _deleteChapter(story, chapter),
                  icon: FLucideIcons.trash2,
                  destructive: true,
                ),
              ],
            ),
            onPress: () {
              if (wide) {
                setState(() => _selected = chapter.id);
              } else {
                _push(
                  ReaderScreen(
                    branchId: story.branch.id,
                    chapterId: chapter.id,
                    onEdit: _edit,
                    onIllustrate: _illustrate,
                  ),
                );
              }
            },
          ),
        const SizedBox(height: 90),
      ],
    );
    // The add button belongs to the outline: on wide screens it sits in the
    // outline pane, so it never covers the reader's own bottom bar.
    return Stack(
      children: [
        Positioned.fill(child: outline),
        Positioned(
          right: 16,
          bottom: 16,
          child: SafeArea(
            child: FloatingAction(
              icon: FLucideIcons.plus,
              label: '新增章节',
              onPress: () => _addChapter(story),
            ),
          ),
        ),
      ],
    );
  }
}
