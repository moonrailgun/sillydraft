import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'image_provider.dart';
import 'local_cli.dart';
import 'provider.dart';

/// Uses Codex's native image tool and subscription, not an API key or shell skill.
/// Protocol: codex-cli 0.163.0 `app-server generate-json-schema --experimental`.
final class CodexImageProvider implements ImageProvider {
  CodexImageProvider({required this.config, CliLocator? locator})
    : _locator = locator ?? CliLocator.shared;

  @override
  final ModelConnection config;
  final CliLocator _locator;
  final _active = <GenerationCancellation>{};
  static const _maxImageBytes = 32 * 1024 * 1024;
  static const _disabledFeatures = [
    'hooks',
    'codex_hooks',
    'plugin_hooks',
    'plugins',
    'apps',
    'shell_tool',
    'unified_exec',
    'multi_agent',
    'browser_use',
    'computer_use',
    'js_repl',
    'code_mode',
  ];

  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? GenerationCancellation();
    _active.add(cancel);
    try {
      cancel.check();
      if (config.protocol != ModelProtocol.codexCli) {
        throw const ProviderException('image_protocol', '此连接不是 Codex 本地订阅');
      }
      if (request.retrieveOnly) {
        throw const ProviderException(
          'image_retrieve',
          'Codex 生图不支持恢复远端任务，请新建生成',
        );
      }
      for (final entry in request.parameters.entries) {
        if (!const {'size', 'quality', 'negative_prompt'}.contains(entry.key) ||
            entry.value is! String ||
            (entry.value as String).length > 32000) {
          throw ProviderException(
            'image_parameter',
            'Codex 生图不支持参数 ${entry.key}；仅支持尺寸、质量和负面提示词作为画面要求',
          );
        }
      }
      if (references.length > 16 ||
          references.fold<int>(0, (n, r) => n + r.bytes.length) >
              64 * 1024 * 1024) {
        throw const ProviderException(
          'image_references',
          '参考图最多 16 张，合计 64 MB',
        );
      }
      for (final ref in references) {
        if (!const {
              'image/png',
              'image/jpeg',
              'image/webp',
            }.contains(ref.mimeType) ||
            ref.bytes.isEmpty ||
            ref.bytes.length > _maxImageBytes) {
          throw const ProviderException(
            'image_reference',
            '参考图须为 32 MB 以内的 PNG、JPEG、WebP',
          );
        }
      }
      final executable = await _locator.find('codex', config.command);
      cancel.check();
      final workspace = await Directory.systemTemp.createTemp(
        'sillydraft-codex-image-',
      );
      try {
        return await _run(executable, workspace, request, references, cancel);
      } finally {
        await workspace.delete(recursive: true);
      }
    } finally {
      _active.remove(cancel);
    }
  }

  Future<GeneratedImage> _run(
    CliExecutable executable,
    Directory workspace,
    ImageRequest request,
    List<ImageReference> references,
    GenerationCancellation cancel,
  ) async {
    final Process process;
    try {
      process = await executable.start([
        'app-server',
        '--stdio',
        for (final feature in _disabledFeatures) ...[
          '-c',
          'features.$feature=false',
        ],
        '-c',
        'features.skip_host_skill_discovery=true',
        '-c',
        'features.image_generation=true',
        '-c',
        'features.imagegenext=true',
        '-c',
        'features.omit_app_server_notification_media=false',
        '-c',
        'project_doc_max_bytes=0',
        '-c',
        'web_search="disabled"',
        '-c',
        'notify=[]',
      ], workspace.path);
    } on ProcessException catch (error) {
      throw ProviderException(
        'cli_start',
        '无法启动 Codex（${error.message}），请检查安装和命令路径',
      );
    }
    final lines = StreamController<String>();
    void stop() {
      process.kill();
      if (!lines.isClosed) lines.close();
    }

    final removeCancel = cancel.onCancel(stop);
    var timedOut = false;
    final timer = Timer(const Duration(minutes: 10), () {
      timedOut = true;
      stop();
    });
    var responseBytes = 0;
    final stdout = process.stdout
        .map((chunk) {
          // Bound bytes before LineSplitter buffers a base64 image line.
          responseBytes += chunk.length;
          if (responseBytes > 64 * 1024 * 1024) {
            throw const ProviderException('response_limit', 'Codex 生图响应超过大小限制');
          }
          return chunk;
        })
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (!lines.isClosed) lines.add(line);
          },
          onError: (Object error, StackTrace stack) {
            if (!lines.isClosed) lines.addError(error, stack);
            stop();
          },
          onDone: () {
            if (!lines.isClosed) lines.close();
          },
        );
    final stderr = process.stderr.listen((_) {});
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!lines.isClosed) lines.addError(error, stack);
          stop();
        },
      ),
    );
    void send(String method, Map<String, dynamic> params, [int? id]) {
      process.stdin.writeln(
        jsonEncode({'id': ?id, 'method': method, 'params': params}),
      );
    }

    GeneratedImage? image;
    Map<String, dynamic> usage = {};
    try {
      cancel.check();
      send('initialize', {
        'clientInfo': {'name': 'sillydraft', 'version': '1.0.0'},
        'capabilities': {'experimentalApi': true},
      }, 1);
      await for (final line in lines.stream) {
        cancel.check();
        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          continue;
        }
        if (decoded is! Map<String, dynamic>) continue;
        if (decoded['error'] case final Map error) {
          throw ProviderException(
            'codex_image',
            'Codex 生图失败：${error['message'] ?? '协议错误'}',
          );
        }
        final method = decoded['method'];
        if (method != null && decoded.containsKey('id')) {
          // Approval and client tool requests must never hang or grant access.
          process.stdin.writeln(
            jsonEncode({
              'id': decoded['id'],
              'error': {
                'code': -32601,
                'message':
                    'SillyDraft only supports the native image generation tool',
              },
            }),
          );
          continue;
        }
        final result = decoded['result'];
        if (result is Map) {
          switch (decoded['id']) {
            case 1:
              send('initialized', {});
              send('config/read', {
                'includeLayers': false,
                'cwd': workspace.path,
              }, 2);
            case 2:
              final servers =
                  (result['config'] as Map?)?['mcp_servers'] as Map? ?? {};
              send('thread/start', {
                'cwd': workspace.path,
                'ephemeral': true,
                'sandbox': 'read-only',
                'approvalPolicy': 'never',
                'modelProvider': 'openai',
                if (config.model.trim().isNotEmpty &&
                    config.model.trim() != 'default')
                  'model': config.model.trim(),
                // An empty map merges with user config; disable each saved server.
                'config': {
                  'mcp_servers': {
                    for (final key in servers.keys) key: {'enabled': false},
                  },
                },
                'baseInstructions':
                    'Generate exactly one image with the built-in image generation tool. '
                    'Do not use shell commands, files, skills, MCP, web search, or external services. '
                    'Use the supplied reference images in order when present. '
                    'If the image tool is unavailable or fails, report the failure; do not substitute text or code.',
              }, 3);
            case 3:
              final threadId = (result['thread'] as Map?)?['id'];
              if (threadId is! String || threadId.isEmpty) {
                throw const ProviderException('codex_image', 'Codex 没有返回生图会话');
              }
              send('turn/start', {
                'threadId': threadId,
                'input': [
                  {
                    'type': 'text',
                    'text':
                        '${request.prompt}\n\n'
                        'Generate one image using the built-in image generation tool.'
                        '${references.isEmpty ? '' : '\nUse all ${references.length} attached reference images.'}'
                        '${request.parameters.isEmpty ? '' : '\nImage requirements: ${jsonEncode(request.parameters)}'}',
                  },
                  for (final ref in references)
                    {
                      'type': 'image',
                      'url':
                          'data:${ref.mimeType};base64,${base64Encode(ref.bytes)}',
                    },
                ],
              }, 4);
          }
        }
        final params = decoded['params'];
        if (params is! Map) continue;
        if (method == 'item/completed' && params['item'] is Map) {
          final item = params['item'] as Map;
          if (item['type'] == 'imageGeneration') {
            if (image != null) {
              throw const ProviderException(
                'image_result',
                'Codex 返回了多张图片，请每次只生成一张',
              );
            }
            image = _image(item);
          }
        } else if (method == 'thread/tokenUsage/updated') {
          final last = (params['tokenUsage'] as Map?)?['last'];
          if (last is Map) {
            usage = {
              if (last['inputTokens'] is num)
                'input_tokens': last['inputTokens'],
              if (last['outputTokens'] is num)
                'output_tokens': last['outputTokens'],
            };
          }
        } else if (method == 'turn/completed') {
          final turn = params['turn'] as Map?;
          if (turn?['status'] != 'completed') {
            throw ProviderException(
              'codex_image',
              'Codex 生图未完成：${(turn?['error'] as Map?)?['message'] ?? turn?['status'] ?? '未知错误'}',
            );
          }
          if (image == null) {
            throw const ProviderException(
              'image_result',
              'Codex 未返回图片，请确认已登录且当前 Codex 版本和账号支持内置生图工具',
            );
          }
          return GeneratedImage(
            bytes: image.bytes,
            revisedPrompt: image.revisedPrompt,
            usage: usage,
          );
        }
      }
      cancel.check();
      throw ProviderException(
        timedOut ? 'cli_timeout' : 'cli_error',
        timedOut
            ? 'Codex 生图等待超过 10 分钟，已停止等待'
            : 'Codex 生图进程提前结束，请检查安装、登录状态并更新 Codex',
      );
    } on FormatException {
      throw const ProviderException('image_result', 'Codex 返回了无效的图片数据');
    } on IOException {
      cancel.check();
      throw const ProviderException('cli_error', 'Codex 生图进程通信失败，请检查安装和登录状态');
    } finally {
      timer.cancel();
      removeCancel();
      stop();
      unawaited(process.stdin.close().catchError((Object _) {}));
      await stdout.cancel();
      await stderr.cancel();
      // SIGTERM is advisory; do not leave a provider process alive on disposal.
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  GeneratedImage _image(Map item) {
    if (item['status'] != 'completed') {
      throw const ProviderException('image_result', 'Codex 内置生图工具未完成生成');
    }
    final result = item['result'];
    if (result is! String ||
        result.isEmpty ||
        result.length > 48 * 1024 * 1024) {
      throw const ProviderException(
        'image_result',
        'Codex 未返回可读取的图片数据，请更新 Codex 后重试',
      );
    }
    final bytes = base64Decode(result);
    if (bytes.isEmpty || bytes.length > _maxImageBytes) {
      throw const ProviderException('image_size', '图片为空或超过 32 MB');
    }
    return GeneratedImage(
      bytes: bytes,
      revisedPrompt: item['revisedPrompt'] as String? ?? '',
    );
  }

  @override
  void close() {
    for (final cancel in _active.toList()) {
      cancel.cancel();
    }
  }
}
