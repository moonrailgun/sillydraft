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
  }) : super({
         'nodes': nodes,
         'promptInput': promptInput,
         'modelInput': modelInput,
         'imageInput': imageInput,
         'outputNode': outputNode,
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
  );

  static Map<String, dynamic> parseNodes(Object? value) {
    final nodes = jsonObject(value, 'API 工作流');
    if (nodes.isEmpty ||
        nodes.length > 4096 ||
        utf8.encode(jsonEncode(nodes)).length > 2 * 1024 * 1024 ||
        nodes.values.any(
          (node) =>
              node is! Map<String, dynamic> ||
              node['class_type'] is! String ||
              (node['class_type'] as String).isEmpty ||
              node['inputs'] is! Map<String, dynamic>,
        )) {
      throw const FormatException('请导入 ComfyUI 的 API 格式工作流（不超过 2 MB），不是画布格式');
    }
    if (jsonEncode(nodes) != jsonEncode(redactCredentials(nodes))) {
      throw const FormatException('工作流包含密钥，请移除密钥后再导入');
    }
    return nodes;
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

  void setInput(Map<String, dynamic> nodes, String binding, String value) {
    final (node, input) = splitInput(binding);
    nodes[node]['inputs'][input] = value;
  }
}
