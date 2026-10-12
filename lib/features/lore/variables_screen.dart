import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

class VariablesScreen extends ConsumerStatefulWidget {
  const VariablesScreen({super.key, required this.branchId, this.sceneId});
  final String branchId;
  final String? sceneId;
  @override
  ConsumerState<VariablesScreen> createState() => _VariablesState();
}

class _VariablesState extends ConsumerState<VariablesScreen> {
  BranchVariables? _base;
  final _local = <String, String>{}, _global = <String, String>{};
  Object? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await ref
          .read(repositoryProvider)
          .getBranchVariables(widget.branchId, throughSceneId: widget.sceneId);
      if (mounted) {
        setState(() {
          _base = value;
          _local.addAll(value.local);
          _global.addAll(value.global);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _add(Map<String, String> values) async {
    final name = await askText(context, title: '新增变量', label: '变量名');
    if (name != null && mounted) {
      if (values.containsKey(name)) {
        showError(context, '变量已存在');
        return;
      }
      setState(() => values[name] = '');
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider),
          story = await ref.read(repositoryProvider).getStory(widget.branchId);
      final sceneId = widget.sceneId ?? story.scenes.lastOrNull?.id;
      if (sceneId == null) throw const FormatException('请先创建一个正文场景');
      await repo.setBranchVariables(
        branchId: widget.branchId,
        sceneId: sceneId,
        expectedVersion: _base!.version,
        local: _local,
        global: _global,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('当前故事位置的变量')),
    body: _error != null
        ? ErrorPane(message: _error.toString(), retry: _load)
        : _base == null
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('变量只属于当前分支，并按故事位置保存。预览提示词不会提交变量；采纳正文候选时才会提交模型产生的变化。'),
              const SizedBox(height: 20),
              for (final section in [
                ('局部变量 · getvar / setvar', _local),
                ('分支共享变量 · getglobalvar / setglobalvar', _global),
              ]) ...[
                Text(
                  section.$1,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                for (final entry in section.$2.entries.toList())
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            key: ValueKey('${section.$1}:${entry.key}'),
                            initialValue: entry.value,
                            decoration: InputDecoration(labelText: entry.key),
                            onChanged: (v) => section.$2[entry.key] = v,
                          ),
                        ),
                        IconButton(
                          tooltip: '删除变量 ${entry.key}',
                          onPressed: () =>
                              setState(() => section.$2.remove(entry.key)),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                TextButton.icon(
                  onPressed: () => _add(section.$2),
                  icon: const Icon(Icons.add),
                  label: const Text('新增变量'),
                ),
                const SizedBox(height: 24),
              ],
              FilledButton(
                onPressed: _busy ? null : _save,
                child: const Text('保存变量'),
              ),
            ],
          ),
  );
}
