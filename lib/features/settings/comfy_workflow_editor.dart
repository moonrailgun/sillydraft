import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

class ComfyWorkflowEditor extends StatefulWidget {
  const ComfyWorkflowEditor({
    super.key,
    this.initialValue,
    required this.onChange,
  });
  final ComfyWorkflow? initialValue;
  final ValueChanged<ComfyWorkflow?> onChange;
  @override
  State<ComfyWorkflowEditor> createState() => _WorkflowState();
}

class _WorkflowState extends State<ComfyWorkflowEditor> {
  final _field = GlobalKey<FormFieldState<ComfyWorkflow>>();
  late final _json = TextEditingController(
    text: widget.initialValue == null
        ? ''
        : const JsonEncoder.withIndent('  ')
              .convert(widget.initialValue!.nodes),
  );
  late Map<String, dynamic> _nodes = widget.initialValue?.nodes ?? {};
  late String _prompt = widget.initialValue?.promptInput ?? '',
      _model = widget.initialValue?.modelInput ?? '',
      _image = widget.initialValue?.imageInput ?? '',
      _output = widget.initialValue?.outputNode ?? '';
  Object? _error;

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _changed() {
    ComfyWorkflow? value;
    if (_prompt.isNotEmpty && _output.isNotEmpty) {
      try {
        value = ComfyWorkflow(
          nodes: _nodes,
          promptInput: _prompt,
          modelInput: _model,
          imageInput: _image,
          outputNode: _output,
        );
        _error = null;
      } catch (e) {
        _error = e;
      }
    }
    _field.currentState!.didChange(value);
    widget.onChange(value);
  }

  void _read() {
    try {
      final nodes = ComfyWorkflow.parseNodes(jsonDecode(_json.text));
      final models = <String>[];
      final outputs = <String>[];
      for (final entry in nodes.entries) {
        final node = entry.value as Map<String, dynamic>;
        for (final input in (node['inputs'] as Map).entries) {
          if (['ckpt_name', 'unet_name'].contains(input.key) &&
              input.value is String) {
            models.add('${entry.key}.${input.key}');
          }
        }
        if (node['class_type'] == 'SaveImage' ||
            node['class_type'] == 'PreviewImage') {
          outputs.add(entry.key);
        }
      }
      setState(() {
        _nodes = nodes;
        _prompt = _image = '';
        _model = models.length == 1 ? models.single : '';
        _output = outputs.length == 1 ? outputs.single : '';
        _error = null;
        _changed();
      });
    } catch (e) {
      setState(() {
        _error = e;
        _nodes = {};
        _prompt = _output = '';
        _changed();
      });
    }
  }

  Future<void> _import() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'ComfyUI API 工作流',
            extensions: ['json'],
            uniformTypeIdentifiers: ['public.json'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 2 * 1024 * 1024) {
        throw const FormatException('工作流超过 2 MB');
      }
      final content = await file.readAsString();
      if (!mounted) return;
      _json.text = content;
      _read();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Widget _select({
    Key? key,
    required String label,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChange,
  }) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: FSelect<String>.rich(
      key: key,
      label: Text(label),
      hint: '请选择',
      control: FSelectControl.lifted(
        value: options.containsKey(value) ? value : null,
        onChange: (v) {
          if (v != null) {
            setState(() {
              onChange(v);
              _changed();
            });
          }
        },
      ),
      format: (v) => options[v] ?? v,
      children: [
        for (final e in options.entries)
          FSelectItem(value: e.key, title: Text(e.value)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final inputs = <String, String>{}, outputs = <String, String>{};
    for (final entry in _nodes.entries) {
      final node = entry.value as Map<String, dynamic>;
      final title = node['_meta'] is Map ? node['_meta']['title'] : null;
      final label = '${entry.key} · ${title ?? node['class_type']}';
      outputs[entry.key] = label;
      for (final input in (node['inputs'] as Map).entries) {
        if (input.value is String) {
          inputs['${entry.key}.${input.key}'] = '$label · ${input.key}';
        }
      }
    }
    return FormField<ComfyWorkflow>(
      key: _field,
      initialValue: widget.initialValue,
      validator: (value) => value == null ? '请读取 API 工作流并选择提示词和输出节点' : null,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('在 ComfyUI 中导出 API 格式工作流，再选择要替换的输入。尺寸、采样器等沿用工作流设置。'),
          const SizedBox(height: 12),
          FTextField(
            key: const Key('comfy-workflow-json'),
            label: const Text('API 工作流 JSON'),
            minLines: 3,
            maxLines: 6,
            control: FTextFieldControl.managed(
              controller: _json,
              onChange: (_) {
                setState(() {
                  _nodes = {};
                  _prompt = _output = '';
                  _error = null;
                  _changed();
                });
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FButton(
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _import,
                child: const Text('导入工作流'),
              ),
              FButton(
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _read,
                child: const Text('读取工作流'),
              ),
            ],
          ),
          if (_nodes.isNotEmpty) ...[
            _select(
              key: const Key('comfy-prompt-input'),
              label: '画面描述输入',
              value: _prompt,
              options: inputs,
              onChange: (v) => _prompt = v,
            ),
            _select(
              label: '模型输入（可选）',
              value: _model,
              options: {'': '沿用工作流中的模型', ...inputs},
              onChange: (v) => _model = v,
            ),
            _select(
              label: '参考图输入（可选）',
              value: _image,
              options: {'': '不使用参考图', ...inputs},
              onChange: (v) => _image = v,
            ),
            _select(
              label: '图片输出节点',
              value: _output,
              options: outputs,
              onChange: (v) => _output = v,
            ),
          ],
          if (_error != null || field.errorText != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${_error ?? field.errorText}',
                style: TextStyle(color: context.theme.colors.error),
              ),
            ),
        ],
      ),
    );
  }
}
