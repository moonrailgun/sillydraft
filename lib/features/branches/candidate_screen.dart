import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import '../editor/workspace_screen.dart';

final _candidateState =
    FutureProvider.family<({bool current, Map<int, String> chosen}), String>((
      ref,
      id,
    ) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider);
      return (
        current: await repo.taskSourcesCurrent(id),
        chosen: await repo.selectedCandidateBranches(id),
      );
    });

class CandidateScreen extends ConsumerStatefulWidget {
  const CandidateScreen({super.key, required this.taskId});
  final String taskId;
  @override
  ConsumerState<CandidateScreen> createState() => _CandidateState();
}

class _CandidateState extends ConsumerState<CandidateScreen> {
  bool _busy = false;
  Future<void> _choose(int index) async {
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .branchFromCandidate(taskId: widget.taskId, index: index);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('选择故事走向')),
    body: AsyncView(
      value: ref.watch(taskProvider(widget.taskId)),
      builder: (task) => AsyncView(
        value: ref.watch(_candidateState(task.id)),
        builder: (state) {
          final candidates = task.result['candidates'] as List? ?? [];
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('每个候选都是一种可能。选择后会复制当前故事，加入此候选开头，并将后续概要保留为创作计划。'),
              if (!state.current)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('候选依据的正文已变化，请根据最新正文重新生成后再选择。'),
                ),
              for (final (i, raw) in candidates.indexed) ...[
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          raw['title'] as String,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          raw['summary'] as String,
                          style: const TextStyle(height: 1.7),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '候选开头',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          raw['opening'] as String,
                          style: const TextStyle(height: 1.8),
                        ),
                        const SizedBox(height: 20),
                        if (state.chosen[i] == null)
                          FilledButton(
                            key: Key('choose-candidate-$i'),
                            onPressed: _busy || !state.current
                                ? null
                                : () => _choose(i),
                            child: const Text('采纳开头并创建分支'),
                          )
                        else
                          OutlinedButton(
                            onPressed: () async {
                              final repo = ref.read(repositoryProvider),
                                  branch = await repo.getBranch(
                                    state.chosen[i]!,
                                  );
                              await repo.setActiveBranch(branch.id);
                              if (context.mounted) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        NovelWorkspace(novelId: branch.novelId),
                                  ),
                                );
                              }
                            },
                            child: const Text('已创建分支 · 进入创作'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    ),
  );
}
