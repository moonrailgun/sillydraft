import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../transfer/safe_archive.dart';
import 'image_provider.dart';
import 'provider.dart';

final class NovelAIImageProvider implements ImageProvider {
  NovelAIImageProvider({required this.config, required this._apiKey})
    : _client = Dio(
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
  static const _maxBytes = 32 * 1024 * 1024;
  // ST 1.19.0 stable-diffusion `loadNovelModels`, in its order (see
  // test/fixtures/st/novelai-models-reference.json). Not a live model
  // discovery API; manual IDs remain valid.
  static const models = [
    'nai-diffusion-4-5-full',
    'nai-diffusion-4-5-curated',
    'nai-diffusion-4-full',
    'nai-diffusion-4-curated-preview',
    'nai-diffusion-3',
    'nai-diffusion-2',
    'nai-diffusion-furry-3',
  ];

  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final signal = cancellation ?? GenerationCancellation(),
        token = CancelToken();
    final remove = signal.onCancel(() => token.cancel());
    // shortcut: cancellation stops waiting locally; add server cancellation if NovelAI exposes a per-request API.
    final deadline = Timer(const Duration(minutes: 10), () => token.cancel());
    try {
      signal.check();
      if (config.protocol != ModelProtocol.novelAI) {
        throw const ProviderException('image_protocol', '请选择 NovelAI 生图连接');
      }
      if (_apiKey.trim().isEmpty) {
        throw const ProviderException(
          'novelai_key',
          '请在模型设置中填写 NovelAI API Key',
        );
      }
      if (references.isNotEmpty) {
        throw const ProviderException(
          'novelai_reference',
          'NovelAI 连接目前仅支持文生图，请移除参考图',
        );
      }
      final parameters = _parameters(request);
      final response = await _client.post<ResponseBody>(
        '${config.baseUrl.replaceFirst(RegExp(r'/+$'), '')}/ai/generate-image',
        data: {
          'input': request.prompt,
          'model': config.model,
          'action': 'generate',
          'parameters': parameters,
        },
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          },
        ),
        cancelToken: token,
      );
      if (response.statusCode == null ||
          response.statusCode! < 200 ||
          response.statusCode! >= 300) {
        await response.data?.stream.listen(null).cancel();
        throw ProviderException(
          'novelai_http',
          'NovelAI 生图失败，请检查密钥、模型、参数与额度',
          statusCode: response.statusCode,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        signal.check();
        if (bytes.length + chunk.length > _maxBytes) {
          token.cancel();
          throw const ProviderException('novelai_size', 'NovelAI 生图结果超过 32 MB');
        }
        bytes.add(chunk);
      }
      signal.check();
      final files = readSafeZip(
        bytes.takeBytes(),
        maxExpandedBytes: _maxBytes,
        maxEntries: 16,
      );
      final images = files.entries
          .where((e) => e.key.toLowerCase().endsWith('.png'))
          .toList();
      if (images.length != 1) throw const FormatException('Expected one PNG');
      final image = images.single.value;
      const signature = [137, 80, 78, 71, 13, 10, 26, 10];
      if (image.length < signature.length ||
          !signature.indexed.every((entry) => image[entry.$1] == entry.$2)) {
        throw const FormatException('Invalid PNG');
      }
      return GeneratedImage(bytes: image);
    } on DioException {
      signal.check();
      throw const ProviderException(
        'novelai_connection',
        'NovelAI 连接中断或超时，请检查网络后手动重试',
      );
    } on FormatException {
      throw const ProviderException(
        'novelai_result',
        'NovelAI 返回的图片压缩包无效或超出限制',
      );
    } finally {
      deadline.cancel();
      remove();
    }
  }

  Map<String, dynamic> _parameters(ImageRequest request) {
    final supplied = {...request.parameters};
    const allowed = {
      'size',
      'width',
      'height',
      'steps',
      'scale',
      'seed',
      'sampler',
      'noise_schedule',
      'negative_prompt',
      'cfg_rescale',
      'sm',
      'sm_dyn',
      'dynamic_thresholding',
    };
    for (final key in supplied.keys) {
      if (!allowed.contains(key)) {
        throw ProviderException('novelai_parameter', 'NovelAI 不支持参数 $key');
      }
    }
    final size = supplied.remove('size');
    if (size != null && size != 'auto') {
      final match = size is String
          ? RegExp(r'^(\d+)x(\d+)$').firstMatch(size)
          : null;
      final width = match == null ? null : int.tryParse(match[1]!);
      final height = match == null ? null : int.tryParse(match[2]!);
      if (width == null || height == null) {
        throw const ProviderException(
          'novelai_parameter',
          '尺寸须为宽x高，例如 832x1216',
        );
      }
      supplied.addAll({'width': width, 'height': height});
    }
    final p = <String, dynamic>{
      'width': 1024,
      'height': 1024,
      'steps': 28,
      'scale': 5.0,
      'seed': -1,
      'sampler': 'k_euler_ancestral',
      'noise_schedule': 'karras',
      'negative_prompt': '',
      'cfg_rescale': 0.0,
      'sm': false,
      'sm_dyn': false,
      'dynamic_thresholding': false,
      ...supplied,
    };
    for (final key in ['width', 'height', 'steps', 'seed']) {
      final value = p[key];
      final valid =
          value is int &&
          (switch (key) {
            'width' ||
            'height' => value >= 64 && value <= 4096 && value % 64 == 0,
            'steps' => value >= 1 && value <= 50,
            _ => value >= -1 && value <= 0xffffffff,
          });
      if (!valid) {
        throw ProviderException(
          'novelai_parameter',
          'NovelAI 参数 $key 超出范围或不是整数',
        );
      }
    }
    for (final key in ['scale', 'cfg_rescale']) {
      final value = p[key];
      if (value is! num ||
          !value.isFinite ||
          value < 0 ||
          value > (key == 'scale' ? 50 : 1)) {
        throw ProviderException('novelai_parameter', 'NovelAI 参数 $key 数值无效');
      }
    }
    for (final key in ['sampler', 'noise_schedule', 'negative_prompt']) {
      final value = p[key];
      if (value is! String ||
          value.length > 32000 ||
          (key != 'negative_prompt' && value.trim().isEmpty)) {
        throw ProviderException('novelai_parameter', 'NovelAI 参数 $key 文本无效');
      }
    }
    for (final key in ['sm', 'sm_dyn', 'dynamic_thresholding']) {
      if (p[key] is! bool) {
        throw ProviderException('novelai_parameter', 'NovelAI 参数 $key 须为布尔值');
      }
    }
    if (p['seed'] == -1) p['seed'] = Random.secure().nextInt(0x100000000);
    // Match ST 1.19.0 (06bde939), src/endpoints/novelai.js /generate-image.
    return {
      ...p,
      'params_version': 3,
      'n_samples': 1,
      'prefer_brownian': true,
      'ucPreset': 0,
      'qualityToggle': false,
      'add_original_image': false,
      'controlnet_strength': 1,
      'deliberate_euler_ancestral_bug': false,
      'legacy': false,
      'legacy_v3_extend': false,
      'uncond_scale': 1,
      'use_coords': false,
      'characterPrompts': <Object?>[],
      'reference_image_multiple': <String>[],
      'reference_information_extracted_multiple': <double>[],
      'reference_strength_multiple': <double>[],
      'v4_prompt': {
        'caption': {
          'base_caption': request.prompt,
          'char_captions': <Object?>[],
        },
        'use_coords': false,
        'use_order': true,
      },
      'v4_negative_prompt': {
        'caption': {
          'base_caption': p['negative_prompt'],
          'char_captions': <Object?>[],
        },
      },
    };
  }

  @override
  void close() => _client.close(force: true);
}
