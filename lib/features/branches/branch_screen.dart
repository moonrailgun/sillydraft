import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../agent/task_screen.dart';
import '../editor/workspace_screen.dart';
import 'branch_comparison_screen.dart';

final branchesProvider = FutureProvider.family<List<StoryBranch>, String>((
  ref,
  novelId,
) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listBranches(novelId);
});

/// Which candidates of a story-direction run became branches.
final _chosenProvider = FutureProvider.family<Map<int, String>, String>((
  ref,
  taskId,
) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).selectedCandidateBranches(taskId);
});

/// Where a branch left its parent: 第五章后, or 「序章」后 for a chapter
/// outside the numbering.
String _forkLabel(Chapter c) => c.numbered
    ? '${chapterTitle(c.number, '', c.numerals)}后'
    : '「${c.name.isEmpty ? '未命名章节' : c.name}」后';

/// The branches of a novel as a tree: each branch hangs under the one it
/// was forked from, marked with the chapter it left it after.
class BranchScreen extends ConsumerStatefulWidget {
  const BranchScreen({super.key, required this.novelId});
  final String novelId;
  @override
  ConsumerState<BranchScreen> createState() => _BranchState();
}

class _BranchState extends ConsumerState<BranchScreen> {
  /// The branch whose actions are open.
  String? _selected;

