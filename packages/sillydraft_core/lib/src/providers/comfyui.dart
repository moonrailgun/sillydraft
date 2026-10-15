import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

import 'comfy_workflow.dart';
import 'image_provider.dart';
import 'provider.dart';

final class ComfyUIProvider implements ImageProvider {
  ComfyUIProvider({required this.config, String apiKey = ''})
    : _client = Dio(
        BaseOptions(
          baseUrl: '${config.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/',
          headers: {if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(minutes: 2),
          followRedirects: false,
        ),
      );

  @override
  final ModelConnection config;
  final Dio _client;
  static const _maxImageBytes = 32 * 1024 * 1024;

  Future<List<String>> listWorkflows() async {
    try {
      final data = _decode(
        await _bytes(
          'userdata',
          query: {'dir': 'workflows', 'recurse': true, 'split': false},
          limit: 2 * 1024 * 1024,
        ),
      );
      if (data is! List || data.any((name) => name is! String)) {
        throw const ProviderException('comfy_result', 'ComfyUI 返回的工作流列表无效');
      }
      return data.where(_workflowFile).cast<String>().toSet().toList()..sort();
    } on DioException {
      throw const ProviderException(
        'comfy_connection',
        '无法连接 ComfyUI，请检查服务地址和访问密钥',
      );
    }
  }

  Future<Map<String, dynamic>> readWorkflow(String filename) async {
    if (!_workflowFile(filename)) {
      throw const FormatException('请选择 workflows 目录内的 JSON 工作流文件');
    }
    try {
      final data = await _json(
        'userdata/${Uri.encodeComponent('workflows/$filename')}',
        limit: 2 * 1024 * 1024,
      );
      if (data['nodes'] is List) {
        return ComfyWorkflow.parseCanvas(
          data,
          await _json('object_info', limit: 16 * 1024 * 1024),
        );
      }
      return ComfyWorkflow.parseNodes(data);
    } on DioException {
      throw const ProviderException(
        'comfy_connection',
        '无法连接 ComfyUI，请检查服务地址和访问密钥',
      );
    }
  }

  static bool _workflowFile(Object? name) =>
      name is String &&
      name.toLowerCase().endsWith('.json') &&
      // ComfyUI unquotes the already decoded route; reject ambiguous paths.
      !name.contains(RegExp(r'%[0-9a-fA-F]{2}')) &&
      _safeFolder(name) &&
      name.split('/').every(_safeFile);

  /// Use the bound loader's choices so UNET and checkpoint workflows both work.
  Future<List<String>> listModels() async {
    final workflow = config.comfyWorkflow;
    var nodeClass = 'CheckpointLoaderSimple', input = 'ckpt_name';
    if (workflow != null && workflow.modelInput.isNotEmpty) {
      final (node, field) = ComfyWorkflow.splitInput(workflow.modelInput);
      nodeClass = workflow.nodes[node]['class_type'] as String;
      input = field;
    }
    try {
      final data = await _json('object_info/${Uri.encodeComponent(nodeClass)}');
      final definition = data[nodeClass];
      final inputs = definition is Map ? definition['input'] : null;
      final required = inputs is Map ? inputs['required'] : null;
      final optional = inputs is Map ? inputs['optional'] : null;
      final spec =
          (required is Map ? required[input] : null) ??
          (optional is Map ? optional[input] : null);
      if (spec is! List || spec.isEmpty || spec.first is! List) {
        throw const ProviderException('comfy_models', '无法获取此模型输入的选项，可手动填写模型名称');
      }
      return (spec.first as List).whereType<String>().toSet().toList()..sort();
    } on DioException {
      throw const ProviderException(
        'comfy_connection',
        '无法连接 ComfyUI，请检查服务地址和访问密钥',
      );
    }
  }

  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final signal = cancellation ?? GenerationCancellation();
    final token = CancelToken(), stopped = Completer<void>();
    // shortcut: cancel local waits; add server cancellation when it can target one prompt across supported versions.
    final remove = signal.onCancel(() {
      token.cancel();
      if (!stopped.isCompleted) stopped.complete();
    });
    var timedOut = false;
    final deadline = Timer(const Duration(minutes: 10), () {
      timedOut = true;
      token.cancel();
      if (!stopped.isCompleted) stopped.complete();
    });
    void check() {
      signal.check();
      if (timedOut) {
        throw const ProviderException(
          'comfy_timeout',
          '等待 ComfyUI 超过 10 分钟，请检查服务端任务状态',
        );
      }
    }

    try {
      check();
      // References need the edit workflow when there is one; the text
      // workflow's own image inputs still serve when there is not. The edit
      // workflow keeps the model saved in it: the connection's models are
      // the text workflow's.
      final edit = references.isEmpty ? null : config.comfyEditWorkflow;
      final workflow = edit ?? config.comfyWorkflow;
      if (config.protocol != ModelProtocol.comfyUI || workflow == null) {
        throw const ProviderException(
          'comfy_workflow',
          '请先导入并绑定 ComfyUI API 工作流',
        );
      }
      if (edit == null &&
          config.models.length > 1 &&
          workflow.modelInput.isEmpty) {
        throw const ProviderException('comfy_workflow', '使用多个模型时，请绑定工作流的模型输入');
      }
      if (request.parameters.keys.any((key) => key != 'seed')) {
        throw const ProviderException(
          'comfy_parameter',
          'ComfyUI 额外参数仅支持 seed；其他参数请在工作流中配置',
        );
      }
      final seed =
          request.parameters['seed'] ?? Random.secure().nextInt(0x7fffffff);
      if (seed is! int || seed < 0 || seed > 9007199254740991) {
        throw const ProviderException(
          'comfy_parameter',
          'seed 须为 0 到 9007199254740991 的整数',
        );
      }
      if (references.length > workflow.imageInputs.length) {
        throw ProviderException(
          'comfy_reference',
          workflow.imageInputs.isEmpty
              ? '请先在模型设置中添加图生图工作流，或为工作流绑定参考图输入'
              : '此工作流最多使用 ${workflow.imageInputs.length} 张参考图',
        );
      }
      final nodes = workflow.nodes;
      workflow.setInput(nodes, workflow.promptInput, request.prompt);
      if (edit == null && workflow.modelInput.isNotEmpty) {
        workflow.setInput(nodes, workflow.modelInput, config.model);
      }
      for (final node in nodes.values) {
        final inputs = node['inputs'] as Map<String, dynamic>;
        for (final key in ['seed', 'noise_seed']) {
          if (inputs[key] is int) inputs[key] = seed;
        }
      }
      final uploaded = <String>[];
      for (final reference in references) {
        final bytes = reference.bytes;
        final extension = const {
          'image/png': 'png',
          'image/jpeg': 'jpg',
          'image/webp': 'webp',
        }[reference.mimeType];
        if (extension == null ||
            bytes.isEmpty ||
            bytes.length > _maxImageBytes) {
          throw const ProviderException(
            'comfy_reference',
            '参考图须为 32 MB 以内的 PNG、JPEG、WebP',
          );
        }
        final file = await _json(
          'upload/image',
          method: 'POST',
          token: token,
          data: FormData.fromMap({
            'type': 'input',
            'overwrite': 'false',
            'image': MultipartFile.fromBytes(
              bytes,
              filename: 'sillydraft-${const Uuid().v4()}.$extension',
              contentType: DioMediaType.parse(reference.mimeType),
            ),
          }),
        );
        final name = file['name'], folder = file['subfolder'] ?? '';
        if (!_safeFile(name) ||
            !_safeFolder(folder) ||
            file['type'] != 'input') {
          throw const ProviderException(
            'comfy_reference',
            'ComfyUI 返回了无效的参考图路径',
          );
        }
        uploaded.add(folder == '' ? name as String : '$folder/$name');
      }
      // Inputs past the last reference repeat it, so a sample image saved in
      // the workflow never slips into the picture.
      if (uploaded.isNotEmpty) {
        for (final (i, binding) in workflow.imageInputs.indexed) {
          workflow.setInput(
            nodes,
            binding,
            uploaded[i < uploaded.length ? i : uploaded.length - 1],
          );
        }
      }
      check();
      final queued = await _json(
        'prompt',
        method: 'POST',
        data: {'prompt': nodes},
        token: token,
      );
      final id = queued['prompt_id'];
      // Other output branches may have node_errors even when this job is queued.
      if (id is! String || id.isEmpty) {
        throw const ProviderException(
          'comfy_workflow',
          'ComfyUI 拒绝了工作流，请检查节点、模型和输入绑定',
        );
      }
      while (true) {
        check();
        final history = await _json(
          'history/${Uri.encodeComponent(id)}',
          token: token,
        );
        final entry = history[id];
        if (entry != null) {
          if (entry is! Map || entry['status'] is! Map) {
            throw const ProviderException('comfy_result', 'ComfyUI 返回了无效的任务状态');
          }
          final status = entry['status'] as Map;
          if (status['status_str'] == 'error') {
            throw const ProviderException(
              'comfy_execution',
              'ComfyUI 工作流执行失败，请在服务端查看节点错误',
            );
          }
          if (status['completed'] == true) {
            final outputs = entry['outputs'];
            final output = outputs is Map ? outputs[workflow.outputNode] : null;
            final images = output is Map ? output['images'] : null;
            if (images is! List ||
                images.length != 1 ||
                images.single is! Map) {
              throw const ProviderException(
                'comfy_result',
                '所选输出节点须返回一张图片，请检查输出节点并设置 batch_size 为 1',
              );
            }
            final file = images.single as Map;
            final name = file['filename'],
                folder = file['subfolder'] ?? '',
                type = file['type'];
            if (!_safeFile(name) ||
                !_safeFolder(folder) ||
                !['output', 'temp'].contains(type)) {
              throw const ProviderException(
                'comfy_result',
                'ComfyUI 返回了无效的图片路径',
              );
            }
            final bytes = await _bytes(
              'view',
              query: {'filename': name, 'subfolder': folder, 'type': type},
              token: token,
              limit: _maxImageBytes,
            );
            check();
            if (bytes.isEmpty) {
              throw const ProviderException('comfy_result', 'ComfyUI 返回了空图片');
            }
            return GeneratedImage(
              bytes: bytes,
              usage: {'prompt_id': id, 'seed': seed},
            );
          }
        }
        await Future.any([
          Future<void>.delayed(const Duration(seconds: 1)),
          stopped.future,
        ]);
      }
    } on DioException {
      check();
      throw const ProviderException(
        'comfy_connection',
        'ComfyUI 连接中断或超时，请检查服务端任务状态后再重试',
      );
    } finally {
      deadline.cancel();
      remove();
    }
  }

