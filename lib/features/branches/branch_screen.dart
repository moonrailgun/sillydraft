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
  String? _source, _scene;
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
        atSceneId: _scene,
      );
      await repo.setActiveBranch(branch.id);
      if (mounted) {
        setState(() {
          _source = branch.id;
          _scene = null;
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('故事分支')),
    body: AsyncView(
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
            for (final b in branches.where((b) => b.parentBranchId == parent)) {
              ordered.add(b);
              visit(b.id);
            }
          }

          visit(null);
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
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Icon(
                                b.id == novel.activeBranchId
                                    ? Icons.check_circle_outline
                                    : Icons.account_tree_outlined,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  b.name,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: '重命名分支',
                                onPressed: () async {
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
                                    if (context.mounted) showError(context, e);
                                  }
                                },
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            ],
                          ),
                          Text(
                            b.parentBranchId == null
                                ? '起始分支'
                                : '来自：${byId[b.parentBranchId]?.name ?? '原分支'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                key: ValueKey('activate-${b.id}'),
                                onPressed: b.id == novel.activeBranchId
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
                                TextButton(
                                  key: ValueKey('compare-${b.id}'),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => BranchComparisonScreen(
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
              Text('从已有故事创建分支', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('source:$source'),
                initialValue: source,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '依据分支'),
                items: [
                  for (final b in branches)
                    DropdownMenuItem(value: b.id, child: Text(b.name)),
                ],
                onChanged: (v) => setState(() {
                  _source = v;
                  _scene = null;
                }),
              ),
              const SizedBox(height: 16),
              AsyncView(
                value: ref.watch(storyProvider(source)),
                builder: (story) => DropdownButtonFormField<String>(
                  key: ValueKey('cutoff:$source:$_scene'),
                  initialValue: _scene,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '分叉位置'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('当前故事末尾'),
                    ),
                    for (final s in story.scenes)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(
                          s.title.isEmpty ? '未命名场景' : s.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _scene = v),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _fork(source),
                icon: const Icon(Icons.fork_right),
                label: const Text('创建独立分支'),
              ),
              const SizedBox(height: 24),
              Text('探索故事的下一步', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text('根据所选分支的全部正文，提出多种可能。要从中途探索，先在该处分叉。'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('推演结局'),
                subtitle: const Text('关闭时生成后续剧情走向'),
                value: _endings,
                onChanged: (v) => setState(() => _endings = v),
              ),
              DropdownButtonFormField<int>(
                initialValue: _count,
                decoration: const InputDecoration(labelText: '候选数量'),
                items: [
                  for (var i = 2; i <= 6; i++)
                    DropdownMenuItem(value: i, child: Text('$i 个')),
                ],
                onChanged: (v) => setState(() => _count = v!),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : () => _generate(source),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(_busy ? '准备中…' : '生成候选走向'),
              ),
              const SizedBox(height: 24),
              AsyncView(
                value: ref.watch(tasksProvider(source)),
                builder: (tasks) => Column(
                  children: [
                    for (final task in tasks.where(
                      (t) => t.kind == TaskKind.branches,
                    ))
                      ListTile(
                        title: Text('故事走向 · ${taskStatusLabels[task.status]}'),
                        subtitle: Text(
                          task.createdAt.toLocal().toString().substring(0, 16),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => TaskScreen(taskId: task.id),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
