import 'dart:convert';

import '../st/import_types.dart';
import 'comfy_workflow.dart';

enum ModelKind { text, image, both }

enum ModelProtocol {
  openAICompatible,
  comfyUI,
  novelAI,
  anthropic,
  gemini,
  sillyDraftRunner,

  /// The author's own Claude Code login, run as a local `claude -p` process.
  claudeCode,

  /// The author's own Codex login, run as a local `codex exec` process.
  codexCli;

  /// Desktop subscriptions driven through an installed command-line tool.
  bool get isLocalCli => this == claudeCode || this == codexCli;
}

final class ModelConnection extends JsonSource {
  ModelConnection({
    required String id,
    required String name,
    required String baseUrl,
    required String model,
    List<String>? models,
    ModelKind? kind,
    ComfyWorkflow? comfyWorkflow,
    ModelProtocol protocol = ModelProtocol.openAICompatible,
    String outputTokenParameter = 'max_tokens',
    List<String> extraParameters = const [],
    int contextWindow = 200000,
    int maxOutputTokens = 2048,
    bool allowInsecureHttp = false,
    String command = '',
  }) : super({
         'id': id,
         'name': name,
         'baseUrl': baseUrl,
         'model': model,
         'models': ?models,
         if (kind != null) 'kind': kind.name,
         if (comfyWorkflow != null) 'comfyWorkflow': comfyWorkflow.raw,
         'protocol': protocol.name,
         'outputTokenParameter': outputTokenParameter,
         'extraParameters': extraParameters,
         'contextWindow': contextWindow,
         'maxOutputTokens': maxOutputTokens,
         'allowInsecureHttp': allowInsecureHttp,
         if (command.isNotEmpty) 'command': command,
       }) {
    if (id.isEmpty || model.trim().isEmpty) {
      throw const FormatException('模型配置缺少标识或模型名称');
    }
    if (models != null &&
        (!models.contains(model) ||
            models.any((m) => m.trim().isEmpty || m != m.trim()) ||
            models.toSet().length != models.length)) {
      throw const FormatException('模型列表须包含当前模型，且不能有空白或重复项');
    }
    if (protocol.isLocalCli) {
      // Local tools have no endpoint; an explicit command must be a path, not
      // a shell snippet, because it is executed directly.
      if (command.contains(RegExp(r'[\r\n\x00]'))) {
        throw const FormatException('命令路径无效');
      }
      return;
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('模型地址须为不含凭据或查询参数的 HTTP(S) 地址');
    }
    if (protocol == ModelProtocol.sillyDraftRunner &&
        uri.scheme == 'http' &&
        !['localhost', '127.0.0.1', '::1'].contains(uri.host) &&
        !allowInsecureHttp) {
      throw const FormatException('远程执行器需要 HTTPS；可信局域网可明确启用 HTTP');
    }
    if (![
      'max_tokens',
      'max_completion_tokens',
    ].contains(outputTokenParameter)) {
      throw const FormatException('输出参数名称无效');
    }
  }
  factory ModelConnection.fromJson(Map<String, dynamic> map) => ModelConnection(
    id: map['id'] as String,
    name: map['name'] as String,
    baseUrl: map['baseUrl'] as String,
    model: map['model'] as String,
    models: map.containsKey('models')
        ? stringList(map['models'], 'models')
        : null,
    kind: map['kind'] == null
        ? null
        : ModelKind.values.byName(map['kind'] as String),
    comfyWorkflow: map['comfyWorkflow'] == null
        ? null
        : ComfyWorkflow.fromJson(
            jsonObject(map['comfyWorkflow'], 'ComfyUI 工作流'),
          ),
    protocol: ModelProtocol.values.byName(
      map['protocol'] as String? ?? 'openAICompatible',
    ),
    outputTokenParameter:
        map['outputTokenParameter'] as String? ?? 'max_tokens',
    extraParameters: stringList(map['extraParameters'], 'extraParameters'),
    contextWindow: map['contextWindow'] as int? ?? 200000,
    maxOutputTokens: map['maxOutputTokens'] as int? ?? 2048,
    allowInsecureHttp: map['allowInsecureHttp'] as bool? ?? false,
    command: map['command'] as String? ?? '',
  );
  String get id => raw['id'] as String;
  String get name => raw['name'] as String;
  String get baseUrl => raw['baseUrl'] as String;
  String get model => raw['model'] as String;
  List<String> get models =>
      raw['models'] == null ? [model] : stringList(raw['models'], 'models');
  ModelKind get kind => protocol.isLocalCli
      ? ModelKind.text
      : protocol == ModelProtocol.comfyUI || protocol == ModelProtocol.novelAI
      ? ModelKind.image
      : ModelKind.values.byName(raw['kind'] as String? ?? 'both');
  ComfyWorkflow? get comfyWorkflow => raw['comfyWorkflow'] == null
      ? null
      : ComfyWorkflow.fromJson(raw['comfyWorkflow'] as Map<String, dynamic>);

