import 'dart:convert';

import '../st/import_types.dart';

/// An API workflow and the inputs the author explicitly chose to replace.
final class ComfyWorkflow extends JsonSource {
  ComfyWorkflow({
    required Map<String, dynamic> nodes,
    required String promptInput,
    required String outputNode,
    String modelInput = '',
    String imageInput = '',
    String filename = '',
  }) : super({
         'nodes': nodes,
         'promptInput': promptInput,
         'modelInput': modelInput,
         'imageInput': imageInput,
         'outputNode': outputNode,
         if (filename.isNotEmpty) 'filename': filename,
       }) {
    parseNodes(nodes);
    if (promptInput.isEmpty || !nodes.containsKey(outputNode)) {
      throw const FormatException('请选择工作流的提示词输入和图片输出节点');
    }
    for (final binding in [promptInput, modelInput, imageInput]) {
      if (binding.isEmpty) continue;
      final (node, input) = splitInput(binding);
      if (nodes[node]?['inputs']?[input] is! String) {
        throw FormatException('工作流输入 $binding 不存在或不是文本字段');
      }
    }
    final bindings = [
      promptInput,
      modelInput,
      imageInput,
    ].where((b) => b.isNotEmpty);
    if (bindings.toSet().length != bindings.length) {
      throw const FormatException('提示词、模型和参考图须绑定不同的输入');
    }
  }

  factory ComfyWorkflow.fromJson(Map<String, dynamic> json) => ComfyWorkflow(
    nodes: jsonObject(json['nodes'], '工作流'),
    promptInput: stringField(json, 'promptInput'),
    modelInput: stringField(json, 'modelInput'),
    imageInput: stringField(json, 'imageInput'),
    outputNode: stringField(json, 'outputNode'),
    filename: stringField(json, 'filename'),
  );

  static Map<String, dynamic> parseNodes(Object? value) {
    final nodes = jsonObject(value, 'API 工作流');
    if (utf8.encode(jsonEncode(nodes)).length > 2 * 1024 * 1024) {
      throw const FormatException('工作流超过 2 MB');
    }
    if (nodes.length > 4096) {
      throw const FormatException('工作流超过 4096 个节点');
    }
    if (nodes.isEmpty ||
        nodes.values.any(
          (node) =>
              node is! Map<String, dynamic> ||
              node['class_type'] is! String ||
              (node['class_type'] as String).isEmpty ||
              node['inputs'] is! Map<String, dynamic>,
        )) {
      throw const FormatException(
        'JSON 不是 API 工作流；画布工作流请从服务端选择，或在 ComfyUI 中导出 API 格式',
      );
    }
    if (jsonEncode(nodes) != jsonEncode(redactCredentials(nodes))) {
      throw const FormatException('工作流包含密钥，请移除密钥后再导入');
    }
    return nodes;
  }

