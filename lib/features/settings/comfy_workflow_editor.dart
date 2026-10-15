import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

class ComfyWorkflowEditor extends StatefulWidget {
  const ComfyWorkflowEditor({
    super.key,
    this.initialValue,
    required this.serverUrl,
    required this.listWorkflows,
    required this.readWorkflow,
    required this.onChange,
    this.edit = false,
  });
  final ComfyWorkflow? initialValue;
  final String serverUrl;
  final Future<List<String>> Function() listWorkflows;
  final Future<Map<String, dynamic>> Function(String) readWorkflow;
  final ValueChanged<ComfyWorkflow?> onChange;

  /// The image-to-image workflow: at least one reference input, and nothing
  /// to choose is no workflow at all.
  final bool edit;
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
      _output = widget.initialValue?.outputNode ?? '';
  late List<String> _images = [...?widget.initialValue?.imageInputs];

  /// Keys apart for the two editors on one settings page.
  Key _key(String name) =>
      Key(widget.edit ? 'comfy-edit-$name' : 'comfy-$name');
  Object? _error;
  bool _loading = false;
  bool _advanced = false;
  int _request = 0;
  late String? _filename = widget.initialValue?.filename.isNotEmpty == true
      ? widget.initialValue!.filename
      : null;
  late List<String> _files = [?_filename];
  String? _serverMessage;

