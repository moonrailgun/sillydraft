import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../st/import_types.dart';
import 'image_provider.dart';
import 'provider.dart';

/// Remote jobs outlive local streams. Closing/cancelling a local stream detaches;
/// explicit user cancellation calls [cancelRemote] and waits for acknowledgement.
abstract interface class RemoteJobControl {
  Future<void> cancelRemote(String executionId);
}

final class RemoteRunnerClient {
  RemoteRunnerClient({
    required this.config,
    required String accessToken,
    this.pollInterval = const Duration(milliseconds: 750),
  }) : _accessToken = accessToken,
       _dio = Dio(
         BaseOptions(
           connectTimeout: const Duration(seconds: 15),
           receiveTimeout: const Duration(seconds: 30),
           sendTimeout: const Duration(seconds: 60),
           followRedirects: false,
         ),
       ) {
    if (accessToken.isEmpty ||
        accessToken.length > 1024 ||
        accessToken.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('请填写有效的远程执行器访问令牌');
    }
  }
  final ModelConnection config;
  final Duration pollInterval;
  final String _accessToken;
  final Dio _dio;
  final _pending = <CancelToken>{};
  bool _closed = false;
  String _job(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('远程任务标识无效');
    }
    return 'v1/jobs/$id';
  }

  Future<Uint8List> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    int limit = 16 * 1024 * 1024,
    GenerationCancellation? cancellation,
  }) async {
    if (_closed) throw const GenerationCancelled();
    cancellation?.check();
    final token = CancelToken();
    _pending.add(token);
    final remove = cancellation?.onCancel(() => token.cancel());
    try {
      final response = await _dio.request<ResponseBody>(
        '${config.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/$path',
        data: body == null ? null : jsonEncode(body),
        cancelToken: token,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'application/json',
          },
        ),
      );
      final data = BytesBuilder(copy: false);
      await for (final part in response.data!.stream) {
        cancellation?.check();
        if (data.length + part.length > limit) {
          token.cancel();
          throw const ProviderException('remote_size', '远程执行器响应超过大小限制');
        }
        data.add(part);
      }
      if (response.statusCode! < 200 || response.statusCode! >= 300) {
        final message = switch (response.statusCode) {
          401 => '远程执行器认证失败，请检查访问令牌',
          409 => '远程任务身份冲突或任务已完成，请获取结果',
          413 => '远程任务输入超过服务端大小限制',
          404 => '远程任务不存在，请检查服务地址；不会自动重新生成',
          429 || 507 => '远程执行器容量已满，请稍后重试或清理服务端任务',
          _ => '远程执行器未接受请求，请检查服务端模型配置和任务参数',
        };
        throw ProviderException(
          'remote_http',
          message,
          statusCode: response.statusCode,
        );
      }
      return data.takeBytes();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) throw const GenerationCancelled();
      throw const ProviderException(
        'remote_offline',
        '与远程执行器的连接中断；任务可能仍在执行，可获取同一任务的结果',
      );
    } finally {
      remove?.call();
      _pending.remove(token);
    }
  }

  Future<Map<String, dynamic>> _json(
    String method,
    String path, {
    Map<String, dynamic>? body,
    GenerationCancellation? cancellation,
  }) async {
    final bytes = await _request(
      method,
      path,
      body: body,
      cancellation: cancellation,
    );
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('远程响应格式无效');
    }
    return decoded;
  }

  Future<List<String>> listModels() async {
    final response = await _json('GET', 'v1/models');
    return (response['data'] as List)
        .map((e) => (e as Map)['id'] as String)
        .toList();
  }

  Future<void> cancelRemote(String id) async {
    final response = await _json('DELETE', _job(id));
    if (!['cancelled', 'failed', 'interrupted'].contains(response['status'])) {
      throw const ProviderException('remote_cancel', '远程取消尚未确认，请获取任务状态后重试');
    }
  }

  Stream<Map<String, dynamic>> watch({
    required String id,
    required String kind,
    required Map<String, dynamic> request,
    bool retrieveOnly = false,
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async* {
    _job(id);
    final clean = {...request}
      ..remove('executionId')
      ..remove('usagePurpose')
      ..remove('usageBranchId')
      ..remove('retrieveOnly');
    var state = retrieveOnly
        ? await _json('GET', _job(id), cancellation: cancellation)
        : await _json(
            'POST',
            'v1/jobs',
            body: {
              'id': id,
              'profile': config.model,
              'kind': kind,
              'request': clean,
              if (kind == 'image')
                'references': [
                  for (final ref in references)
                    {'mimeType': ref.mimeType, 'data': base64Encode(ref.bytes)},
                ],
            },
            cancellation: cancellation,
          );
    while (true) {
      cancellation?.check();
      if (state['id'] != id ||
          state['kind'] != kind ||
          state['profile'] != config.model ||
          ![
            'queued',
            'running',
            'completed',
            'failed',
            'cancelled',
            'interrupted',
          ].contains(state['status'])) {
        throw const ProviderException('remote_protocol', '远程任务响应与请求不匹配');
      }
      yield state;
      if (!['queued', 'running'].contains(state['status'])) return;
      await Future<void>.delayed(pollInterval);
      cancellation?.check();
      state = await _json('GET', _job(id), cancellation: cancellation);
    }
  }

  Future<Uint8List> image(String id, GenerationCancellation? cancellation) =>
      _request(
        'GET',
        '${_job(id)}/image',
        limit: 32 * 1024 * 1024,
        cancellation: cancellation,
      );
  void close() {
    _closed = true;
    for (final token in _pending.toList()) {
      token.cancel();
    }
    _dio.close(force: true);
  }
}

String _executionId(String? id) {
  if (id == null) {
    throw const ProviderException('remote_identity', '远程执行需要持久化任务标识');
  }
  return id;
}

Never _terminalError(Map<String, dynamic> state) {
  if (state['status'] == 'cancelled') throw const GenerationCancelled();
  if (state['status'] == 'interrupted') {
    throw const ProviderException('interrupted', '服务端执行已中断，部分输出已保留；重新生成会发起新请求');
  }
  throw const ProviderException(
    'remote_failed',
    '远程模型执行失败，部分结果已保留；请检查服务端配置后明确重新生成',
  );
}

final class RemoteModelProvider implements ModelProvider, RemoteJobControl {
  RemoteModelProvider({
    required this.config,
    required String accessToken,
    Duration pollInterval = const Duration(milliseconds: 750),
  }) : _client = RemoteRunnerClient(
         config: config,
         accessToken: accessToken,
         pollInterval: pollInterval,
       );
  @override
  final ModelConnection config;
  final RemoteRunnerClient _client;
  @override
  Future<List<String>> listModels() => _client.listModels();
  @override
  Future<void> cancelRemote(String executionId) =>
      _client.cancelRemote(executionId);
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      request.tools.isEmpty
      ? []
      : [
          const CompatibilityDiagnostic(
            'remote_agent_tools',
            '编辑助手的工具在本地执行，请为编辑助手选择直连模型；其正文生成任务可以使用远程执行器',
            severity: DiagnosticSeverity.error,
          ),
        ];
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    if (!config.supportsText) {
      throw const ProviderException('model_kind', '此连接仅支持生图，请选择文本模型');
    }
    if (request.tools.isNotEmpty) {
      throw const ProviderException('remote_agent_tools', '远程执行器不接管本地编辑工具');
    }
    var text = '', reasoning = '';
    await for (final state in _client.watch(
      id: _executionId(request.executionId),
      kind: 'text',
      request: request.raw,
      retrieveOnly: request.retrieveOnly,
      cancellation: cancellation,
    )) {
      final next = state['text'] as String? ?? '',
          thought = state['reasoning'] as String? ?? '';
      if (!next.startsWith(text) || !thought.startsWith(reasoning)) {
        throw const ProviderException('remote_protocol', '远程输出不是同一任务的连续结果');
      }
      if (next.length > text.length) {
        yield TextDelta(next.substring(text.length));
      }
      if (thought.length > reasoning.length) {
        yield ReasoningDelta(thought.substring(reasoning.length));
      }
      text = next;
      reasoning = thought;
      if (state['status'] == 'completed') {
        final finish = jsonObject(state['finish'], 'finish');
        yield GenerationFinished(
          finish['reason'] as String,
          usage: (finish['usage'] as Map? ?? {}).cast<String, dynamic>(),
        );
      } else if (!['queued', 'running'].contains(state['status'])) {
        _terminalError(state);
      }
    }
  }

  @override
  void close() => _client.close();
}

