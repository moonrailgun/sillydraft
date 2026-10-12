import 'dart:convert';

import 'package:dio/dio.dart';

import '../st/import_types.dart';
import 'provider.dart';
import 'sse.dart';

/// Shared OpenAI-compatible wire protocol; credentials are injected at runtime,
/// absent from connection records, task snapshots and normal error messages.
final class OpenAICompatibleProvider implements ModelProvider {
  OpenAICompatibleProvider({
    required this.config,
    required this._apiKey,
    Dio? client,
  }) : _client =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(seconds: 30),
               receiveTimeout: const Duration(seconds: 120),
               followRedirects: false,
             ),
           );
  @override
  final ModelConnection config;
  final String _apiKey;
  final Dio _client;
  static const _supported = {
    'temperature',
    'top_p',
    'frequency_penalty',
    'presence_penalty',
    'max_tokens',
    'max_completion_tokens',
    'seed',
    'stop',
    'logit_bias',
    'reasoning_effort',
  };
  static const _internal = {
    'openai_max_context',
    'max_context_length',
    'truncation_length',
    'streaming',
    'stream_openai',
    'n',
    'assistant_prefill',
    'claude_assistant_prefill',
    'continue_prefill',
    'include_reasoning',
  };
  String _url(String path) =>
      '${config.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/$path';
  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
  };

  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) {
    final diagnostics = <CompatibilityDiagnostic>[];
    for (final key in [
      'assistant_prefill',
      'claude_assistant_prefill',
      'continue_prefill',
    ]) {
      final value = request.parameters[key];
      if (value != null &&
          value != false &&
          value != '' &&
          !config.extraParameters.contains(key)) {
        diagnostics.add(
          CompatibilityDiagnostic(
            'unsupported_prefill',
            '当前连接未实现 $key，需调整预设或连接能力',
            path: key,
            severity: DiagnosticSeverity.error,
          ),
        );
      }
    }
    for (final e in request.parameters.entries) {
      if (!_supported.contains(e.key) &&
          !_internal.contains(e.key) &&
          !config.extraParameters.contains(e.key)) {
        diagnostics.add(
          CompatibilityDiagnostic(
            'unsupported_parameter',
            '当前连接未启用参数 ${e.key}；可在连接能力中配置',
            path: e.key,
          ),
        );
      }
    }
    if ((request.parameters['n'] as num? ?? 1) != 1) {
      diagnostics.add(
        const CompatibilityDiagnostic(
          'multiple_choices',
          '一次生成只处理一个候选；多个走向使用独立任务',
          severity: DiagnosticSeverity.error,
        ),
      );
    }
    if (request.completionText != null && request.tools.isNotEmpty) {
      diagnostics.add(
        const CompatibilityDiagnostic(
          'text_tools',
          '文本补全接口不能接收编辑工具定义',
          severity: DiagnosticSeverity.error,
        ),
      );
    }
    return diagnostics;
  }

  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    final cancel = cancellation ?? GenerationCancellation();
    cancel.check();
    final validation = validateParameters(request);
    if (validation.any((d) => d.severity == DiagnosticSeverity.error)) {
      throw ProviderException(
        'invalid_request',
        validation
            .where((d) => d.severity == DiagnosticSeverity.error)
            .map((d) => d.message)
            .join('\n'),
      );
    }
    final token = CancelToken();
    final remove = cancel.onCancel(() => token.cancel());
    try {
      final parameters = {
        for (final e in request.parameters.entries)
          if (_supported.contains(e.key) ||
              config.extraParameters.contains(e.key))
            e.key: e.value,
      };
      if (parameters.containsKey('max_tokens') &&
          config.outputTokenParameter != 'max_tokens') {
        parameters[config.outputTokenParameter] = parameters.remove(
          'max_tokens',
        );
      }
      parameters.putIfAbsent(
        config.outputTokenParameter,
        () => config.maxOutputTokens,
      );
      // Structural fields are written last so imported parameters cannot change
      // destination, model, messages, credentials or tools.
      final body = <String, dynamic>{
        ...parameters,
        'model': config.model,
        'stream': true,
        if (request.completionText != null)
          'prompt': request.completionText
        else
          'messages': request.messages,
        if (request.tools.isNotEmpty) 'tools': request.tools,
        if (request.stopStrings.isNotEmpty) 'stop': request.stopStrings,
      };
      final response = await _client.post<ResponseBody>(
        _url(
          request.completionText == null ? 'chat/completions' : 'completions',
        ),
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          headers: _headers,
          validateStatus: (_) => true,
          followRedirects: false,
        ),
        cancelToken: token,
      );
      final stream = response.data!.stream.cast<List<int>>();
      if ((response.statusCode ?? 500) >= 300) {
        throw ProviderException(
          'http_error',
          '模型服务拒绝请求，请检查连接、权限或额度',
          statusCode: response.statusCode,
        );
      }
      final tools = <int, _ToolBuffer>{};
      String? finish;
      Map<String, dynamic> usage = {};
      var total = 0;
      final eventStream =
          response.headers
                  .value('content-type')
                  ?.contains('text/event-stream') ==
              true
          ? decodeSse(stream)
          : _jsonBody(stream);
      await for (final event in eventStream) {
        cancel.check();
        total += event.length;
        if (total > 16 * 1024 * 1024) {
          throw const ProviderException('response_limit', '模型响应超过大小限制');
        }
        if (event.trim() == '[DONE]') break;
        final decoded = jsonDecode(event);
        if (decoded is! Map<String, dynamic>) {
          throw const ProviderException('invalid_response', '模型响应不是对象');
        }
        if (decoded['error'] != null) {
          throw const ProviderException('stream_error', '模型服务在生成中返回错误');
        }
        if (decoded['usage'] is Map<String, dynamic>) {
          usage = decoded['usage'] as Map<String, dynamic>;
        }
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = jsonObject(choices.first, 'choice');
        final delta = jsonObject(
          choice['delta'] ?? choice['message'] ?? <String, dynamic>{},
          'delta',
        );
        final content = delta['content'] ?? choice['text'];
        if (content is String && content.isNotEmpty) yield TextDelta(content);
        final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield ReasoningDelta(reasoning);
        }
        if (delta['refusal'] is String &&
            (delta['refusal'] as String).isNotEmpty) {
          throw const ProviderException('refusal', '模型未完成此请求');
        }
        final calls = delta['tool_calls'];
        if (calls is List) {
          for (final (i, value) in calls.indexed) {
            final call = jsonObject(value, 'tool_call');
            final index = call['index'] as int? ?? i;
            if (index < 0 || index > 63) {
              throw const ProviderException('tool_limit', '工具调用数量超限');
            }
            final buffer = tools.putIfAbsent(index, _ToolBuffer.new);
            if (call['id'] is String) buffer.id = call['id'] as String;
            final function = call['function'] as Map<String, dynamic>? ?? {};
            if (function['name'] is String) {
              buffer.name += function['name'] as String;
            }
            if (function['arguments'] is String) {
              buffer.arguments.write(function['arguments']);
            }
          }
        }
        if (choice['finish_reason'] is String) {
          finish = choice['finish_reason'] as String;
        }
      }
      cancel.check();
      if (finish == null) {
        throw const ProviderException('interrupted', '连接中断，已收到的部分内容已保留');
      }
      for (final key in tools.keys.toList()..sort()) {
        final call = tools[key]!;
        if (call.id.isEmpty || call.name.isEmpty) {
          throw const ProviderException('invalid_tool', '工具调用缺少标识或名称');
        }
        final args = jsonDecode(call.arguments.toString());
        if (args is! Map<String, dynamic>) {
          throw const ProviderException(
            'invalid_tool_arguments',
            '工具参数必须是 JSON 对象',
          );
        }
        yield ToolCallReady(call.id, call.name, args);
      }
      yield GenerationFinished(finish, usage: usage);
    } on DioException catch (error) {
      if (cancel.isCancelled || CancelToken.isCancel(error)) {
        throw const GenerationCancelled();
      }
      throw ProviderException(
        'network_error',
        '连接失败或超时，请检查模型地址和网络',
        statusCode: error.response?.statusCode,
      );
    } on FormatException {
      throw const ProviderException('invalid_response', '模型响应格式不完整或无效');
    } finally {
      remove();
    }
  }

  Stream<String> _jsonBody(Stream<List<int>> stream) async* {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (bytes.length > 16 * 1024 * 1024) {
        throw const ProviderException('response_limit', '模型响应超过大小限制');
      }
    }
    yield utf8.decode(bytes);
  }

  @override
  Future<List<String>> listModels() async {
    try {
      final response = await _client.get<Object?>(
        _url('models'),
        options: Options(headers: _headers, followRedirects: false),
      );
      final body = response.data is String
          ? jsonDecode(response.data as String)
          : response.data;
      final data = jsonObject(body, 'models')['data'];
      if (data is! List) throw const FormatException('缺少模型列表');
      return data
          .map((m) => stringField(jsonObject(m, 'model'), 'id'))
          .where((id) => id.isNotEmpty)
          .toList()
        ..sort();
    } on DioException catch (error) {
      throw ProviderException(
        'model_list',
        '无法获取模型列表，可手动输入模型名称',
        statusCode: error.response?.statusCode,
      );
    } on FormatException {
      throw const ProviderException('model_list', '模型列表格式无效，可手动输入模型名称');
    }
  }

  @override
  void close() => _client.close(force: true);
}

final class _ToolBuffer {
  String id = '', name = '';
  final arguments = StringBuffer();
}
