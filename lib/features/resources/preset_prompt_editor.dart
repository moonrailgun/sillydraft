import 'dart:convert';

import 'package:flutter/material.dart';

/// Edits the original ST objects; identifiers and unrecognized fields survive.
class PresetPromptEditor extends StatefulWidget {
  const PresetPromptEditor({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final Map<String, dynamic> value;
  final ValueChanged<Map<String, dynamic>> onChanged;

  static bool supports(Map<String, dynamic> value) =>
      value['prompts'] is List ||
      (value['data'] is Map && (value['data'] as Map)['prompts'] is List);

  @override
  State<PresetPromptEditor> createState() => _PresetPromptState();
}

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
    final updated = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PromptDialog(prompt: prompt),
    );
    if (updated != null && mounted) _change(() => prompt.addAll(updated));
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    final ordered = [
      for (final item in order)
        for (final prompt in _prompts)
          if (prompt['identifier'] == item['identifier'])
            prompt as Map<String, dynamic>,
      for (final prompt in _prompts)
        if (!order.any((item) => item['identifier'] == prompt['identifier']))
          prompt as Map<String, dynamic>,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        if (!_pack && _groups.length > 1)
          DropdownButtonFormField<int>(
            initialValue: _group,
            decoration: const InputDecoration(labelText: '编辑顺序组'),
            isExpanded: true,
            items: [
              for (var i = 0; i < _groups.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    '${_groups[i]['character_id']}${_groups[i]['character_id'] == 100001 ? ' · 默认全局' : ''}',
                  ),
                ),
            ],
            onChanged: (value) => setState(() => _group = value!),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('开关与移动修改当前顺序组；条目内容由各组共享。动态标记在生成时填入正文、人物或世界书。'),
        ),
        for (final prompt in ordered)
          Builder(
            builder: (context) {
              final id = prompt['identifier'] as String;
              final index = order.indexWhere(
                (item) => item['identifier'] == id,
              );
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SwitchListTile(
                        key: Key('prompt-enabled-$id'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(prompt['name'] as String? ?? id),
                        subtitle: Text(
                          '$id · ${prompt['role'] ?? 'system'}${prompt['marker'] == true ? ' · 动态标记' : ''}',
                        ),
                        value: index >= 0 && order[index]['enabled'] == true,
                        onChanged: (enabled) => _change(() {
                          if (index < 0) {
                            order.add({'identifier': id, 'enabled': enabled});
                          } else {
                            order[index]['enabled'] = enabled;
                          }
                        }),
                      ),
                      if (prompt['injection_position'] == 1)
                        Text(
                          '深度 ${prompt['injection_depth'] ?? 4} · 注入优先级 ${prompt['injection_order'] ?? 100}',
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            key: Key('prompt-edit-$id'),
                            onPressed: () => _edit(prompt),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('编辑条目'),
                          ),
                          IconButton(
                            key: Key('prompt-up-$id'),
                            tooltip: '上移',
                            onPressed: index > 0
                                ? () => _change(() {
                                    final item = order.removeAt(index);
                                    order.insert(index - 1, item);
                                  })
                                : null,
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            key: Key('prompt-down-$id'),
                            tooltip: '下移',
                            onPressed: index >= 0 && index < order.length - 1
                                ? () => _change(() {
                                    final item = order.removeAt(index);
                                    order.insert(index + 1, item);
                                  })
                                : null,
                            icon: const Icon(Icons.arrow_downward),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        const Text('添加、删除条目或调整扩展配置时可切换到 JSON。保存为新版本后，再在作品写作配置中绑定。'),
      ],
    );
  }
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({required this.prompt});
  final Map<String, dynamic> prompt;
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('编辑提示词条目'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
                validator: (value) =>
                    value?.trim().isNotEmpty == true ? null : '请填写名称',
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '消息角色'),
                items: [
                  for (final role in {'system', 'user', 'assistant', _role})
                    DropdownMenuItem(value: role, child: Text(role)),
                ],
                onChanged: (value) => setState(() => _role = value!),
              ),
              const SizedBox(height: 12),
              if (widget.prompt['marker'] != true)
                TextFormField(
                  key: const Key('prompt-content'),
                  controller: _content,
                  minLines: 3,
                  maxLines: 8,
                  decoration: const InputDecoration(labelText: '提示词内容'),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _position,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '注入位置'),
                items: [
                  const DropdownMenuItem(value: 0, child: Text('按列表顺序')),
                  const DropdownMenuItem(value: 1, child: Text('故事历史中的深度')),
                  if (_position != 0 && _position != 1)
                    DropdownMenuItem(
                      value: _position,
                      child: Text('保留值 $_position'),
                    ),
                ],
                onChanged: (value) => setState(() => _position = value!),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('prompt-depth'),
                controller: _depth,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '注入深度'),
                validator: _number,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '同深度注入优先级'),
                validator: _number,
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('禁止角色卡覆盖'),
                value: _forbid,
                onChanged: (value) => setState(() => _forbid = value!),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
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
        child: const Text('应用条目修改'),
      ),
    ],
  );
  String? _number(String? value) =>
      (int.tryParse(value ?? '') ?? -1) >= 0 ? null : '请输入非负整数';
}
