import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../branches/branch_screen.dart';
import '../lore/sidecar.dart';
import '../settings/world_info_budget.dart';
import 'next_chapter.dart';

/// The latest story-direction run on a branch, and whether the story it
/// read is still the story.
final _directionsProvider =
    FutureProvider.family<({GenerationTask task, bool current})?, String>((
      ref,
      branchId,
    ) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider);
      final task = (await repo.listTasks(branchId: branchId))
          .where((t) => t.kind == TaskKind.branches)
          .firstOrNull;
      if (task == null) return null;
      return (task: task, current: await repo.taskSourcesCurrent(task.id));
    });

/// Under the last chapter: three ways the story could go on, proposed from the
/// whole text. Picking one writes the next chapter along it, with the
/// branch's preset and cards, and turns to it ([onOpenChapter]) to read as it
/// is written; it joins the book by itself once done.
///
/// With [auto], the directions are proposed as soon as this comes into view,
/// if a model is set up for it: once for each version of the story, and
/// never over directions that still fit it, nor after a run that failed or
/// was stopped, which waits for the author.
class StoryDirections extends ConsumerStatefulWidget {
  const StoryDirections({
    super.key,
    required this.story,
    this.auto = false,
    this.onOpenChapter,
  });
  final StorySnapshot story;
  final bool auto;

  /// Shows a chapter of the story: the chapter just started.
  final ValueChanged<String>? onOpenChapter;
  @override
  ConsumerState<StoryDirections> createState() => _DirectionsState();
}

class _DirectionsState extends ConsumerState<StoryDirections> {
  bool _busy = false;

  /// The direction whose brief is open for editing, and the edit.
  int? _adjusting;
  final _brief = TextEditingController();

  /// The story version an automatic run was last considered for.
  String? _autoFor;

  /// Why the last automatic run could not start.
  Object? _autoError;
  ScrollPosition? _position;

