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

class BranchScreen extends ConsumerStatefulWidget {
  const BranchScreen({super.key, required this.novelId, this.sourceBranchId});
  final String novelId;
  final String? sourceBranchId;
  @override
  ConsumerState<BranchScreen> createState() => _BranchState();
}

class _BranchState extends ConsumerState<BranchScreen> {
  String? _source, _chapter;
  bool _endings = false, _busy = false;
  int _count = 3;
  Future<void> _fork(String source) async {
    final name = await askText(context, title: '从此处分叉', label: '新分支名称');
    if (name == null) return;
    try {
      final repo = ref.read(repositoryProvider);
      final branch = await repo.forkBranch(
        branchId: source,
        name: name,
        atChapterId: _chapter,
      );
      await repo.setActiveBranch(branch.id);
      if (mounted) {
        setState(() {
          _source = branch.id;
          _chapter = null;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _generate(String source) async {
    setState(() => _busy = true);
    try {
      final services = ref.read(servicesProvider),
          connection = await ref
              .read(servicesProvider)
              .connectionFor('analysis');
      if (connection == null) throw const FormatException('请先配置整理模型。');
      final task = await services.writing.suggestBranches(
        branchId: source,
        connection: connection,
        endings: _endings,
        count: _count,
      );
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '故事分支',
    body: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: AsyncView(
          value: ref.watch(novelProvider(widget.novelId)),
          builder: (novel) => AsyncView(
            value: ref.watch(branchesProvider(novel.id)),
            builder: (branches) {
              final source =
                  _source ?? widget.sourceBranchId ?? novel.activeBranchId;
              final byId = {for (final b in branches) b.id: b};
              int depth(StoryBranch b) {
                var d = 0;
                final seen = <String>{};
                while (b.parentBranchId != null && seen.add(b.id)) {
                  final parent = byId[b.parentBranchId];
                  if (parent == null) break;
                  d++;
                  b = parent;
                }
                return d;
              }

              final ordered = <StoryBranch>[];
              void visit(String? parent) {
                for (final b in branches.where(
                  (b) => b.parentBranchId == parent,
                )) {
                  ordered.add(b);
                  visit(b.id);
                }
              }

              visit(null);
              final theme = context.theme;
              final heading = theme.typography.body.md.copyWith(
                fontWeight: FontWeight.w600,
              );
              return ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text('每条分支保留各自的正文、人物资料和故事变量。切换分支继续写作，或比较不同发展。'),
                  const SizedBox(height: 20),
                  for (final b in ordered)
                    Padding(
                      padding: EdgeInsets.only(
                        left: (depth(b) * 12).clamp(0, 48).toDouble(),
                        bottom: 10,
                      ),
                      child: FCard(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    b.id == novel.activeBranchId
                                        ? FLucideIcons.circleCheck
                                        : FLucideIcons.gitBranch,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(child: Text(b.name, style: heading)),
                                  IconAction(
                                    icon: FLucideIcons.pencil,
                                    tooltip: '重命名分支',
                                    onPress: () async {
                                      final name = await askText(
                                        context,
                                        title: '重命名分支',
                                        initial: b.name,
                                      );
                                      if (name == null) return;
                                      try {
                                        await ref
                                            .read(repositoryProvider)
                                            .renameBranch(b.id, name);
                                      } catch (e) {
                                        if (context.mounted) {
                                          showError(context, e);
                                        }
                                      }
                                    },
                                  ),
                                ],
                              ),
                              Text(
                                b.parentBranchId == null
                                    ? '起始分支'
                                    : '来自：${byId[b.parentBranchId]?.name ?? '原分支'}',
                                style: theme.typography.body.sm.copyWith(
                                  color: theme.colors.mutedForeground,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FButton(
                                    key: ValueKey('activate-${b.id}'),
                                    variant: FButtonVariant.outline,
                                    size: FButtonSizeVariant.sm,
                                    mainAxisSize: MainAxisSize.min,
                                    onPress: b.id == novel.activeBranchId
                                        ? null
                                        : () async {
                                            try {
                                              await ref
                                                  .read(servicesProvider)
                                                  .flushDrafts();
                                              await ref
                                                  .read(repositoryProvider)
                                                  .setActiveBranch(b.id);
                                            } catch (e) {
                                              if (context.mounted) {
                                                showError(context, e);
                                              }
                                            }
                                          },
                                    child: Text(
                                      b.id == novel.activeBranchId
                                          ? '当前创作分支'
                                          : '切换到此分支',
                                    ),
                                  ),
                                  if (b.id != novel.activeBranchId)
                                    FButton(
                                      key: ValueKey('compare-${b.id}'),
                                      variant: FButtonVariant.ghost,
                                      size: FButtonSizeVariant.sm,
                                      mainAxisSize: MainAxisSize.min,
                                      onPress: () => Navigator.push(
                                        context,
                                        MaterialPageRoute<void>(
                                          builder: (_) =>
                                              BranchComparisonScreen(
                                                leftId: novel.activeBranchId,
                                                rightId: b.id,
                                              ),
                                        ),
                                      ),
                                      child: const Text('与当前分支比较'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text('从已有故事创建分支', style: heading),
                  const SizedBox(height: 16),
                  FSelect<String>.rich(
                    key: ValueKey('source:$source'),
                    label: const Text('依据分支'),
                    control: FSelectControl<String>.lifted(
                      value: source,
                      onChange: (v) => setState(() {
                        _source = v;
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
                    value: ref.watch(storyProvider(source)),
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
                        key: ValueKey('cutoff:$source:$_chapter'),
                        label: const Text('分叉位置'),
                        control: FSelectControl<String>.lifted(
                          value: _chapter ?? '',
                          onChange: (v) => setState(
                            () => _chapter = v == null || v.isEmpty ? null : v,
                          ),
                        ),
                        format: title,
                        children: [
                          FSelectItem<String>(
                            title: Text(title('')),
                            value: '',
                          ),
                          for (final s in story.chapters)
                            FSelectItem<String>(
                              title: Text(
                                title(s.id),
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: s.id,
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  FButton(
                    variant: FButtonVariant.outline,
                    onPress: () => _fork(source),
                    prefix: const Icon(FLucideIcons.gitFork),
                    child: const Text('创建独立分支'),
                  ),
                  const SizedBox(height: 24),
                  Text('探索故事的下一步', style: heading),
                  const SizedBox(height: 8),
                  const Text('根据所选分支的全部正文，提出多种可能。要从中途探索，先在该处分叉。'),
                  const SizedBox(height: 12),
                  FTile(
                    title: const Text('推演结局'),
                    subtitle: const Text('关闭时生成后续剧情走向'),
                    suffix: FSwitch(
                      value: _endings,
                      onChange: (v) => setState(() => _endings = v),
                    ),
                    onPress: () => setState(() => _endings = !_endings),
                  ),
                  const SizedBox(height: 16),
                  FSelect<int>(
                    label: const Text('候选数量'),
                    items: {for (var i = 2; i <= 6; i++) '$i 个': i},
                    control: FSelectControl<int>.lifted(
                      value: _count,
                      onChange: (v) {
                        if (v != null) setState(() => _count = v);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  FButton(
                    onPress: _busy ? null : () => _generate(source),
                    prefix: const Icon(FLucideIcons.sparkles),
                    child: Text(_busy ? '准备中…' : '生成候选走向'),
                  ),
                  const SizedBox(height: 24),
                  AsyncView(
                    value: ref.watch(tasksProvider(source)),
                    builder: _branchTasks,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  /// Earlier story-direction runs on the source branch.
  Widget _branchTasks(List<GenerationTask> all) {
    final tasks = all.where((t) => t.kind == TaskKind.branches).toList();
    if (tasks.isEmpty) return const SizedBox.shrink();
    return FTileGroup(
      children: [
        for (final task in tasks)
          FTile(
            title: Text('故事走向 · ${taskStatusLabels[task.status]}'),
            subtitle: Text(
              task.createdAt.toLocal().toString().substring(0, 16),
            ),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TaskScreen(taskId: task.id),
              ),
            ),
          ),
      ],
    );
  }
}
