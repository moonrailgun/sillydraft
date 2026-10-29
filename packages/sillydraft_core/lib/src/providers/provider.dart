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

/// The [ModelConnection.raw] fields that say where its key goes or which
/// tool it runs: a desktop's keys follow only these as it saved them.
const connectionEndpointKeys = [
  'protocol',
  'baseUrl',
  'command',
  'allowInsecureHttp',
];

/// ST 1.19.0 (06bde939) openai.js: OpenRouter/NanoGPT sampling fields.
/// SillyDraft enables these by default; ST Custom requires explicit inclusion.
const stSamplingParameters = ['top_k', 'top_a', 'min_p', 'repetition_penalty'];

final class ModelConnection extends JsonSource {
  ModelConnection({
    required String id,
    required String name,
    required String baseUrl,
    required String model,
    List<String>? models,
    ModelKind? kind,
    ComfyWorkflow? comfyWorkflow,
    ComfyWorkflow? comfyEditWorkflow,
    ModelProtocol protocol = ModelProtocol.openAICompatible,
    String outputTokenParameter = 'max_tokens',
    List<String> extraParameters = const [],
    List<String> disabledSamplingParameters = const [],
    int contextWindow = 200000,
    int maxOutputTokens = 2048,
    int maxReferenceImages = 16,
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
         if (comfyEditWorkflow != null)
           'comfyEditWorkflow': comfyEditWorkflow.raw,
         'protocol': protocol.name,
         'outputTokenParameter': outputTokenParameter,
         'extraParameters': extraParameters,
         'disabledSamplingParameters': disabledSamplingParameters,
         'contextWindow': contextWindow,
         'maxOutputTokens': maxOutputTokens,
         'maxReferenceImages': maxReferenceImages,
         'allowInsecureHttp': allowInsecureHttp,
         if (command.isNotEmpty) 'command': command,
       }) {
    if (maxReferenceImages < 0 || maxReferenceImages > 16) {
      throw const FormatException('参考图数量须在 0–16 之间');
    }
    if (id.isEmpty || model.trim().isEmpty) {
      throw const FormatException('模型配置缺少标识或模型名称');
    }
    if (models != null &&
        (!models.contains(model) ||
            models.any((m) => m.trim().isEmpty || m != m.trim()) ||
            models.toSet().length != models.length)) {
      throw const FormatException('模型列表须包含当前模型，且不能有空白或重复项');
    }
    if (comfyEditWorkflow != null && comfyEditWorkflow.imageInputs.isEmpty) {
      throw const FormatException('图生图工作流须绑定至少一个参考图输入');
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
    comfyEditWorkflow: map['comfyEditWorkflow'] == null
        ? null
        : ComfyWorkflow.fromJson(
            jsonObject(map['comfyEditWorkflow'], 'ComfyUI 图生图工作流'),
          ),
    protocol: ModelProtocol.values.byName(
      map['protocol'] as String? ?? 'openAICompatible',
    ),
    outputTokenParameter:
        map['outputTokenParameter'] as String? ?? 'max_tokens',
    extraParameters: stringList(map['extraParameters'], 'extraParameters'),
    disabledSamplingParameters: stringList(
      map['disabledSamplingParameters'],
      'disabledSamplingParameters',
    ),
    contextWindow: map['contextWindow'] as int? ?? 200000,
    maxOutputTokens: map['maxOutputTokens'] as int? ?? 2048,
    maxReferenceImages: map['maxReferenceImages'] as int? ?? 16,
    allowInsecureHttp: map['allowInsecureHttp'] as bool? ?? false,
    command: map['command'] as String? ?? '',
  );
  String get id => raw['id'] as String;
  String get name => raw['name'] as String;
  String get baseUrl => raw['baseUrl'] as String;
  String get model => raw['model'] as String;
  List<String> get models =>
      raw['models'] == null ? [model] : stringList(raw['models'], 'models');
  ModelKind get kind => protocol == ModelProtocol.codexCli
      ? ModelKind.both
      : protocol.isLocalCli
      ? ModelKind.text
      : protocol == ModelProtocol.comfyUI || protocol == ModelProtocol.novelAI
      ? ModelKind.image
      : ModelKind.values.byName(raw['kind'] as String? ?? 'both');
  ComfyWorkflow? get comfyWorkflow => raw['comfyWorkflow'] == null
      ? null
      : ComfyWorkflow.fromJson(raw['comfyWorkflow'] as Map<String, dynamic>);
  ComfyWorkflow? get comfyEditWorkflow => raw['comfyEditWorkflow'] == null
      ? null
      : ComfyWorkflow.fromJson(
          raw['comfyEditWorkflow'] as Map<String, dynamic>,
        );

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
  List<String> get disabledSamplingParameters =>
      (raw['disabledSamplingParameters'] as List).cast<String>();
  int get contextWindow => raw['contextWindow'] as int;
  int get maxOutputTokens => raw['maxOutputTokens'] as int;
  int get maxReferenceImages => raw['maxReferenceImages'] as int;
  bool get allowInsecureHttp => raw['allowInsecureHttp'] as bool;

  /// Explicit executable for a local CLI connection; empty means look it up.
  String get command => raw['command'] as String? ?? '';
}

/// The editor also needs tool calls: OpenAI-compatible or a local CLI.
bool connectionServes(ModelConnection connection, String role) =>
    switch (role) {
      'editor' =>
        connection.supportsText &&
            (connection.protocol == ModelProtocol.openAICompatible ||
                connection.protocol.isLocalCli),
      'image' => connection.supportsImages,
      _ => connection.supportsText,
    };

final class ProviderRequest extends JsonSource {
  ProviderRequest({
    List<Map<String, dynamic>> messages = const [],
    String? completionText,
    Map<String, dynamic> parameters = const {},
    List<Map<String, dynamic>> tools = const [],
    List<String> stopStrings = const [],
    String? executionId,
    String? usagePurpose,
    String? usageBranchId,
    bool retrieveOnly = false,
  }) : super({
         'messages': messages,
         'completionText': completionText,
         'parameters': parameters,
         'tools': tools,
         'stopStrings': stopStrings,
         'executionId': ?executionId,
         'usagePurpose': ?usagePurpose,
         'usageBranchId': ?usageBranchId,
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
        usagePurpose: json['usagePurpose'] as String?,
        usageBranchId: json['usageBranchId'] as String?,
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
  // Local bookkeeping; providers must not include these in model payloads.
  String? get usagePurpose => raw['usagePurpose'] as String?;
  String? get usageBranchId => raw['usageBranchId'] as String?;
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
  ToolCallReady(
    this.id,
    this.name,
    Map<String, dynamic> arguments, {
    Map<String, dynamic>? extraContent,
  }) : _arguments = jsonEncode(arguments),
       _extraContent = extraContent == null ? null : jsonEncode(extraContent);
  final String id, name, _arguments;
  final String? _extraContent;
  Map<String, dynamic> get arguments =>
      jsonDecode(_arguments) as Map<String, dynamic>;
  Map<String, dynamic>? get extraContent => _extraContent == null
      ? null
      : jsonDecode(_extraContent) as Map<String, dynamic>;
  Map<String, dynamic> toOpenAI() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': _arguments},
    if (_extraContent != null) 'extra_content': extraContent,
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

/// How many reference images an image request on [connection] may carry.
/// Text-only engines retain the canonical descriptions without image inputs.
/// References on ComfyUI run the edit workflow when there is one.
int referenceLimit(ModelConnection connection) {
  switch (connection.protocol) {
    case ModelProtocol.novelAI:
      return 0;
    case ModelProtocol.comfyUI:
      return (connection.comfyEditWorkflow ?? connection.comfyWorkflow)
              ?.imageInputs
              .length
              .clamp(0, connection.maxReferenceImages) ??
          0;
    default:
      return connection.maxReferenceImages;
  }
}
