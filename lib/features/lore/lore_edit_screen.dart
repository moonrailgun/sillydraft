import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import 'lore_providers.dart';
import '../resources/resource_library_screen.dart';

class LoreEditScreen extends ConsumerStatefulWidget {
  const LoreEditScreen({
    super.key,
    required this.branchId,
    this.entry,
    this.atSceneId,
    this.kind = LoreKind.world,
  });
  final String branchId;
  final LoreEntry? entry;
  final String? atSceneId;
  final LoreKind kind;
  @override
  ConsumerState<LoreEditScreen> createState() => _LoreEditState();
}

class _LoreEditState extends ConsumerState<LoreEditScreen> {
  late final _name = TextEditingController(text: widget.entry?.name),
      _content = TextEditingController(text: widget.entry?.content);
  late final _appearance = TextEditingController(
        text: widget.entry?.data['appearance'] as String?,
      ),
      _goal = TextEditingController(
        text: widget.entry?.data['goal'] as String?,
      ),
      _time = TextEditingController(
        text: widget.entry?.data['storyTime'] as String?,
      );
  late LoreKind _kind = widget.entry?.kind ?? widget.kind;
  late LoreCertainty _certainty = widget.entry?.certainty ?? LoreCertainty.fact;
  late String? _sceneId = widget.atSceneId ?? widget.entry?.atSceneId,
      _from = widget.entry?.data['fromId'] as String?,
      _to = widget.entry?.data['toId'] as String?;
  late String _status = widget.entry?.data['status'] as String? ?? 'active';
  late bool _directed = widget.entry?.data['directed'] != false;
  bool _busy = false, _rechecked = false;
  @override
  void dispose() {
    for (final c in [_name, _content, _appearance, _goal, _time]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool deleted = false}) async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider),
          provenance = widget.entry?.provenance ?? {'type': 'manual'};
      if (_rechecked && provenance['sceneId'] is String) {
        final source = await repo.getScene(
          branchId: widget.branchId,
          sceneId: provenance['sceneId'] as String,
        );
        provenance['revisionId'] = source.revisionId;
        provenance['reviewedAt'] = DateTime.now().toUtc().toIso8601String();
      }
      final entry = await repo.saveLoreEntry(
        branchId: widget.branchId,
        id: widget.entry?.id,
        expectedRevisionId: widget.entry?.revisionId,
        kind: _kind,
        name: _name.text,
        content: _content.text,
        certainty: _certainty,
        atSceneId: _sceneId,
        deleted: deleted,
        data: {
          ...?widget.entry?.data,
          'status': _status,
          if (_kind == LoreKind.character) 'appearance': _appearance.text,
          if (_kind == LoreKind.character) 'goal': _goal.text,
          if (_kind == LoreKind.event || _kind == LoreKind.foreshadow)
            'storyTime': _time.text,
          if (_kind == LoreKind.relationship) ...{
            'fromId': _from,
            'toId': _to,
            'directed': _directed,
          },
        },
        provenance: provenance,
      );
      if (mounted) Navigator.pop(context, entry);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reference = widget.entry;
    if (reference?.data['worldBookOnly'] == true) {
      return Scaffold(
        appBar: AppBar(title: Text(reference!.name)),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '此条是导入角色卡时的世界书快照。生成时由角色卡世界书按触发条件参与提示词，不会始终注入。要修改生成使用的内容，请编辑角色卡资源并在写作配置中选择新版本。',
            ),
            const SizedBox(height: 24),
            SelectableText(reference.content),
            const SizedBox(height: 24),
            if (reference.provenance['resourceId'] case final String id)
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ResourceDetailScreen(resourceId: id),
                  ),
                ),
                child: const Text('查看来源角色卡'),
              ),
          ],
        ),
      );
    }
    final story = ref.watch(storyProvider(widget.branchId));
    final entries =
        ref
            .watch(loreProvider((branchId: widget.branchId, sceneId: _sceneId)))
            .value ??
        [];
    Widget endpoint(
      String label,
      String? value,
      ValueChanged<String?> changed,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DropdownButtonFormField<String>(
        key: ValueKey('$label:$value'),
        initialValue: entries.any((e) => e.id == value && !e.deleted)
            ? value
            : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final e in entries.where(
            (e) =>
                !e.deleted &&
                e.kind != LoreKind.relationship &&
                e.kind != LoreKind.map,
          ))
            DropdownMenuItem(
              value: e.id,
              child: Text(e.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: changed,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry == null ? '添加旁路资料' : '编辑${loreLabels[_kind]}'),
        actions: [
          if (widget.entry != null && !widget.entry!.deleted)
            IconButton(
              tooltip: '移入资料归档',
              onPressed: _busy ? null : () => _save(deleted: true),
              icon: const Icon(Icons.archive_outlined),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.entry?.sourceStale == true) ...[
              const Text('正文依据已经变化。请对照原文复核此条资料。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('已对照最新正文复核'),
                value: _rechecked,
                onChanged: (v) => setState(() => _rechecked = v == true),
              ),
            ],
            if (widget.entry == null) ...[
              DropdownButtonFormField<LoreKind>(
                initialValue: _kind,
                decoration: const InputDecoration(labelText: '资料类型'),
                items: [
                  for (final e in loreLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _kind = v!),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const Key('lore-name'),
              controller: _name,
              decoration: InputDecoration(
                labelText: _kind == LoreKind.relationship
                    ? '关系类型，例如信任、敌对'
                    : '名称',
              ),
            ),
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
            const SizedBox(height: 16),
            AsyncView(
              value: story,
              builder: (story) => DropdownButtonFormField<String>(
                key: ValueKey('anchor:$_sceneId'),
                initialValue: story.scenes.any((s) => s.id == _sceneId)
                    ? _sceneId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '从哪个场景开始成立'),
                hint: const Text('当前故事末尾'),
                items: [
                  for (final s in story.scenes)
                    DropdownMenuItem(
                      value: s.id,
                      child: Text(s.title, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _sceneId = v),
              ),
            ),
            const SizedBox(height: 16),
            if (_kind == LoreKind.relationship) ...[
              endpoint('起点人物或组织', _from, (v) => setState(() => _from = v)),
              endpoint('终点人物或组织', _to, (v) => setState(() => _to = v)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('有方向的关系'),
                value: _directed,
                onChanged: (v) => setState(() => _directed = v),
              ),
            ],
            if (_kind == LoreKind.character) ...[
              TextField(
                controller: _appearance,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '外貌与辨识特征'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _goal,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '动机与目标'),
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.event || _kind == LoreKind.foreshadow) ...[
              TextField(
                controller: _time,
                decoration: const InputDecoration(
                  labelText: '故事内时间',
                  hintText: '例如：第三个雨夜',
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.foreshadow) ...[
              DropdownButtonFormField<String>(
                initialValue: loreStatusLabels.containsKey(_status)
                    ? _status
                    : 'active',
                decoration: const InputDecoration(labelText: '伏笔状态'),
                items: [
                  for (final e in loreStatusLabels.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => setState(() => _status = v!),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const Key('lore-content'),
              controller: _content,
              minLines: 6,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: '内容、依据与备注',
                alignLabelWithHint: true,
              ),
            ),
            if (widget.entry != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  '来源：${const {'manual': '手动整理', 'analysis': 'AI 建议，经作者采纳', 'card': '角色卡', 'candidate': '故事走向候选'}[widget.entry!.provenance['type']] ?? '导入资料'}${widget.entry!.provenance['sceneId'] == null ? '' : ' · 正文场景'}',
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : () => _save(),
              child: Text(
                _busy
                    ? '保存中…'
                    : widget.entry?.deleted == true
                    ? '恢复资料'
                    : '保存资料',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