  /// Standard core widgets follow ComfyUI's object_info input order.
  /// See Comfy-Org/workflow_templates scripts/comfyui_node_compat/workflow.py.
  static Map<String, dynamic> parseCanvas(
    Map<String, dynamic> canvas,
    Map<String, dynamic> definitions,
  ) {
    Never invalid(String reason) =>
        throw FormatException('$reason；请在 ComfyUI 中导出 API 格式，再通过高级设置导入');
    if (utf8.encode(jsonEncode(canvas)).length > 2 * 1024 * 1024) {
      throw const FormatException('工作流超过 2 MB');
    }
    final nodes = canvas['nodes'], links = canvas['links'];
    if (nodes is! List || nodes.isEmpty || links is! List) {
      invalid('画布工作流缺少节点或连线');
    }
    if (nodes.length > 4096) {
      throw const FormatException('工作流超过 4096 个节点');
    }
    final byId = <String, Map>{}, byLink = <Object, List>{};
    for (final node in nodes) {
      if (node is! Map ||
          (node['id'] is! int && node['id'] is! String) ||
          byId.containsKey('${node['id']}')) {
        invalid('画布节点标识无效或重复');
      }
      byId['${node['id']}'] = node;
    }
    for (final link in links) {
      if (link is! List ||
          link.length < 6 ||
          (link[0] is! int && link[0] is! String) ||
          byLink.containsKey(link[0])) {
        invalid('画布连线格式无效');
      }
      byLink[link[0] as Object] = link;
    }
    const notes = {'Note', 'MarkdownNote'};
    final result = <String, dynamic>{};
    for (final entry in byId.entries) {
      final node = entry.value, type = node['type'];
      if (notes.contains(type)) continue;
      if ((node['mode'] ?? 0) != 0) {
        invalid('节点 ${entry.key} 使用了暂不支持的禁用或绕过模式');
      }
      final definition = definitions[type];
      final module = definition is Map ? definition['python_module'] : null;
      if (module is! String ||
          !(module == 'nodes' || module.startsWith('comfy_extras.'))) {
        invalid('节点 ${entry.key}（$type）未安装或需要自定义前端转换');
      }
      final specification = definition['input'];
      if (specification is! Map) invalid('节点 $type 的输入定义无效');
      final sockets = node['inputs'] ?? const <dynamic>[];
      if (sockets is! List ||
          sockets.any((s) => s is! Map || s['name'] is! String)) {
        invalid('节点 $type 的输入端口无效');
      }
      final inputs = <String, dynamic>{};
      for (var slot = 0; slot < sockets.length; slot++) {
        final socket = sockets[slot] as Map, linkId = socket['link'];
        if (linkId == null) continue;
        final link = byLink[linkId];
        if (link == null ||
            '${link[3]}' != entry.key ||
            link[4] != slot ||
            !byId.containsKey('${link[1]}') ||
            notes.contains(byId['${link[1]}']!['type']) ||
            link[2] is! int ||
            (link[2] as int) < 0) {
          invalid('节点 ${entry.key} 的连线缺失或无效');
        }
        inputs[socket['name'] as String] = ['${link[1]}', link[2]];
      }
      final named = node['widgets_values_named'];
      final values = node['widgets_values'] ?? const <dynamic>[];
      if ((named != null && named is! Map) || values is! List) {
        invalid('节点 $type 的控件值格式无效');
      }
      var cursor = 0;
      final order = definition['input_order'];
      for (final group in ['required', 'optional']) {
        final fields = specification[group] ?? const <String, dynamic>{};
        if (fields is! Map) invalid('节点 $type 的输入定义无效');
        final names =
            (order is Map ? order[group] : null) ?? fields.keys.toList();
        if (names is! List ||
            names.toSet().length != fields.length ||
            !names.every(fields.containsKey)) {
          invalid('节点 $type 的控件顺序无效');
        }
        for (final name in names) {
          final spec = fields[name];
          if (name is! String || spec is! List || spec.isEmpty) {
            invalid('节点 $type 的输入定义无效');
          }
          final kind = spec.first;
          final options = spec.length > 1 && spec[1] is Map
              ? spec[1] as Map
              : const <String, dynamic>{};
          final widget =
              kind is List ||
              const {
                'STRING',
                'INT',
                'FLOAT',
                'BOOLEAN',
                'COMBO',
              }.contains(kind);
          final linked = inputs.containsKey(name);
          if (!widget || options['forceInput'] == true) {
            if (!linked && group == 'required' && kind != 'COMFY_AUTOGROW_V3') {
              invalid('节点 ${entry.key} 缺少输入 $name');
            }
            continue;
          }
          final hasWidget = sockets.any(
            (s) => s['name'] == name && s['widget'] is Map,
          );
          if (linked && !hasWidget) continue;
          Object? value;
          if (named is Map) {
            if (!named.containsKey(name)) {
              if (linked || group == 'optional') continue;
              invalid('节点 ${entry.key} 缺少控件 $name');
            }
            value = named[name];
          } else {
            if (cursor >= values.length) {
              if (group == 'optional') continue;
              invalid('节点 ${entry.key} 缺少控件 $name');
            }
            value = values[cursor++];
            if (options['control_after_generate'] != null &&
                options['control_after_generate'] != false &&
                cursor < values.length &&
                const {
                  'fixed',
                  'increment',
                  'decrement',
                  'randomize',
                }.contains(values[cursor])) {
              cursor++;
            }
          }
          final valid =
              kind is List ||
                  (kind == 'COMBO' &&
                      options['options'] is List &&
                      options['multiselect'] != true)
              ? value is String || value is num || value is bool
              : switch (kind) {
                  'STRING' => value is String,
                  'INT' => value is int,
                  'FLOAT' => value is num,
                  'BOOLEAN' => value is bool,
                  _ => false,
                };
          if (!valid) invalid('节点 ${entry.key} 的控件 $name 无法可靠转换');
          if (!linked) inputs[name] = value;
        }
      }
      if (named == null &&
          cursor != values.length &&
          !(type == 'LoadImage' &&
              cursor + 1 == values.length &&
              values.last == 'image')) {
        invalid('节点 ${entry.key} 包含无法识别的额外控件');
      }
      result[entry.key] = {
        'class_type': type,
        'inputs': inputs,
        if (node['title'] is String) '_meta': {'title': node['title']},
      };
    }
    return parseNodes(result);
  }

  static (String, String) splitInput(String binding) {
    final dot = binding.lastIndexOf('.');
    if (dot <= 0 || dot == binding.length - 1) {
      throw const FormatException('工作流绑定须为 节点ID.输入名称');
    }
    return (binding.substring(0, dot), binding.substring(dot + 1));
  }

  Map<String, dynamic> get nodes => raw['nodes'] as Map<String, dynamic>;
  String get promptInput => raw['promptInput'] as String;
  String get modelInput => raw['modelInput'] as String;
  String get imageInput => raw['imageInput'] as String;
  String get outputNode => raw['outputNode'] as String;
  String get filename => raw['filename'] as String? ?? '';

  void setInput(Map<String, dynamic> nodes, String binding, String value) {
    final (node, input) = splitInput(binding);
    nodes[node]['inputs'][input] = value;
  }
}
