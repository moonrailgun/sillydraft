import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import 'lore_providers.dart';

final _evidenceProvider = FutureProvider.family<DocumentRevision, String>(
  (ref, id) => ref.watch(repositoryProvider).getRevision(id),
);

final _analysisState =
    FutureProvider.family<({bool current, Map<int, String> accepted}), String>((
      ref,
      id,
    ) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider);
      return (
        current: await repo.taskSourcesCurrent(id),
        accepted: await repo.acceptedAnalysisEntries(id),
      );
    });

class AnalysisReviewScreen extends ConsumerWidget {
  const AnalysisReviewScreen({super.key, required this.taskId});
  final String taskId;
  Future<void> _review(
    BuildContext context,
    WidgetRef ref,
    GenerationTask task,
    int index,
    Map<String, dynamic> suggestion,
  ) async {
    try {
      final entries = await ref
          .read(repositoryProvider)
          .listLore(
            task.branchId,
            throughSceneId: suggestion['sourceSceneId'] as String?,
          );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _ReviewDialog(
          taskId: task.id,
          index: index,
          suggestion: suggestion,
          entries: entries,
        ),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('审阅资料提取')),
    body: AsyncView(
      value: ref.watch(taskProvider(taskId)),
      builder: (task) => AsyncView(
        value: ref.watch(_analysisState(taskId)),
        builder: (state) {
          final entries = (task.result['entries'] as List? ?? [])
              .cast<Map<String, dynamic>>();
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('逐条核对依据和确定程度，再纳入当前分支。模型的推测不会自动成为事实。'),
              const SizedBox(height: 16),
              if (!state.current)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('正文已经变化，这次分析已过期。'),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: () async {
                            try {
                              final services = ref.read(servicesProvider),
                                  connection = await ref
                                      .read(servicesProvider)
                                      .connectionFor('analysis');
                              if (connection == null) {
                                throw const FormatException('请先配置整理模型');
                              }
                              final next = await services.writing.analyze(
                                branchId: task.branchId,
                                connection: connection,
                              );
                              if (context.mounted) {
                                Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => TaskScreen(taskId: next.id),
                                  ),
                                );
                              }
                            } catch (e) {
                              if (context.mounted) showError(context, e);
                            }
                          },
                          child: const Text('根据最新正文重新整理'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('这次分析没有可采纳的条目。'),
                ),
              for (final (i, entry) in entries.indexed)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            entry['name'] as String? ?? '未命名',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${loreLabels[LoreKind.values.where((e) => e.name == entry['kind']).firstOrNull] ?? entry['kind']} · ${certaintyLabels[LoreCertainty.values.where((e) => e.name == entry['certainty']).firstOrNull] ?? entry['certainty']}',
                          ),
                          const SizedBox(height: 12),
                          SelectableText(entry['content'] as String? ?? ''),
                          for (final source
                              in (task.input['sourceRevisions'] as List? ?? []))
                            if (source['sceneId'] == entry['sourceSceneId'])
                              ExpansionTile(
                                title: const Text('查看依据正文'),
                                children: [
                                  AsyncView(
                                    value: ref.watch(
                                      _evidenceProvider(
                                        source['revisionId'] as String,
                                      ),
                                    ),
                                    builder: (revision) => Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: SelectableText(
                                        revision.content.text,
                                        style: const TextStyle(height: 1.7),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                          const SizedBox(height: 16),
                          if (state.accepted.containsKey(i))
                            const Text('已采纳')
                          else
                            FilledButton.tonal(
                              onPressed: state.current
                                  ? () => _review(context, ref, task, i, entry)
                                  : null,
                              child: const Text('审阅并采纳'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _ReviewDialog extends ConsumerStatefulWidget {
  const _ReviewDialog({
    required this.taskId,
    required this.index,
    required this.suggestion,
    required this.entries,
  });
  final String taskId;
  final int index;
  final Map<String, dynamic> suggestion;
  final List<LoreEntry> entries;
  @override
  ConsumerState<_ReviewDialog> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<_ReviewDialog> {
  late final _name = TextEditingController(
        text: widget.suggestion['name'] as String?,
      ),
      _content = TextEditingController(
        text: widget.suggestion['content'] as String?,
      );
  late LoreCertainty _certainty =
      LoreCertainty.values
          .where((e) => e.name == widget.suggestion['certainty'])
          .firstOrNull ??
      LoreCertainty.inference;
  String? _target;
  late String? _from =
          (widget.suggestion['data'] as Map?)?['fromId'] as String?,
      _to = (widget.suggestion['data'] as Map?)?['toId'] as String?;
  late bool _directed =
      (widget.suggestion['data'] as Map?)?['directed'] != false;
  bool _busy = false;
  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(repositoryProvider)
          .acceptAnalysisEntry(
            taskId: widget.taskId,
            index: widget.index,
            targetEntityId: _target,
            expectedRevisionId: widget.entries
                .where((e) => e.id == _target)
                .firstOrNull
                ?.revisionId,
            name: _name.text,
            content: _content.text,
            certainty: _certainty,
            details: widget.suggestion['kind'] == 'relationship'
                ? {'fromId': _from, 'toId': _to, 'directed': _directed}
                : null,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final old = widget.entries.where((e) => e.id == _target).firstOrNull;
    return AlertDialog(
      title: const Text('确认资料内容'),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _target,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '更新目标'),
                hint: const Text('新建条目'),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('新建条目'),
                  ),
                  for (final e in widget.entries.where(
                    (e) =>
                        e.kind.name == widget.suggestion['kind'] &&
                        e.data['worldBookOnly'] != true,
                  ))
                    DropdownMenuItem(value: e.id, child: Text(e.name)),
                ],
                onChanged: (v) => setState(() => _target = v),
              ),
              const SizedBox(height: 16),
              if (old != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: SelectableText('当前内容：\n${old.content}'),
                ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _content,
                minLines: 4,
                maxLines: 10,
                decoration: const InputDecoration(labelText: '采纳的内容'),
              ),
              if (widget.suggestion['kind'] == 'relationship') ...[
                const SizedBox(height: 16),
                for (final endpoint in ['from', 'to'])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: DropdownButtonFormField<String>(
                      initialValue: endpoint == 'from' ? _from : _to,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: endpoint == 'from' ? '关系起点' : '关系终点',
                      ),
                      items: [
                        for (final e in widget.entries.where(
                          (e) => ![
                            LoreKind.relationship,
                            LoreKind.map,
                          ].contains(e.kind),
                        ))
                          DropdownMenuItem(value: e.id, child: Text(e.name)),
                      ],
                      onChanged: (v) => setState(() {
                        if (endpoint == 'from') {
                          _from = v;
                        } else {
                          _to = v;
                        }
                      }),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('有方向的关系'),
                  value: _directed,
                  onChanged: (v) => setState(() => _directed = v),
                ),
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<LoreCertainty>(
                initialValue: _certainty,
                decoration: const InputDecoration(labelText: '确定程度'),
                items: [
                  for (final e in certaintyLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _certainty = v!),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('采纳到资料'),
        ),
      ],
    );
  }
}
