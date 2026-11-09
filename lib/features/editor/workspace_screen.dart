import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/task_activity.dart';
import '../../app/widgets.dart';
import '../bookshelf/novel_dialog.dart';
import '../comics/comic_canvas.dart';
import '../comics/comic_dialogs.dart';
import '../comics/comic_screen.dart';
import '../comics/comic_reader.dart';
import '../comics/comic_storyboard.dart';
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
  gallery(FLucideIcons.images, '插图'),
  comic(FLucideIcons.bookImage, '漫画');

  const WorkspaceSection(this.icon, this.label);
  final IconData icon;
  final String label;
}

/// The sections a wide workspace offers as tools beside the page.
const _tools = [
  WorkspaceSection.agent,
  WorkspaceSection.lore,
  WorkspaceSection.gallery,
  WorkspaceSection.comic,
];

/// A comic work's sections on a phone: the canvas right after the outline.
const _comicSections = [
  WorkspaceSection.manuscript,
  WorkspaceSection.comic,
  WorkspaceSection.lore,
  WorkspaceSection.agent,
  WorkspaceSection.gallery,
];

/// Whether a chapter's comic work goes through the adaptation panel: its
/// comic is an adaptation, or it holds prose and no comic yet.
bool _adapts(Chapter chapter, ComicRevision? head) => head == null
    ? chapter.content.text.trim().isNotEmpty
    : !head.document.isOriginal;

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
  bool _initialSection = false;
  var _section = WorkspaceSection.manuscript;

  /// The tool on the right of a wide screen: the assistant until another is
  /// picked.
  var _tool = WorkspaceSection.agent;

  /// Whether the side panes of a wide screen are open; null until changed
  /// here, which keeps the stored choice.
  bool? _toolsOpen, _outlineOpen;

  /// The latest request for the assistant from the reader.
  AgentRequest? _agentRequest;

  /// A comic work's page picked on the canvas, shown by the storyboard; null
  /// means the last page.
  String? _selectedPage;

  /// Text a finished episode carries into the next one's opening, with the
  /// chapter it belongs to: the outline may show another chapter for a frame
  /// before the new one loads.
  (String, String)? _carry;

  void _select(String chapterId, {String? carry}) => setState(() {
    if (_selected != chapterId) _selectedPage = null;
    _selected = chapterId;
    _carry = carry == null ? null : (chapterId, carry);
  });

  /// Opens the adaptation panel: the tool beside the page, or for a comic
  /// work on a phone (whose 漫画 section is the canvas) a page of its own.
  void _adapt(StorySnapshot story, String chapterId, bool wide) {
    _select(chapterId);
    if (story.novel.workFormat == WorkFormat.comic && !wide) {
      _push(ComicScreen(branchId: story.branch.id, chapterId: chapterId));
    } else {
      _go(WorkspaceSection.comic);
    }
  }

  void _try(Future<void> action) => unawaited(
    action.catchError((Object e) {
      if (mounted) showError(context, e);
    }),
  );

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
        illustrationOnly: true,
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
        _select(chapter.id);
        if (story.novel.workFormat == WorkFormat.comic) {
          _go(WorkspaceSection.comic);
        } else {
          _edit(chapter);
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// The story last shown, kept on screen while a newly picked branch loads
  /// so the sections, and unsaved storyboard edits, stay mounted.
  StorySnapshot? _shown;

  @override
  Widget build(BuildContext context) => AsyncView(
    value: ref.watch(novelProvider(widget.novelId)),
    builder: (novel) {
      final story = ref.watch(storyProvider(novel.activeBranchId));
      return AsyncView(
        value: story.isLoading && !story.hasValue && _shown != null
            ? AsyncData(_shown!)
            : story,
        builder: (story) => _buildStory(_shown = story),
      );
    },
  );

  Widget _buildStory(StorySnapshot story) {
    if (!_initialSection) {
      _initialSection = true;
      if (story.novel.workFormat == WorkFormat.comic) {
        _section = _tool = WorkspaceSection.comic;
        _visited.add(_section);
      }
    }
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final comic = story.novel.workFormat == WorkFormat.comic;
    final selected =
        story.chapters.where((s) => s.id == _selected).firstOrNull ??
        story.chapters.firstOrNull;
    final pending =
        ref.watch(pendingReviewCountProvider(story.branch.id)).value ?? 0;
    final sections = comic ? _comicSections : WorkspaceSection.values;
    // A comic work's 漫画 is the canvas on a phone, and its storyboard
    // beside the canvas on a wide screen.
    String label(WorkspaceSection s) => switch (s) {
      WorkspaceSection.manuscript when comic => '目录',
      WorkspaceSection.comic when comic && wide => '分镜',
      _ => s.label,
    };
    int badge(WorkspaceSection s) => s == WorkspaceSection.agent ? pending : 0;
    final destinations = <NavDestination>[
      for (final s in sections)
        (icon: s.icon, label: label(s), badge: badge(s)),
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
      WorkspaceSection.comic when selected == null => const Center(
        child: Text('先创建一话，开始画漫画'),
      ),
      WorkspaceSection.comic when comic && !wide => _canvas(
        story,
        selected!,
        wide: false,
      ),
      WorkspaceSection.comic when comic => _storyboard(story, selected!),
      WorkspaceSection.comic => ComicScreen(
        key: ValueKey('comic:$branchKey:${selected!.id}'),
        branchId: branchKey,
        chapterId: selected.id,
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
            const TaskActivityAction(),
            HeaderIconAction(
              key: const Key('open-reader'),
              icon: FLucideIcons.bookOpen,
              tooltip: '阅读',
              onPress: () => _push(
                story.novel.workFormat == WorkFormat.comic && selected != null
                    ? ComicReader(branchId: branchKey, chapterId: selected.id)
                    : ReaderScreen(
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
                if (comic && selected != null)
                  menuEntry(
                    '导出漫画',
                    () => _try(
                      showComicExport(
                        context,
                        ref,
                        branchId: branchKey,
                        chapterId: selected.id,
                      ),
                    ),
                    icon: FLucideIcons.fileArchive,
                  ),
              ],
            ),
            if (wide)
              HeaderIconAction(
                key: const Key('workspace-tools-toggle'),
                icon: open.tools
                    ? FLucideIcons.panelRight
                    : FLucideIcons.panelRightDashed,
                tooltip: '${open.tools ? '收起' : '显示'}${label(_tool)}',
                onPress: () => _panes(tools: !open.tools),
              ),
          ],
        ),
        footer: wide
            ? null
            : AppBottomBar(
                key: const Key('workspace-sections'),
                selectedIndex: sections.indexOf(_section),
                onSelect: (i) => _go(sections[i]),
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
                                count: badge(t),
                                child: IconAction(
                                  icon: t.icon,
                                  tooltip: label(t),
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
                index: sections.indexOf(_section),
                children: [for (final s in sections) kept(s, _section == s)],
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
  /// feature, kept in step with the outline on both sides. A comic work's
  /// page is its comic.
  Widget _page(StorySnapshot story, Chapter? selected) => selected == null
      ? const Center(child: Text('选择一个章节'))
      : story.novel.workFormat == WorkFormat.comic
      ? _canvas(story, selected, wide: true)
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

  /// One episode of a comic work, where it is read and drawn.
  Widget _canvas(StorySnapshot story, Chapter chapter, {required bool wide}) {
    final branchId = story.branch.id;
    final head = ref.watch(comicHeadProvider((branchId, chapter.id)));
    final adapts = head.hasValue && _adapts(chapter, head.value);
    final carry = _carry?.$1 == chapter.id ? _carry!.$2 : null;
    // Handed over once: the canvas keeps it from here.
    if (carry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _carry = null);
    }
    void pick(String page) {
      setState(() => _selectedPage = page);
      if (wide) _go(WorkspaceSection.comic);
    }

    return ComicCanvas(
      // Each episode starts at its top.
      key: ValueKey('canvas:$branchId:${chapter.id}'),
      branchId: branchId,
      chapterId: chapter.id,
      selectedPageId: _selectedPage,
      initialInstruction: carry,
      onSelectPage: pick,
      onEditStoryboard: adapts
          ? (_) => _adapt(story, chapter.id, wide)
          : wide
          ? pick
          : (page) => _push(
              ComicStoryboard(
                branchId: branchId,
                chapterId: chapter.id,
                pageId: page,
              ),
            ),
      onOpenChapter: (id, instruction) => _select(id, carry: instruction),
      onReadProse: () => _push(
        ReaderScreen(
          branchId: branchId,
          chapterId: chapter.id,
          onEdit: _edit,
          onIllustrate: _illustrate,
        ),
      ),
      onAdapt: () => _adapt(story, chapter.id, wide),
    );
  }

  /// A comic work's tool beside the canvas: the picked page's storyboard,
  /// or the adaptation panel for an episode adapted from its prose.
  Widget _storyboard(StorySnapshot story, Chapter chapter) {
    final branchId = story.branch.id;
    final head = ref.watch(comicHeadProvider((branchId, chapter.id)));
    final adapts = head.hasValue && _adapts(chapter, head.value);
    // The storyboard stays mounted under the panel and across episodes,
    // pages and branches. Its unsaved drafts live in comicDraftsProvider,
    // so the remount when the window crosses 900 px keeps them as well.
    return IndexedStack(
      index: adapts ? 1 : 0,
      children: [
        ComicStoryboard(
          key: ValueKey('storyboard:${story.novel.id}'),
          branchId: branchId,
          chapterId: chapter.id,
          pageId: _selectedPage,
          embedded: true,
        ),
        if (adapts)
          ComicScreen(
            key: ValueKey('comic:$branchId:${chapter.id}'),
            branchId: branchId,
            chapterId: chapter.id,
            embedded: true,
          ),
      ],
    );
  }

  /// An episode's outline line: how much comic it has, or that it is drawing.
  String _comicLine(StorySnapshot story, Chapter chapter, bool drawing) {
    if (drawing) return '绘制中';
    final doc = ref
        .watch(comicHeadProvider((story.branch.id, chapter.id)))
        .value
        ?.document;
    // Older adaptations are single panels, not pages.
    return doc != null && !doc.hasPages
        ? '${doc.panels.length} 格'
        : '${doc?.pages.length ?? 0} 页';
  }

  /// The comic entries of an episode's menu in a comic work.
  List<MenuEntry> _episodeMenu(
    StorySnapshot story,
    Chapter chapter,
    bool wide,
  ) {
    final branchId = story.branch.id;
    final head = ref.watch(comicHeadProvider((branchId, chapter.id)));
    if (!head.hasValue) return [];
    return [
      if (_adapts(chapter, head.value))
        menuEntry(
          '改编为漫画',
          () => _adapt(story, chapter.id, wide),
          icon: WorkspaceSection.comic.icon,
        ),
      if (head.value != null) ...[
        menuEntry(
          '本话历史版本',
          () => _try(
            showComicHistory(
              context,
              ref,
              branchId: branchId,
              chapterId: chapter.id,
            ),
          ),
          icon: FLucideIcons.history,
        ),
        menuEntry(
          '导出漫画',
          () => _try(
            showComicExport(
              context,
              ref,
              branchId: branchId,
              chapterId: chapter.id,
            ),
          ),
          icon: FLucideIcons.fileArchive,
        ),
      ],
    ];
  }

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
    final comic = story.novel.workFormat == WorkFormat.comic;
    // Episodes a comic task is drawing; suggesting directions is not drawing.
    // Selected as one string so other task writes do not rebuild the page.
    final drawing = comic
        ? ref
              .watch(
                tasksProvider(story.branch.id).select(
                  (tasks) => [
                    for (final t in tasks.value ?? <GenerationTask>[])
                      if (t.kind == TaskKind.comic &&
                          t.isActive &&
                          t.input['comicAction'] != 'directions')
                        ...(t.input['comicHeads'] as Map? ?? {}).keys,
                  ].join(' '),
                ),
              )
              .split(' ')
              .toSet()
        : const <String>{};
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
          story.novel.workFormat == WorkFormat.comic
              ? '${story.chapters.length} 话'
              : '${countCharacters(story.text)} 字 · ${story.chapters.length} 章',
          style: muted,
        ),
        if (goal > 0 && story.novel.workFormat != WorkFormat.comic) ...[
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
          story.novel.workFormat == WorkFormat.comic ? '漫画目录' : '正文目录',
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
            subtitle: comic
                ? Text(_comicLine(story, chapter, drawing.contains(chapter.id)))
                : Text('${countCharacters(chapter.content.text)} 字'),
            suffix: MenuAction(
              tooltip: '章节操作',
              entries: [
                if (!comic)
                  menuEntry('改编为漫画', () {
                    _select(chapter.id);
                    _go(WorkspaceSection.comic);
                  }, icon: WorkspaceSection.comic.icon)
                else
                  ..._episodeMenu(story, chapter, wide),
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
                _select(chapter.id);
              } else if (comic) {
                _select(chapter.id);
                _go(WorkspaceSection.comic);
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
