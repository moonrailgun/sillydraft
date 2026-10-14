import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../model/persona.dart';
import '../providers/image_provider.dart';
import '../providers/provider.dart';
import '../st/import_types.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';
import 'illustration_service.dart';

const _describe =
    '你是角色设定助手。根据参考图写出人物的外貌与服饰。用户消息先给出现有字段（JSON），再附参考图。'
    '只输出一个 JSON 对象，不要其他文字：'
    '{"appearance": "脸型、五官、发型发色、瞳色、体型等不随衣着改变的特征", '
    '"outfit": "图中的服装、鞋子与配饰", '
    '"description": "由图推测的年龄、气质与身份，一两句"}。'
    '用中文，简洁具体，不写构图与背景。';

const _refine =
    '你是角色设定助手。用户消息给出一个人设的现有字段（JSON），可能只有只言片语。'
    '补全并润色四个字段，保留已有设定，不要自相矛盾。只输出一个 JSON 对象，不要其他文字：'
    '{"name": "名字", "description": "身份、性格与经历，100 到 200 字", '
    '"appearance": "不随衣着改变的外貌特征", "outfit": "日常默认服饰"}。用中文。';

const _tags =
    '把用户消息中人物的外貌与服饰（JSON）写成 Danbooru 风格的英文标签，逗号分隔，以 solo 开头，'
    '用于单人全身角色参考图。只输出一个 JSON 对象：{"prompt": "..."}。';

const _sentence =
    '把用户消息中人物的外貌与服饰（JSON）写成一段英文生图描述：单人、全身、纯色背景的角色参考图。'
    '只输出一个 JSON 对象：{"prompt": "..."}。';

/// Model help for filling in a persona. Results only fill the form; the
/// author decides what to save.
final class PersonaService {
  const PersonaService({required this.repository, required this.runner});
  final StoryRepository repository;
  final TaskRunner runner;

  /// Appearance and outfit from the first four reference images, and a
  /// description when [draft] has none.
  Future<Persona> describeImages(
    ModelConnection connection,
    Persona draft, {
    GenerationCancellation? cancellation,
  }) async {
    if (draft.images.isEmpty) throw const FormatException('请先添加参考图');
    if (connection.protocol.isLocalCli) {
      throw const FormatException('当前资料整理模型不支持看图，请改用 OpenAI 兼容连接');
    }
    final library = runner.assetLibrary ?? (throw StateError('本地图片目录尚未配置'));
    final reply = await _ask(connection, _describe, [
      {'type': 'text', 'text': jsonEncode(draft.snapshot)},
      // ponytail: 480px thumbnails keep requests small; send larger copies
      // if descriptions miss fine detail.
      for (final image in draft.images.take(4))
        {
          'type': 'image_url',
          'image_url': {
            'url':
                'data:image/jpeg;base64,${base64Encode(await library.readHash(image.thumbnailHash, thumbnail: true))}',
          },
        },
    ], cancellation);
    return draft.copyWith(
      appearance: _text(reply, 'appearance'),
      outfit: _text(reply, 'outfit'),
      description:
          draft.description.trim().isEmpty && reply['description'] is String
          ? _text(reply, 'description')
          : null,
    );
  }

  /// Fills and polishes every field from whatever [draft] has; a written
  /// name stays.
  Future<Persona> refine(
    ModelConnection connection,
    Persona draft, {
    GenerationCancellation? cancellation,
  }) async {
    final reply = await _ask(
      connection,
      _refine,
      jsonEncode(draft.snapshot),
      cancellation,
    );
    return draft.copyWith(
      name: draft.name.trim().isEmpty ? _text(reply, 'name') : null,
      description: _text(reply, 'description'),
      appearance: _text(reply, 'appearance'),
      outfit: _text(reply, 'outfit'),
    );
  }

  /// An image prompt for [painter]: Danbooru tags for NovelAI and ComfyUI,
  /// an English sentence for other image models.
  Future<String> imagePrompt(
    ModelConnection connection,
    Persona draft,
    ModelConnection painter, {
    GenerationCancellation? cancellation,
  }) async {
    if (draft.appearance.trim().isEmpty && draft.outfit.trim().isEmpty) {
      throw const FormatException('请先填写外貌或默认服饰');
    }
    final tags =
        painter.protocol == ModelProtocol.novelAI ||
        painter.protocol == ModelProtocol.comfyUI;
    final reply = await _ask(
      connection,
      tags ? _tags : _sentence,
      jsonEncode({'appearance': draft.appearance, 'outfit': draft.outfit}),
      cancellation,
    );
    return _text(reply, 'prompt');
  }

  /// One reference image from [prompt], with the painter's saved defaults.
  Future<PersonaImage> generateImage(
    ModelConnection painter,
    String prompt, {
    GenerationCancellation? cancellation,
  }) async {
    final factory = runner.imageProviderFactory, library = runner.assetLibrary;
    if (factory == null || library == null) {
      throw StateError('生图服务或本地图片目录尚未配置');
    }
    final illustrations = IllustrationService(
      repository: repository,
      runner: runner,
    );
    final frozen = await illustrations.withLatestWorkflow(painter);
    var request = IllustrationService.requestFrom(
      frozen,
      prompt,
      await illustrations.savedDefaults(painter),
    );
    if (frozen.protocol == ModelProtocol.sillyDraftRunner) {
      // A remote runner keeps jobs by ID; this one is never resumed.
      request = ImageRequest.fromJson({
        ...request.raw,
        'executionId': 'persona-${const Uuid().v4()}',
      });
    }
    final provider = await factory(frozen);
    try {
      final output = await provider.generate(
        request,
        cancellation: cancellation,
      );
      return PersonaImage.of(await library.prepare(output.bytes));
    } finally {
      provider.close();
    }
  }

  Future<Map<String, dynamic>> _ask(
    ModelConnection connection,
    String instructions,
    Object content,
    GenerationCancellation? cancellation,
  ) async {
    final provider = await runner.providerFactory(connection);
    try {
      final text = StringBuffer();
      await for (final event in provider.generate(
        ProviderRequest(
          messages: [
            {'role': 'system', 'content': instructions},
            {'role': 'user', 'content': content},
          ],
          // A remote runner keeps jobs by ID; this one is never resumed.
          executionId: 'persona-${const Uuid().v4()}',
        ),
        cancellation: cancellation,
      )) {
        if (event is TextDelta) text.write(event.text);
      }
      final cleaned = text
          .toString()
          .trim()
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
      try {
        return jsonObject(jsonDecode(cleaned), 'reply');
      } on FormatException {
        throw const FormatException('模型没有按要求返回 JSON，请重试');
      }
    } finally {
      provider.close();
    }
  }

  static String _text(Map<String, dynamic> reply, String key) {
    final value = reply[key];
    if (value is! String) throw FormatException('模型回复缺少 $key');
    return value.trim();
  }
}
