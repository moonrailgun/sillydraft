import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart' show ReorderableListView;
import 'package:flutter/widgets.dart';

import '../../app/widgets.dart';

/// ST's Prompt Manager: toggle, drag to reorder, edit, add and delete prompt
/// entries. Edits the original ST objects; identifiers and unrecognized fields
/// survive.
class PresetPromptEditor extends StatefulWidget {
  const PresetPromptEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.scrollable = true,
  });
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;

  /// False when placed inside another scroll view, such as the preset panel.
  final bool scrollable;

  static bool supports(Map<String, dynamic> value) =>
      value['prompts'] is List ||
      (value['data'] is Map && (value['data'] as Map)['prompts'] is List);

  @override
  State<PresetPromptEditor> createState() => _PresetPromptState();
}

/// Entries ST itself defines; they can be switched off but not deleted.
const _builtIn = {
  'main',
  'nsfw',
  'jailbreak',
  'enhanceDefinitions',
  'worldInfoBefore',
  'worldInfoAfter',
  'charDescription',
  'charPersonality',
  'scenario',
  'personaDescription',
  'dialogueExamples',
  'chatHistory',
};

class _PresetPromptState extends State<PresetPromptEditor> {
  late final Map<String, dynamic> _root =
      jsonDecode(jsonEncode(widget.value)) as Map<String, dynamic>;
  late final Map<String, dynamic> _body = _root['prompts'] is List
      ? _root
      : _root['data'] as Map<String, dynamic>;
  late final bool _pack = !identical(_root, _body);
  late final List<dynamic> _prompts = _body['prompts'] as List;
  late final List<dynamic> _groups = _pack
      ? []
      : (_body['prompt_order'] as List? ?? []);
  late int _group =
      _groups.indexWhere((g) => (g as Map)['character_id'] == 100001) < 0
      ? 0
      : _groups.indexWhere((g) => (g as Map)['character_id'] == 100001);
  List<dynamic> get _order {
    if (_pack) return _body.putIfAbsent('prompt_order', _defaultOrder) as List;
    if (_groups.isEmpty) {
      _groups.add({'character_id': 100001, 'order': _defaultOrder()});
    }
    _body['prompt_order'] = _groups;
    return (_groups[_group] as Map).putIfAbsent('order', _defaultOrder) as List;
  }

  List<dynamic> _defaultOrder() => [
    for (final p in _prompts) {'identifier': p['identifier'], 'enabled': true},
  ];
  void _change(VoidCallback action) {
    setState(action);
    widget.onChanged(jsonDecode(jsonEncode(_root)) as Map<String, dynamic>);
  }