final class RemoteImageProvider implements ImageProvider, RemoteJobControl {
  RemoteImageProvider({
    required this.config,
    required String accessToken,
    Duration pollInterval = const Duration(milliseconds: 750),
  }) : _client = RemoteRunnerClient(
         config: config,
         accessToken: accessToken,
         pollInterval: pollInterval,
       );
  @override
  final ModelConnection config;
  final RemoteRunnerClient _client;
  @override
  Future<void> cancelRemote(String executionId) =>
      _client.cancelRemote(executionId);
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final id = _executionId(request.executionId);
    await for (final state in _client.watch(
      id: id,
      kind: 'image',
      request: request.raw,
      retrieveOnly: request.retrieveOnly,
      references: references,
      cancellation: cancellation,
    )) {
      if (state['status'] == 'completed') {
        return GeneratedImage(
          bytes: await _client.image(id, cancellation),
          revisedPrompt: state['revisedPrompt'] as String? ?? '',
          usage: (state['usage'] as Map? ?? {}).cast<String, dynamic>(),
        );
      }
      if (!['queued', 'running'].contains(state['status'])) {
        _terminalError(state);
      }
    }
    throw const ProviderException('remote_protocol', '远程图片任务未返回完成状态');
  }

  @override
  void close() => _client.close();
}
