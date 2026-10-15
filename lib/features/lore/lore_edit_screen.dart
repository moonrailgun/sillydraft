import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/widgets.dart';
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
    this.atChapterId,
    this.kind = LoreKind.world,
  });
  final String branchId;
  final LoreEntry? entry;
  final String? atChapterId;
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
  late String? _chapterId = widget.atChapterId ?? widget.entry?.atChapterId,
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
      final repo = ref.read(repositoryProvider);
      var provenance = widget.entry?.provenance ?? {'type': 'manual'};
      if (_rechecked && provenance['chapterId'] is String) {
        final source = await repo.getChapter(
          branchId: widget.branchId,
          chapterId: provenance['chapterId'] as String,
        );
        provenance['revisionId'] = source.revisionId;
        provenance['reviewedAt'] = DateTime.now().toUtc().toIso8601String();
      } else if (provenance['type'] == 'sidecar') {
        // The author's edit makes the note theirs: the sidecar no longer
        // redoes it, and it never goes stale with the chapter.
        provenance = {'type': 'manual'};
      }
      final entry = await repo.saveLoreEntry(
        branchId: widget.branchId,
        id: widget.entry?.id,
        expectedRevisionId: widget.entry?.revisionId,
        kind: _kind,
        name: _name.text,
        content: _content.text,
        certainty: _certainty,
        atChapterId: _chapterId,
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
      return PageScaffold(
        title: reference!.name,
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
              FButton(
                variant: FButtonVariant.outline,
                onPress: () => Navigator.push(
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
            .watch(
              loreProvider((branchId: widget.branchId, chapterId: _chapterId)),
            )
            .value ??
        [];
    Widget endpoint(
      String label,
      String? value,
      ValueChanged<String?> changed,
    ) {
      final options = entries
          .where(
            (e) =>
                !e.deleted &&
                e.kind != LoreKind.relationship &&
                e.kind != LoreKind.map,
          )
          .toList();
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: FSelect<String>.rich(
          key: ValueKey('$label:$value'),
          label: Text(label),
          control: FSelectControl<String>.lifted(
            value: entries.any((e) => e.id == value && !e.deleted)
                ? value
                : null,
            onChange: changed,
          ),
          format: (id) =>
              options.where((e) => e.id == id).firstOrNull?.name ?? '',
          children: [
            for (final e in options)
              FSelectItem<String>(
                title: Text(e.name, overflow: TextOverflow.ellipsis),
                value: e.id,
              ),
          ],
        ),
      );
    }

    return PageScaffold(
      title: widget.entry == null ? '添加旁路资料' : '编辑${loreLabels[_kind]}',
      actions: [
        if (widget.entry != null && !widget.entry!.deleted)
          HeaderIconAction(
            icon: FLucideIcons.archive,
            tooltip: '移入资料归档',
            onPress: _busy ? null : () => _save(deleted: true),
          ),
      ],
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.entry?.sourceStale == true) ...[
              const Text('正文依据已经变化。请对照原文复核此条资料。'),
              const SizedBox(height: 12),
              FCheckbox(
                label: const Text('已对照最新正文复核'),
                value: _rechecked,
                onChange: (v) => setState(() => _rechecked = v),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.entry == null) ...[
              FSelect<LoreKind>(
                label: const Text('资料类型'),
                items: {for (final e in loreLabels.entries) e.value: e.key},
                control: FSelectControl<LoreKind>.lifted(
                  value: _kind,
                  onChange: (v) {
                    if (v != null) setState(() => _kind = v);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            FTextField(
              key: const Key('lore-name'),
              control: FTextFieldControl.managed(controller: _name),
              label: Text(
                _kind == LoreKind.relationship ? '关系类型，例如信任、敌对' : '名称',
              ),
            ),
            const SizedBox(height: 16),
            FSelect<LoreCertainty>(
              label: const Text('确定程度'),
              items: {for (final e in certaintyLabels.entries) e.value: e.key},
              control: FSelectControl<LoreCertainty>.lifted(
                value: _certainty,
                onChange: (v) {
                  if (v != null) setState(() => _certainty = v);
                },
              ),
            ),
            const SizedBox(height: 16),
            AsyncView(
              value: story,
              builder: (story) => FSelect<String>.rich(
                key: ValueKey('anchor:$_chapterId'),
                label: const Text('从哪个章节开始成立'),
                hint: '当前故事末尾',
                control: FSelectControl<String>.lifted(
                  value: story.chapters.any((s) => s.id == _chapterId)
                      ? _chapterId
                      : null,
                  onChange: (v) => setState(() => _chapterId = v),
                ),
                format: (id) =>
                    story.chapters
                        .where((s) => s.id == id)
                        .firstOrNull
                        ?.title ??
                    '',
                children: [
                  for (final s in story.chapters)
                    FSelectItem<String>(
                      title: Text(s.title, overflow: TextOverflow.ellipsis),
                      value: s.id,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_kind == LoreKind.relationship) ...[
              endpoint('起点人物或组织', _from, (v) => setState(() => _from = v)),
              endpoint('终点人物或组织', _to, (v) => setState(() => _to = v)),
              FSwitch(
                label: const Text('有方向的关系'),
                value: _directed,
                onChange: (v) => setState(() => _directed = v),
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.character) ...[
              FTextField(
                control: FTextFieldControl.managed(controller: _appearance),
                minLines: 1,
                maxLines: 3,
                label: const Text('外貌与辨识特征'),
              ),
              const SizedBox(height: 16),
              FTextField(
                control: FTextFieldControl.managed(controller: _goal),
                minLines: 1,
                maxLines: 3,
                label: const Text('动机与目标'),
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.event || _kind == LoreKind.foreshadow) ...[
              FTextField(
                control: FTextFieldControl.managed(controller: _time),
                label: const Text('故事内时间'),
                hint: '例如：第三个雨夜',
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.foreshadow) ...[
              FSelect<String>(
                label: const Text('伏笔状态'),
                items: {
                  for (final e in loreStatusLabels.entries) e.value: e.key,
                },
                control: FSelectControl<String>.lifted(
                  value: loreStatusLabels.containsKey(_status)
                      ? _status
                      : 'active',
                  onChange: (v) {
                    if (v != null) setState(() => _status = v);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            FTextField(
              key: const Key('lore-content'),
              control: FTextFieldControl.managed(controller: _content),
              minLines: 6,
              maxLines: 14,
              label: const Text('内容、依据与备注'),
            ),
            if (widget.entry != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  '来源：${const {'manual': '手动整理', 'analysis': 'AI 建议，经作者采纳', 'card': '角色卡', 'candidate': '故事走向候选'}[widget.entry!.provenance['type']] ?? '导入资料'}${widget.entry!.provenance['chapterId'] == null ? '' : ' · 正文章节'}',
                ),
              ),
            const SizedBox(height: 24),
            FButton(
              onPress: _busy ? null : () => _save(),
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