  Future<void> _edit(Map<String, dynamic> prompt) async {
    final updated = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PromptDialog(prompt: prompt),
    );
    if (updated != null && mounted) _change(() => prompt.addAll(updated));
  }

  Future<void> _add() async {
    final random = Random.secure();
    final id = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    final prompt = <String, dynamic>{
      'identifier': id,
      'name': '新条目',
      'role': 'system',
      'content': '',
      'system_prompt': false,
      'marker': false,
      'injection_position': 0,
      'injection_depth': 4,
      'injection_order': 100,
      'forbid_overrides': false,
    };
    final updated = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PromptDialog(prompt: prompt, creating: true),
    );
    if (updated == null || !mounted) return;
    _change(() {
      _prompts.add(prompt..addAll(updated));
      _order.add({'identifier': id, 'enabled': true});
    });
  }

  Future<void> _delete(Map<String, dynamic> prompt) async {
    final yes = await confirmAction(
      context,
      title: '删除条目「${prompt['name'] ?? prompt['identifier']}」？',
      message: '条目会从所有顺序组中移除。保存前可以还原。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!yes || !mounted) return;
    final id = prompt['identifier'];
    _change(() {
      _prompts.remove(prompt);
      for (final group in _pack ? [_body] : _groups) {
        ((group as Map)[_pack ? 'prompt_order' : 'order'] as List?)
            ?.removeWhere((item) => (item as Map)['identifier'] == id);
      }
    });
  }

  /// Entries in the current order, then any not yet placed in it.
  List<Map<String, dynamic>> _ordered(List<dynamic> order) => [
    for (final item in order)
      for (final prompt in _prompts)
        if (prompt['identifier'] == item['identifier'])
          prompt as Map<String, dynamic>,
    for (final prompt in _prompts)
      if (!order.any((item) => item['identifier'] == prompt['identifier']))
        prompt as Map<String, dynamic>,
  ];

  /// Moves the entry at [from] so it ends up at index [to].
  void _move(List<dynamic> order, int from, int to) => _change(() {
    final sequence = _ordered(order).map((p) => p['identifier']).toList();
    final moved = sequence.removeAt(from);
    sequence.insert(to, moved);
    final items = {for (final item in order) item['identifier']: item};
    order
      ..clear()
      ..addAll([
        for (final id in sequence)
          if (items[id] != null)
            items[id]
          else if (id == moved)
            {'identifier': id, 'enabled': false},
      ]);
  });

  Widget _tile(Map<String, dynamic> prompt, List<dynamic> order, int row) {
    final id = prompt['identifier'] as String;
    final index = order.indexWhere((item) => item['identifier'] == id);
    final marker = prompt['marker'] == true;
    final enabled = index >= 0 && order[index]['enabled'] == true;
    void toggle(bool enabled) => _change(() {
      if (index < 0) {
        order.add({'identifier': id, 'enabled': enabled});
      } else {
        order[index]['enabled'] = enabled;
      }
    });
    final theme = context.theme;
    final tile = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ReorderableDragStartListener(
                    index: row,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        FLucideIcons.gripVertical,
                        size: 18,
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                  Expanded(
                    // The whole row toggles, not only the switch and texts.
                    child: GestureDetector(
                      key: Key('prompt-enabled-$id'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => toggle(!enabled),
                      child: FSwitch(
                        leadingLabel: true,
                        label: Text.rich(
                          TextSpan(
                            text: prompt['name'] as String? ?? id,
                            children: [
                              TextSpan(
                                text:
                                    '  $id · ${prompt['role'] ?? 'system'}${marker ? ' · 动态标记' : ''}'
                                    '${prompt['injection_position'] == 1 ? ' · 深度 ${prompt['injection_depth'] ?? 4}' : ''}',
                                style: theme.typography.body.sm.copyWith(
                                  color: theme.colors.mutedForeground,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: enabled,
                        onChange: toggle,
                      ),
                    ),
                  ),
                ],
              ),
              if (!marker && (prompt['content'] as String? ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(40, 6, 8, 4),
                  child: Text(
                    prompt['content'] as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.typography.body.sm.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 4),
                child: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FButton(
                      key: Key('prompt-edit-$id'),
                      variant: FButtonVariant.ghost,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => _edit(prompt),
                      prefix: const Icon(FLucideIcons.pencil),
                      child: const Text('编辑条目'),
                    ),
                    IconAction(
                      key: Key('prompt-up-$id'),
                      tooltip: '上移',
                      onPress: row > 0
                          ? () => _move(order, row, row - 1)
                          : null,
                      icon: FLucideIcons.arrowUp,
                    ),
                    IconAction(
                      key: Key('prompt-down-$id'),
                      tooltip: '下移',
                      onPress: row < _prompts.length - 1
                          ? () => _move(order, row, row + 1)
                          : null,
                      icon: FLucideIcons.arrowDown,
                    ),
                    if (!_builtIn.contains(id) && !marker)
                      IconAction(
                        key: Key('prompt-delete-$id'),
                        tooltip: '删除条目',
                        onPress: () => _delete(prompt),
                        icon: FLucideIcons.trash2,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Opacity(
      key: ValueKey('prompt-$id'),
      opacity: enabled ? 1 : theme.colors.disabledOpacity,
      child: tile,
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final ordered = _ordered(order);
    String groupLabel(int i) =>
        '${_groups[i]['character_id']}${_groups[i]['character_id'] == 100001 ? ' · 默认全局' : ''}';
    final header = [
      if (!_pack && _groups.length > 1)
        FSelect<int>.rich(
          label: const Text('编辑顺序组'),
          format: groupLabel,
          control: FSelectControl<int>.lifted(
            value: _group,
            onChange: (value) {
              if (value != null) setState(() => _group = value);
            },
          ),
          children: [
            for (var i = 0; i < _groups.length; i++)
              FSelectItem<int>(title: Text(groupLabel(i)), value: i),
          ],
        ),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('拖动或用箭头调整顺序；开关与顺序作用于当前顺序组，条目内容由各组共享。动态标记在生成时填入正文、人物或世界书。'),
      ),
    ];
    final list = ReorderableListView(
      shrinkWrap: !widget.scrollable,
      physics: widget.scrollable ? null : const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      padding: widget.scrollable
          ? const EdgeInsets.fromLTRB(16, 0, 16, 32)
          : EdgeInsets.zero,
      // The lifted entry casts a soft shadow instead of Material elevation.
      proxyDecorator: (child, _, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: context.theme.style.borderRadius.lg,
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: child,
      ),
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: header,
      ),
      footer: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FButton(
            key: const Key('prompt-add'),
            variant: FButtonVariant.outline,
            mainAxisSize: MainAxisSize.min,
            onPress: _add,
            prefix: const Icon(FLucideIcons.plus),
            child: const Text('新增条目'),
          ),
        ),
      ),
      onReorderItem: (from, to) => _move(order, from, to),
      children: [
        for (final (row, prompt) in ordered.indexed) _tile(prompt, order, row),
      ],
    );
    return list;
  }
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.prompt, this.creating = false});
  final Map<String, dynamic> prompt;
  final bool creating;
  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text:
        widget.prompt['name'] as String? ??
        widget.prompt['identifier'] as String,
  );
  late final _content = TextEditingController(
    text: widget.prompt['content'] as String? ?? '',
  );
  late final _depth = TextEditingController(
    text: '${widget.prompt['injection_depth'] ?? 4}',
  );
  late final _order = TextEditingController(
    text: '${widget.prompt['injection_order'] ?? 100}',
  );
  late String _role = widget.prompt['role'] as String? ?? 'system';
  late int _position = widget.prompt['injection_position'] as int? ?? 0;
  late bool _forbid = widget.prompt['forbid_overrides'] == true;
  @override
  void dispose() {
    for (final c in [_name, _content, _depth, _order]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    maxWidth: 600,
    title: Text(widget.creating ? '新增提示词条目' : '编辑提示词条目'),
    body: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTextFormField(
            control: FTextFieldControl.managed(controller: _name),
            label: const Text('名称'),
            validator: (value) =>
                value?.trim().isNotEmpty == true ? null : '请填写名称',
          ),
          const SizedBox(height: 12),
          FSelect<String>(
            label: const Text('消息角色'),
            items: {
              for (final role in {'system', 'user', 'assistant', _role})
                role: role,
            },
            control: FSelectControl<String>.lifted(
              value: _role,
              onChange: (value) {
                if (value != null) setState(() => _role = value);
              },
            ),
          ),
          const SizedBox(height: 12),
          if (widget.prompt['marker'] != true) ...[
            FTextFormField(
              key: const Key('prompt-content'),
              control: FTextFieldControl.managed(controller: _content),
              minLines: 3,
              maxLines: 12,
              label: const Text('提示词内容'),
              description: const Text('支持 {{char}}、{{user}} 等宏'),
            ),
            const SizedBox(height: 12),
          ],
          FSelect<int>.rich(
            label: const Text('注入位置'),
            format: _positionLabel,
            control: FSelectControl<int>.lifted(
              value: _position,
              onChange: (value) {
                if (value != null) setState(() => _position = value);
              },
            ),
            children: [
              for (final position in {0, 1, _position})
                FSelectItem<int>(
                  title: Text(_positionLabel(position)),
                  value: position,
                ),
            ],
          ),
          const SizedBox(height: 12),
          FTextFormField(
            key: const Key('prompt-depth'),
            control: FTextFieldControl.managed(controller: _depth),
            keyboardType: TextInputType.number,
            label: const Text('注入深度'),
            validator: _number,
          ),
          const SizedBox(height: 12),
          FTextFormField(
            control: FTextFieldControl.managed(controller: _order),
            keyboardType: TextInputType.number,
            label: const Text('同深度注入优先级'),
            validator: _number,
          ),
          const SizedBox(height: 16),
          FCheckbox(
            label: const Text('禁止角色卡覆盖'),
            value: _forbid,
            onChange: (value) => setState(() => _forbid = value),
          ),
        ],
      ),
    ),
    actions: [
      FButton(
        variant: FButtonVariant.outline,
        onPress: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FButton(
        onPress: () {
          if (!_form.currentState!.validate()) return;
          Navigator.pop(context, {
            'name': _name.text.trim(),
            'content': _content.text,
            'role': _role,
            'injection_position': _position,
            'injection_depth': int.parse(_depth.text),
            'injection_order': int.parse(_order.text),
            'forbid_overrides': _forbid,
          });
        },
        child: Text(widget.creating ? '添加条目' : '应用条目修改'),
      ),
    ],
  );

  static String _positionLabel(int position) => switch (position) {
    0 => '按列表顺序',
    1 => '故事历史中的深度',
    _ => '保留值 $position',
  };

  String? _number(String? value) =>
      (int.tryParse(value ?? '') ?? -1) >= 0 ? null : '请输入非负整数';
}