  String get _branchId => widget.story.branch.id;
  String get _version =>
      [for (final s in widget.story.chapters) s.revisionId].join(',');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context)?.position;
    if (position != _position) {
      _position?.removeListener(_checkInView);
      _position = position?..addListener(_checkInView);
    }
    _checkSoon();
  }

  @override
  void didUpdateWidget(StoryDirections old) {
    super.didUpdateWidget(old);
    _checkSoon();
  }

  @override
  void dispose() {
    _position?.removeListener(_checkInView);
    _brief.dispose();
    super.dispose();
  }

  void _checkSoon() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _checkInView();
  });

  /// Starts an automatic run once the top of this is on screen.
  void _checkInView() {
    if (!widget.auto || _autoFor == _version) return;
    // An empty end is a chapter about to be written, not an end to go on
    // from.
    if (widget.story.chapters.lastOrNull?.content.text.trim().isEmpty ?? true) {
      return;
    }
    final box = context.findRenderObject();
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    if (viewport is RenderBox && viewport.hasSize) {
      final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (top > viewport.size.height) return;
    }
    _autoFor = _version;
    unawaited(_autoSuggest());
  }

  /// Automatic runs being started, by branch and story version, so two
  /// readers of one branch (a pane and the full-screen one) start one run.
  static final _starting = <String>{};

  Future<void> _autoSuggest() async {
    final key = '$_branchId@$_version';
    if (!_starting.add(key)) return;
    try {
      final services = ref.read(servicesProvider), repo = services.repository;
      final latest = (await repo.listTasks(branchId: _branchId))
          .where((t) => t.kind == TaskKind.branches)
          .firstOrNull;
      if (latest != null && await repo.taskSourcesCurrent(latest.id)) return;
      final connection = await services.connectionFor('analysis');
      // Without a model the button stays for when one is set up.
      if (connection == null || !mounted) return;
      await services.writing.suggestBranches(
        branchId: _branchId,
        connection: connection,
      );
      if (mounted && _autoError != null) setState(() => _autoError = null);
    } catch (e) {
      if (mounted) setState(() => _autoError = e);
    } finally {
      _starting.remove(key);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    // Writing adds a chapter, which can replace this panel before a later
    // step fails; the navigator outlives it to show the error.
    final host = Navigator.of(context).context;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      showError(mounted ? context : host, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _suggest() => _run(() async {
    setState(() => _autoError = null);
    final services = ref.read(servicesProvider);
    final connection = await services.connectionFor('analysis');
    if (connection == null) throw const FormatException('请先配置整理模型。');
    await services.writing.suggestBranches(
      branchId: _branchId,
      connection: connection,
    );
  });

  /// Writes the next chapter along [direction], or along [brief] when the
  /// author adjusted it, and turns to it.
  Future<void> _write(Map direction, {String? brief}) => _run(() async {
    final chapter = await startNextChapter(
      ref,
      widget.story,
      name: '${direction['title']}',
      brief: brief ?? chapterBrief(direction),
      onWaitSidecar: () => toast(context, sidecarWaitNotice),
      onBudgetDrop: (summary) => showWorldInfoBudgetNotice(context, summary),
    );
    if (mounted) setState(() => _adjusting = null);
    widget.onOpenChapter?.call(chapter.id);
  });

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final latest = ref.watch(_directionsProvider(_branchId)).value;
    final task = latest?.task;
    final current = latest?.current ?? false;
    final directions = task?.status == TaskStatus.completed && current
        ? [
            for (final c in task!.result['candidates'] as List? ?? const [])
              if (c is Map) c,
          ]
        : const <Map>[];
    final failed =
        task != null &&
        current &&
        [
          TaskStatus.failed,
          TaskStatus.interrupted,
          TaskStatus.cancelled,
        ].contains(task.status);
    final more = Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (directions.isNotEmpty)
          FButton(
            key: const Key('directions-again'),
            variant: FButtonVariant.ghost,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: _busy ? null : _suggest,
            prefix: const Icon(FLucideIcons.refreshCw),
            child: const Text('换一批'),
          ),
        FButton(
          variant: FButtonVariant.ghost,
          size: FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => BranchScreen(
                novelId: widget.story.novel.id,
                sourceBranchId: _branchId,
              ),
            ),
          ),
          prefix: const Icon(FLucideIcons.gitFork),
          child: const Text('分支与结局'),
        ),
      ],
    );
    return Column(
      key: const Key('story-directions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '接下来会怎样？',
          textAlign: TextAlign.center,
          style: theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colors.foreground,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          directions.isEmpty ? 'AI 根据全书内容提出三种走向，选一个即可续写。' : '选一个走向，直接写成下一章。',
          textAlign: TextAlign.center,
          style: muted,
        ),
        const SizedBox(height: 16),
        if (task != null && task.isActive && current) ...[
          const FProgress(),
          const SizedBox(height: 8),
          Text('正在根据全书构思三种走向…', textAlign: TextAlign.center, style: muted),
          const SizedBox(height: 8),
          Center(
            child: FButton(
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: () async {
                try {
                  await ref.read(servicesProvider).runner.cancel(task.id);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              prefix: const Icon(FLucideIcons.circleStop),
              child: const Text('取消'),
            ),
          ),
        ] else if (directions.isEmpty) ...[
          if (_autoError != null && !failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '$_autoError',
                textAlign: TextAlign.center,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.error,
                ),
              ),
            ),
          if (failed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                task.error.isEmpty ? '上次没有生成完成。' : task.error,
                textAlign: TextAlign.center,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.error,
                ),
              ),
            ),
          Center(
            child: FButton(
              key: const Key('directions-suggest'),
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : _suggest,
              prefix: const Icon(FLucideIcons.sparkles),
              child: Text(failed ? '重新生成' : '生成三种走向'),
            ),
          ),
        ] else
          for (final (i, d) in directions.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FCard(
                key: Key('direction-$i'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${i + 1}. ${d['title']}',
                        style: theme.typography.body.md.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colors.foreground,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${d['summary']}',
                        style: theme.typography.body.sm.copyWith(
                          height: 1.6,
                          color: theme.colors.foreground,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (_adjusting == i) ...[
                        FTextField(
                          key: Key('direction-brief-$i'),
                          control: FTextFieldControl.managed(
                            controller: _brief,
                          ),
                          minLines: 3,
                          maxLines: 8,
                          label: const Text('写作要求'),
                        ),
                        const SizedBox(height: 10),
                      ],
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FButton(
                            key: Key('direction-continue-$i'),
                            size: FButtonSizeVariant.sm,
                            mainAxisSize: MainAxisSize.min,
                            onPress: _busy
                                ? null
                                : () => _adjusting == i
                                      ? _write(d, brief: _brief.text.trim())
                                      : _write(d),
                            prefix: const Icon(FLucideIcons.penLine),
                            child: Text(_adjusting == i ? '按要求写下一章' : '写下一章'),
                          ),
                          FButton(
                            key: Key('direction-adjust-$i'),
                            variant: FButtonVariant.outline,
                            size: FButtonSizeVariant.sm,
                            mainAxisSize: MainAxisSize.min,
                            onPress: _busy
                                ? null
                                : () => setState(() {
                                    if (_adjusting == i) {
                                      _adjusting = null;
                                    } else {
                                      _adjusting = i;
                                      _brief.text = chapterBrief(d);
                                    }
                                  }),
                            child: Text(_adjusting == i ? '收起' : '调整要求'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        const SizedBox(height: 8),
        more,
      ],
    );
  }
}