  Future<void> _newBranch() async {
    final novel = ref.read(novelProvider(widget.novelId)).value;
    if (novel == null) return;
    final id = await showAppDialog<String>(
      context: context,
      builder: (_) => _NewBranchDialog(
        novelId: novel.id,
        source: _selected ?? novel.activeBranchId,
      ),
    );
    if (id != null && mounted) setState(() => _selected = id);
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '故事分支',
    actions: [
      FButton(
        variant: FButtonVariant.outline,
        size: FButtonSizeVariant.sm,
        mainAxisSize: MainAxisSize.min,
        onPress: _newBranch,
        prefix: const Icon(FLucideIcons.gitFork),
        child: const Text('新建分支'),
      ),
    ],
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: AsyncView(
          value: ref.watch(novelProvider(widget.novelId)),
          builder: (novel) => AsyncView(
            value: ref.watch(branchesProvider(novel.id)),
            builder: (branches) => _page(novel, branches),
          ),
        ),
      ),
    ),
  );

  Widget _page(Novel novel, List<StoryBranch> branches) {
    final byId = {for (final b in branches) b.id: b};
    final children = <String?, List<StoryBranch>>{};
    for (final b in branches) {
      // A branch whose parent is gone stands at the top.
      final parent = byId.containsKey(b.parentBranchId)
          ? b.parentBranchId
          : null;
      (children[parent] ??= []).add(b);
    }
    final line = context.theme.colors.border;
    // [last] is null for a branch at the top, which hangs on no line.
    Widget subtree(StoryBranch b, {bool? last}) {
      final kids = children[b.id] ?? const <StoryBranch>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _node(novel, b, byId[b.parentBranchId], last: last),
          if (kids.isNotEmpty)
            Padding(
              // Puts the tree line under this branch's dot.
              padding: const EdgeInsets.only(left: 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, k) in kids.indexed)
                    // A sibling below carries the line on past this one.
                    CustomPaint(
                      painter: i == kids.length - 1 ? null : _Trunk(line),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14),
                        child: subtree(k, last: i == kids.length - 1),
                      ),
                    ),
                ],
              ),
            ),
        ],
      );
    }

    final focus = byId[_selected] ?? byId[novel.activeBranchId];
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '每条分支保留各自的正文、人物资料和故事变量。点一条分支，可以切换过去或与当前比较。',
          style: context.theme.typography.body.sm.copyWith(
            color: context.theme.colors.mutedForeground,
          ),
        ),
        const SizedBox(height: 16),
        for (final root in children[null] ?? const <StoryBranch>[])
          subtree(root),
        if (focus != null) ...[
          const SizedBox(height: 28),
          AsyncView(
            value: ref.watch(tasksProvider(focus.id)),
            builder: (all) => _directions(all, focus.name),
          ),
        ],
      ],
    );
  }

  Widget _node(Novel novel, StoryBranch b, StoryBranch? parent, {bool? last}) {
    final theme = context.theme;
    final active = b.id == novel.activeBranchId;
    final selected = b.id == _selected;
    final story = ref.watch(storyProvider(b.id)).value;
    final fork = story?.chapters
        .where((c) => c.id == b.forkChapterId)
        .firstOrNull;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final radius = theme.style.borderRadius.lg;
    final row = Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? theme.colors.foreground : null,
            border: Border.all(
              color: active
                  ? theme.colors.foreground
                  : theme.colors.mutedForeground,
              width: 2,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: b.name,
                  style: theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (active)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: FBadge(child: const Text('正在创作')),
                    ),
                  ),
                if (parent == null)
                  TextSpan(text: '  起始分支', style: muted)
                else if (fork != null)
                  TextSpan(text: '  ${_forkLabel(fork)}', style: muted),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (story != null) ...[
          const SizedBox(width: 8),
          Text('${story.chapters.length} 章', style: muted),
        ],
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? theme.colors.card : null,
        border: Border.all(
          color: selected ? theme.colors.border : Colors.transparent,
        ),
        borderRadius: radius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTappable(
            key: ValueKey('branch-${b.id}'),
            semanticsExpanded: selected,
            onPress: () => setState(() => _selected = selected ? null : b.id),
            builder: (context, states, child) => DecoratedBox(
              decoration: BoxDecoration(
                color: !selected && states.contains(FTappableVariant.hovered)
                    ? theme.colors.secondary
                    : null,
                borderRadius: radius,
              ),
              child: child,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: CustomPaint(
                painter: last == null
                    ? null
                    : _Turn(last: last, color: theme.colors.border),
                child: row,
              ),
            ),
          ),
          if (selected)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    parent == null
                        ? '起始分支'
                        : fork == null
                        ? '来自「${parent.name}」'
                        : '从「${parent.name}」的${fork.title}之后分开',
                    style: muted,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!active) ...[
                        FButton(
                          key: ValueKey('activate-${b.id}'),
                          variant: FButtonVariant.outline,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          onPress: () => _activate(b),
                          child: const Text('切换到此分支'),
                        ),
                        FButton(
                          key: ValueKey('compare-${b.id}'),
                          variant: FButtonVariant.ghost,
                          size: FButtonSizeVariant.sm,
                          mainAxisSize: MainAxisSize.min,
                          prefix: const Icon(FLucideIcons.gitCompare),
                          onPress: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => BranchComparisonScreen(
                                leftId: novel.activeBranchId,
                                rightId: b.id,
                              ),
                            ),
                          ),
                          child: const Text('与当前比较'),
                        ),
                      ],
                      FButton(
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        prefix: const Icon(FLucideIcons.pencil),
                        onPress: () => _rename(b),
                        child: const Text('重命名'),
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

  Future<void> _activate(StoryBranch b) async {
    try {
      await ref.read(servicesProvider).flushDrafts();
      await ref.read(repositoryProvider).setActiveBranch(b.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _rename(StoryBranch b) async {
    final name = await askText(context, title: '重命名分支', initial: b.name);
    if (name == null) return;
    try {
      await ref.read(repositoryProvider).renameBranch(b.id, name);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Earlier story-direction runs on [branchName], each by the directions
  /// it proposed; the ones taken up as branches stand out.
  Widget _directions(List<GenerationTask> all, String branchName) {
    final tasks = all.where((t) => t.kind == TaskKind.branches).toList();
    if (tasks.isEmpty) return const SizedBox.shrink();
    final theme = context.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(FLucideIcons.compass, size: 16),
            const SizedBox(width: 8),
            Text(
              '走向候选',
              style: theme.typography.body.md.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                branchName,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FTileGroup(children: [for (final task in tasks) _directionTile(task)]),
      ],
    );
  }

  FTile _directionTile(GenerationTask task) {
    final titles = [
      if (task.status == TaskStatus.completed)
        for (final c in task.result['candidates'] as List? ?? const [])
          if (c is Map && c['title'] is String) c['title'] as String,
    ];
    final chosen = ref.watch(_chosenProvider(task.id)).value ?? const {};
    return FTile(
      title: titles.isEmpty
          ? Text('故事走向 · ${taskStatusLabels[task.status]}')
          : Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, title) in titles.indexed)
                  FBadge(
                    variant: chosen.containsKey(i)
                        ? FBadgeVariant.primary
                        : FBadgeVariant.secondary,
                    child: Text(title),
                  ),
              ],
            ),
      subtitle: Text(
        [
          task.createdAt.toLocal().toString().substring(0, 16),
          if (chosen.isNotEmpty) '已开 ${chosen.length} 条分支',
        ].join(' · '),
      ),
      suffix: const Icon(FLucideIcons.chevronRight),
      onPress: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
      ),
    );
  }
}