  /// [model] as requests send it: null for a ComfyUI workflow that binds no
  /// model input, where [model] is only the settings' 'workflow' marker.
  String? get sentModel =>
      comfyWorkflow?.modelInput.isEmpty == true ? null : model;
  bool get supportsText => kind != ModelKind.image;
  bool get supportsImages => kind != ModelKind.text;

  ModelConnection withModel(String model) =>
      ModelConnection.fromJson({...raw, 'model': model});
  ModelProtocol get protocol =>
      ModelProtocol.values.byName(raw['protocol'] as String);
  String get outputTokenParameter => raw['outputTokenParameter'] as String;
  List<String> get extraParameters =>
      (raw['extraParameters'] as List).cast<String>();
  int get contextWindow => raw['contextWindow'] as int;
  int get maxOutputTokens => raw['maxOutputTokens'] as int;
  bool get allowInsecureHttp => raw['allowInsecureHttp'] as bool;

  /// Explicit executable for a local CLI connection; empty means look it up.
  String get command => raw['command'] as String? ?? '';
}

final class ProviderRequest extends JsonSource {
  ProviderRequest({
    List<Map<String, dynamic>> messages = const [],
    String? completionText,
    Map<String, dynamic> parameters = const {},
    List<Map<String, dynamic>> tools = const [],
    List<String> stopStrings = const [],
    String? executionId,
    bool retrieveOnly = false,
  }) : super({
         'messages': messages,
         'completionText': completionText,
         'parameters': parameters,
         'tools': tools,
         'stopStrings': stopStrings,
         'executionId': ?executionId,
         if (retrieveOnly) 'retrieveOnly': true,
       });
  factory ProviderRequest.fromJson(Map<String, dynamic> json) =>
      ProviderRequest(
        messages: (json['messages'] as List? ?? [])
            .cast<Map<String, dynamic>>(),
        completionText: json['completionText'] as String?,
        parameters: json['parameters'] as Map<String, dynamic>? ?? {},
        tools: (json['tools'] as List? ?? []).cast<Map<String, dynamic>>(),
        stopStrings: stringList(json['stopStrings'], 'stopStrings'),
        executionId: json['executionId'] as String?,
        retrieveOnly: json['retrieveOnly'] as bool? ?? false,
      );
  List<Map<String, dynamic>> get messages =>
      (raw['messages'] as List).cast<Map<String, dynamic>>();
  String? get completionText => raw['completionText'] as String?;
  Map<String, dynamic> get parameters =>
      raw['parameters'] as Map<String, dynamic>;
  List<Map<String, dynamic>> get tools =>
      (raw['tools'] as List).cast<Map<String, dynamic>>();
  List<String> get stopStrings => (raw['stopStrings'] as List).cast<String>();
  String? get executionId => raw['executionId'] as String?;
  bool get retrieveOnly => raw['retrieveOnly'] == true;
}

sealed class ProviderEvent {
  const ProviderEvent();
}

final class TextDelta extends ProviderEvent {
  const TextDelta(this.text);
  final String text;
}

final class ReasoningDelta extends ProviderEvent {
  const ReasoningDelta(this.text);
  final String text;
}

final class ToolCallReady extends ProviderEvent {
  ToolCallReady(this.id, this.name, Map<String, dynamic> arguments)
    : _arguments = jsonEncode(arguments);
  final String id, name, _arguments;
  Map<String, dynamic> get arguments =>
      jsonDecode(_arguments) as Map<String, dynamic>;
  Map<String, dynamic> toOpenAI() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': _arguments},
  };
}

final class GenerationFinished extends ProviderEvent {
  const GenerationFinished(this.reason, {this.usage = const {}});
  final String reason;
  final Map<String, dynamic> usage;
  bool get isComplete =>
      ['stop', 'tool_calls', 'end_turn', 'tool_use', 'STOP'].contains(reason);
}

class ProviderException implements Exception {
  const ProviderException(this.code, this.message, {this.statusCode});
  final String code, message;
  final int? statusCode;
  @override
  String toString() =>
      '$message${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

final class GenerationCancelled extends ProviderException {
  const GenerationCancelled() : super('cancelled', '生成已取消');
}

final class GenerationCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];
  bool get isCancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final callback in [..._listeners]) {
      callback();
    }
    _listeners.clear();
  }

  void check() {
    if (_cancelled) throw const GenerationCancelled();
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }
}

abstract interface class ModelProvider {
  ModelConnection get config;
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  });
  Future<List<String>> listModels();
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request);
  void close();
}