  static bool _safeFile(Object? name) =>
      name is String &&
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains(RegExp(r'[/\\\x00]'));
  static bool _safeFolder(Object? folder) =>
      folder is String &&
      !folder.startsWith('/') &&
      !folder.contains(RegExp(r'[\\\x00:]')) &&
      !folder.split('/').contains('..');

  Future<Map<String, dynamic>> _json(
    String path, {
    String method = 'GET',
    Object? data,
    CancelToken? token,
    int limit = 4 * 1024 * 1024,
  }) async {
    final bytes = await _bytes(
      path,
      method: method,
      data: data,
      token: token,
      limit: limit,
    );
    final json = _decode(bytes);
    if (json is Map<String, dynamic>) return json;
    throw const ProviderException('comfy_result', 'ComfyUI 返回的 JSON 格式无效');
  }

  static Object? _decode(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      // Report the protocol error without exposing server response bodies.
    }
    throw const ProviderException('comfy_result', 'ComfyUI 返回的 JSON 格式无效');
  }

  Future<Uint8List> _bytes(
    String path, {
    String method = 'GET',
    Object? data,
    Map<String, dynamic>? query,
    CancelToken? token,
    required int limit,
  }) async {
    final response = await _client.request<ResponseBody>(
      path,
      data: data,
      queryParameters: query,
      cancelToken: token,
      options: Options(
        method: method,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );
    if (response.statusCode == null ||
        response.statusCode! < 200 ||
        response.statusCode! >= 300) {
      await response.data?.stream.listen(null).cancel();
      throw ProviderException(
        'comfy_http',
        'ComfyUI 请求失败，请检查服务地址、工作流及模型',
        statusCode: response.statusCode,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (bytes.length + chunk.length > limit) {
        throw const ProviderException('comfy_size', 'ComfyUI 返回数据超出大小限制');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  void close() => _client.close(force: true);
}