/// The tree line down the whole of a child branch that has a sibling below.
class _Trunk extends CustomPainter {
  const _Trunk(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawLine(
    const Offset(1, 0),
    Offset(1, size.height),
    Paint()
      ..color = color
      ..strokeWidth = 2,
  );

  @override
  bool shouldRepaint(_Trunk old) => old.color != color;
}

/// The turn from the tree line to a child branch's dot, painted from its
/// row so it meets the dot at any text size. The [last] child also brings
/// the line down to the turn, as no [_Trunk] carries it.
class _Turn extends CustomPainter {
  const _Turn({required this.last, required this.color});
  final bool last;
  final Color color;

  /// The tree line, left of the row by the indent (14) and the node's
  /// padding (10), less half its width.
  static const _line = -23.0;

  /// The top of the child's subtree, above the row by the node's padding.
  static const _top = -8.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    final y = size.height / 2;
    canvas.drawLine(Offset(_line - 1, y), Offset(-2, y), paint);
    if (last) {
      canvas.drawLine(const Offset(_line, _top), Offset(_line, y), paint);
    }
  }

  @override
  bool shouldRepaint(_Turn old) => old.last != last || old.color != color;
}

/// Forks a branch at a chapter of the author's choosing, under a new name,
/// and makes it the one being written. Pops with the new branch's id.
class _NewBranchDialog extends ConsumerStatefulWidget {
  const _NewBranchDialog({required this.novelId, required this.source});
  final String novelId, source;
  @override
  ConsumerState<_NewBranchDialog> createState() => _NewBranchState();
}

class _NewBranchState extends ConsumerState<_NewBranchDialog> {
  late String _source = widget.source;

  /// The chapter to fork after; null for the end of the story.
  String? _chapter;
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(servicesProvider).flushDrafts();
      final repo = ref.read(repositoryProvider);
      final branch = await repo.forkBranch(
        branchId: _source,
        name: name,
        atChapterId: _chapter,
      );
      await repo.setActiveBranch(branch.id);
      if (mounted) Navigator.pop(context, branch.id);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final branches =
        ref.watch(branchesProvider(widget.novelId)).value ??
        const <StoryBranch>[];
    final byId = {for (final b in branches) b.id: b};
    return AppDialog(
      title: const Text('新建分支'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FTextField(
            control: FTextFieldControl.managed(controller: _name),
            autofocus: true,
            label: const Text('新分支名称'),
            onSubmit: (_) => _create(),
          ),
          const SizedBox(height: 16),
          FSelect<String>.rich(
            key: ValueKey('source:$_source'),
            label: const Text('从哪条分支'),
            control: FSelectControl<String>.lifted(
              value: _source,
              onChange: (v) => setState(() {
                if (v != null) _source = v;
                _chapter = null;
              }),
            ),
            format: (id) => byId[id]?.name ?? '',
            children: [
              for (final b in branches)
                FSelectItem<String>(title: Text(b.name), value: b.id),
            ],
          ),
          const SizedBox(height: 16),
          AsyncView(
            value: ref.watch(storyProvider(_source)),
            builder: (story) {
              // The empty id stands for the end of the story.
              String title(String id) => id.isEmpty
                  ? '当前故事末尾'
                  : switch (story.chapters
                        .where((s) => s.id == id)
                        .firstOrNull) {
                      null => '',
                      final s when s.title.isEmpty => '未命名章节',
                      final s => s.title,
                    };
              return FSelect<String>.rich(
                key: ValueKey('cutoff:$_source:$_chapter'),
                label: const Text('在哪一章之后分开'),
                control: FSelectControl<String>.lifted(
                  value: _chapter ?? '',
                  onChange: (v) => setState(
                    () => _chapter = v == null || v.isEmpty ? null : v,
                  ),
                ),
                format: title,
                children: [
                  FSelectItem<String>(title: Text(title('')), value: ''),
                  for (final s in story.chapters)
                    FSelectItem<String>(
                      title: Text(title(s.id), overflow: TextOverflow.ellipsis),
                      value: s.id,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text(
            '新分支保留到这一章为止的正文、人物资料和故事变量，原分支不受影响。',
            style: theme.typography.body.sm.copyWith(
              color: theme.colors.mutedForeground,
            ),
          ),
        ],
      ),
      actions: [
        FButton(
          variant: FButtonVariant.outline,
          onPress: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FButton(
          onPress: _busy ? null : _create,
          prefix: const Icon(FLucideIcons.gitFork),
          child: const Text('创建分支'),
        ),
      ],
    );
  }
}