  @override
  void didUpdateWidget(covariant ComfyWorkflowEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverUrl != widget.serverUrl) {
      _request++;
      _loading = false;
      _files = [?_filename];
      _serverMessage = null;
    }
  }

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
          // The edit workflow keeps the model saved in it.
          modelInput: widget.edit ? '' : _model,
          imageInputs: _images,
          outputNode: _output,
          filename: _filename ?? '',
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
      if (_json.text.trim().isEmpty) {
        throw const FormatException('请先导入工作流文件，或粘贴 API 格式的 JSON');
      }
      final nodes = ComfyWorkflow.parseNodes(jsonDecode(_json.text));
      final outputs = <String>[];
      for (final entry in nodes.entries) {
        final node = entry.value as Map<String, dynamic>;
        if (node['class_type'] == 'SaveImage' ||
            node['class_type'] == 'PreviewImage') {
          outputs.add(entry.key);
        }
      }
      setState(() {
        _nodes = nodes;
        _prompt = '';
        _images = [];
        _model = '';
        _output = outputs.length == 1 ? outputs.single : '';
        _error = null;
        _changed();
      });
    } catch (e) {
      setState(() {
        _error = e is FormatException ? e.message : e;
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
      _filename = null;
      _read();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _fromServer([String? filename]) async {
    if (_loading) return;
    final request = ++_request;
    bool current() => mounted && request == _request;
    setState(() {
      _loading = true;
      _error = _serverMessage = null;
    });
    try {
      if (filename == null) {
        final files = await widget.listWorkflows();
        if (!current()) return;
        setState(() {
          _files = {...files, ?_filename}.toList()..sort();
          if (files.isEmpty) {
            _serverMessage = '服务端 workflows 目录中没有 JSON 工作流，可导入本地 API 文件。';
          }
        });
      } else {
        final nodes = await widget.readWorkflow(filename);
        if (!current()) return;
        _json.text = const JsonEncoder.withIndent('  ').convert(nodes);
        _filename = filename;
        _read();
      }
    } catch (e) {
      if (current()) {
        setState(() => _error = e is FormatException ? e.message : e);
      }
    } finally {
      if (current()) setState(() => _loading = false);
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
      enabled: !_loading,
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
    final inputs = <String, String>{},
        promptInputs = <String, String>{},
        outputs = <String, String>{};
    for (final entry in _nodes.entries) {
      final node = entry.value as Map<String, dynamic>;
      final title = node['_meta'] is Map ? node['_meta']['title'] : null;
      final label = '${entry.key} · ${title ?? node['class_type']}';
      outputs[entry.key] = label;
      for (final input in (node['inputs'] as Map).entries) {
        if (input.value is String) {
          final binding = '${entry.key}.${input.key}';
          final inputLabel = '$label · ${input.key}';
          inputs[binding] = inputLabel;
          // shortcut: common prompt names; advanced mode supports custom fields.
          if (_advanced ||
              const {
                'text',
                'prompt',
                'text_g',
                'text_l',
              }.contains(input.key) ||
              binding == _prompt) {
            promptInputs[binding] = inputLabel;
          }
        }
      }
    }
    return FormField<ComfyWorkflow>(
      key: _field,
      initialValue: widget.initialValue,
      validator: (value) => widget.edit
          ? (_nodes.isNotEmpty && value == null
                ? '请选择画面描述输入和图片输出节点'
                : value != null && value.imageInputs.isEmpty
                ? '图生图工作流须绑定至少一个参考图输入'
                : null)
          : value == null
          ? '请选择工作流、画面描述输入和图片输出节点'
          : null,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.edit
                ? '选择用于参考图生图的 ComfyUI 工作流，绑定画面描述和一到多个参考图输入。带参考图的插图会改用此工作流，参考图按顺序填入。'
                : '选择 ComfyUI 中保存的工作流，再指定画面描述和参考图输入。模型、尺寸和采样设置沿用工作流。',
          ),
          const SizedBox(height: 12),
          FButton(
            variant: FButtonVariant.outline,
            onPress: _loading ? null : () => _fromServer(),
            child: Text(_loading ? '正在读取…' : '获取服务端工作流'),
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 12),
            FSelect<String>.rich(
              key: _key('server-workflow'),
              enabled: !_loading,
              label: const Text('服务端工作流（选择后读取）'),
              hint: '选择文件名',
              control: FSelectControl.lifted(
                value: _filename,
                onChange: (name) {
                  if (name != null) _fromServer(name);
                },
              ),
              format: (name) => name,
              children: [
                for (final name in _files)
                  FSelectItem(value: name, title: Text(name)),
              ],
            ),
          ],
          if (_serverMessage != null) Text(_serverMessage!),
          if (_filename != null) const Text('新建生图任务时自动读取此文件的最新保存内容。'),
          if (_nodes.isNotEmpty) ...[
            _select(
              key: _key('prompt-input'),
              label: '画面描述输入',
              value: _prompt,
              options: promptInputs,
              onChange: (v) => _prompt = v,
            ),
            const Text('自定义提示词字段可展开高级设置后选择。'),
            for (final (i, binding) in _images.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '参考图输入 ${i + 1}：${inputs[binding] ?? binding}',
                      ),
                    ),
                    IconAction(
                      tooltip: '移除参考图输入',
                      icon: FLucideIcons.x,
                      onPress: () => setState(() {
                        _images = [..._images]..removeAt(i);
                        _changed();
                      }),
                    ),
                  ],
                ),
              ),
            _select(
              key: _key('image-input'),
              label: _images.isNotEmpty
                  ? '再添加一个参考图输入'
                  : widget.edit
                  ? '参考图输入'
                  : '参考图输入（可选）',
              value: '',
              options: {
                '': '请选择',
                for (final e in inputs.entries)
                  if (!_images.contains(e.key) && e.key != _prompt)
                    e.key: e.value,
              },
              onChange: (v) {
                if (v.isNotEmpty) _images = [..._images, v];
              },
            ),
            _select(
              label: '图片输出节点',
              value: _output,
              options: outputs,
              onChange: (v) => _output = v,
            ),
          ],
          FAccordion(
            control: FAccordionControl.lifted(
              expanded: (_) => _advanced,
              onChange: (_, expanded) => setState(() => _advanced = expanded),
            ),
            children: [
              FAccordionItem(
                title: const Text('高级设置'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    FTextField(
                      key: _key('workflow-json'),
                      enabled: !_loading,
                      label: const Text('API 工作流 JSON'),
                      minLines: 3,
                      maxLines: 6,
                      control: FTextFieldControl.managed(
                        controller: _json,
                        onChange: (_) {
                          setState(() {
                            _filename = null;
                            _nodes = {};
                            _prompt = _output = '';
                            _images = [];
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
                          onPress: _loading ? null : _import,
                          child: const Text('导入工作流'),
                        ),
                        FButton(
                          variant: FButtonVariant.outline,
                          mainAxisSize: MainAxisSize.min,
                          onPress: _loading ? null : _read,
                          child: const Text('解析 JSON'),
                        ),
                      ],
                    ),
                    if (_nodes.isNotEmpty && !widget.edit)
                      _select(
                        label: '模型输入（可选）',
                        value: _model,
                        options: {'': '沿用工作流中的模型', ...inputs},
                        onChange: (v) => _model = v,
                      ),
                  ],
                ),
              ),
            ],
          ),
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
