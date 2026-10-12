import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'image_provider.dart';
import 'provider.dart';

/// Images API uses separate generation/edit contracts. No automatic network
/// retries: retrying may create another billed image and is a new task.
final class OpenAIImageProvider implements ImageProvider {
  OpenAIImageProvider({
    required this.config,
    required this._apiKey,
    Dio? client,
  }) : _client =
           client ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 20),
               sendTimeout: const Duration(minutes: 2),
               receiveTimeout: const Duration(minutes: 10),
               followRedirects: false,
             ),
           );
  @override
  final ModelConnection config;
  final String _apiKey;
  final Dio _client;
  static const _maxImageBytes = 32 * 1024 * 1024,
      _maxResponseBytes = 48 * 1024 * 1024;
  static const _parameters = {
    'size',
    'quality',
    'background',
    'output_format',
    'output_compression',
    'response_format',
    'seed',
    'style',
    'negative_prompt',
  };
  static const _reserved = {
    'model',
    'prompt',
    'n',
    'image',
    'images',
    'mask',
    'stream',
    'api_key',
    'authorization',
    'headers',
    'url',
    'endpoint',
    'base_url',
  };
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final signal = cancellation ?? GenerationCancellation(),
        token = CancelToken();
    final remove = signal.onCancel(() => token.cancel());
    try {
      signal.check();
      if (config.protocol != ModelProtocol.openAICompatible) {
        throw const ProviderException('image_protocol', '此连接未实现 OpenAI 兼容生图接口');
      }
      for (final key in request.parameters.keys) {
        if (_reserved.contains(key.toLowerCase()) ||
            (!_parameters.contains(key) &&
                !config.extraParameters.contains(key))) {
          throw ProviderException('image_parameter', '生图连接未启用参数 $key');
        }
      }
      if (references.length > 16 ||
          references.fold<int>(0, (a, b) => a + b.bytes.length) >
              64 * 1024 * 1024) {
        throw const ProviderException(
          'image_references',
          '参考图最多 16 张，合计 64 MB',
        );
      }
      final body = <String, dynamic>{
        'model': config.model,
        'prompt': request.prompt,
        'n': 1,
        ...request.parameters,
      };
      Object payload = body;
      if (references.isNotEmpty) {
        final form = FormData.fromMap(body);
        for (final (i, ref) in references.indexed) {
          final extension = const {
            'image/png': 'png',
            'image/jpeg': 'jpg',
            'image/webp': 'webp',
          }[ref.mimeType];
          if (extension == null ||
              ref.bytes.isEmpty ||
              ref.bytes.length > _maxImageBytes) {
            throw const ProviderException(
              'image_reference',
              '参考图须为 32 MB 以内的 PNG、JPEG、WebP',
            );
          }
          form.files.add(
            MapEntry(
              'image[]',
              MultipartFile.fromBytes(
                ref.bytes,
                filename: 'reference-$i.$extension',
                contentType: DioMediaType.parse(ref.mimeType),
              ),
            ),
          );
        }
        payload = form;
      }
      final endpoint = references.isEmpty
          ? 'images/generations'
          : 'images/edits';
      final response = await _client.post<ResponseBody>(
        '${config.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/$endpoint',
        data: payload,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
            if (references.isEmpty) 'Content-Type': 'application/json',
          },
        ),
        cancelToken: token,
      );
      if (response.statusCode == null ||
          response.statusCode! < 200 ||
          response.statusCode! >= 300) {
        await response.data?.stream.listen(null).cancel();
        throw ProviderException(
          'image_http',
          '生图服务请求失败，请检查模型、参数与额度',
          statusCode: response.statusCode,
        );
      }
      final bytes = await _collect(
        response.data!,
        _maxResponseBytes,
        signal,
        token,
      );
      final raw = jsonDecode(utf8.decode(bytes));
      if (raw is! Map<String, dynamic> ||
          raw['data'] is! List ||
          (raw['data'] as List).length != 1) {
        throw const ProviderException('image_result', '生图服务没有返回单张图片');
      }
      final item = (raw['data'] as List).single;
      if (item is! Map<String, dynamic>) {
        throw const ProviderException('image_result', '生图结果格式无效');
      }
      Uint8List image;
      if (item['b64_json'] case final String encoded) {
        if (encoded.length > _maxResponseBytes) {
          throw const ProviderException('image_size', '图片超过 32 MB');
        }
        image = base64Decode(encoded);
      } else if (item['url'] case final String location) {
        final uri = Uri.tryParse(location), base = Uri.parse(config.baseUrl);
        final valid =
            uri != null &&
            uri.userInfo.isEmpty &&
            !uri.hasFragment &&
            ['http', 'https'].contains(uri.scheme) &&
            uri.host.isNotEmpty;
        final sameOrigin =
            valid &&
            uri.scheme == base.scheme &&
            uri.host == base.host &&
            uri.port == base.port;
        final allowed =
            valid &&
            uri.scheme == 'https' &&
            request.allowedDownloadHosts.any(
              (h) => h.toLowerCase() == uri.host.toLowerCase(),
            );
        if (!sameOrigin && !allowed) {
          throw const ProviderException(
            'image_download_origin',
            '服务返回了未配置域名的图片链接。请使用 Base64 返回格式，或在生图设置中允许该图片下载域名。',
          );
        }
        // A fresh client prevents model credentials or interceptors leaking to
        // image storage, including storage on the same origin.
        final download = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(minutes: 2),
            followRedirects: false,
          ),
        );
        try {
          final result = await download.get<ResponseBody>(
            uri.toString(),
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: false,
              validateStatus: (_) => true,
            ),
            cancelToken: token,
          );
          if (result.statusCode != 200) {
            await result.data?.stream.listen(null).cancel();
            throw ProviderException(
              'image_download',
              '下载图片失败',
              statusCode: result.statusCode,
            );
          }
          image = await _collect(result.data!, _maxImageBytes, signal, token);
        } finally {
          download.close(force: true);
        }
      } else {
        throw const ProviderException('image_result', '生图服务没有返回图片数据');
      }
      signal.check();
      if (image.isEmpty || image.length > _maxImageBytes) {
        throw const ProviderException('image_size', '图片为空或超过 32 MB');
      }
      return GeneratedImage(
        bytes: image,
        revisedPrompt: item['revised_prompt'] as String? ?? '',
        usage: raw['usage'] is Map<String, dynamic>
            ? raw['usage'] as Map<String, dynamic>
            : {},
      );
    } on DioException catch (e) {
      if (signal.isCancelled || CancelToken.isCancel(e)) {
        throw const GenerationCancelled();
      }
      throw const ProviderException('image_connection', '生图连接中断或超时，请检查网络后手动重试');
    } on FormatException {
      throw const ProviderException('image_result', '生图服务返回了无效的图片数据');
    } finally {
      remove();
    }
  }

  Future<Uint8List> _collect(
    ResponseBody body,
    int limit,
    GenerationCancellation signal,
    CancelToken token,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      signal.check();
      if (bytes.length + chunk.length > limit) {
        token.cancel();
        throw const ProviderException('image_size', '生图结果超出大小限制');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  @override
  void close() => _client.close(force: true);
}
