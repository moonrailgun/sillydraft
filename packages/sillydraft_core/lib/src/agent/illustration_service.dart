import 'dart:async';

import '../model/asset.dart';
import '../model/illustration_graph.dart';
import '../model/lore.dart';
import 'visual_reference.dart';
export 'visual_reference.dart';
import '../model/task.dart';
import '../providers/image_provider.dart';
import '../providers/comfy_workflow.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';

final class IllustrationService {
  static const _characterFraming =
      'Single character reference, full body, neutral pose, plain background, no text. ';
  static const _locationFraming =
      'Empty location reference, clear architecture and spatial layout, no people, no text. ';
  const IllustrationService({required this.repository, required this.runner});
  final StoryRepository repository;
  final TaskControl runner;

  /// Remove only the context suffix we can reconstruct from the saved inputs.
  static String sourcePrompt(StoryAsset asset, {bool tags = false}) {
    if (asset.metadata['sourcePrompt'] case final String prompt) return prompt;
    final prompt =
        asset.metadata['prompt'] as String? ??
        asset.metadata['referencePrompt'] as String? ??
        '';
    final visual = [
      for (final r in IllustrationGraph.visualSnapshots(asset))
        VisualReference(
          kind: LoreKind.values.byName(r['kind'] as String),
          name: r['name'] as String,
          prompt: r['prompt'] as String,
          assetId: r['assetId'] as String?,
        ),
    ];
    final labels = [
      for (final raw in asset.metadata['references'] as List? ?? [])
        if (raw is Map)
          () {
            final ref = visual.where((r) => r.assetId == raw['id']).firstOrNull;
            return ref == null
                ? 'previous view of this scene'
                : '${ref.kind.name} ${ref.name}';
          }(),
    ];
    final suffix = visualPrompt(
      '',
      visual,
      (asset.metadata['scene'] as Map?)?.cast<String, dynamic>(),
      tags: tags,
      imageLabels: labels,
    );
    return suffix.isNotEmpty && prompt.endsWith(suffix)
        ? prompt.substring(0, prompt.length - suffix.length)
        : prompt;
  }

  Future<GenerationTask> regenerate({
    required String branchId,
    required String assetId,
    required ModelConnection connection,
    String? prompt,
  }) async {
    final graph = await repository.illustrationGraph(branchId);
    final asset = graph.current(assetId);
    final previous = asset.taskId == null
        ? null
        : await repository.getTask(asset.taskId!);
    final oldConnection = previous?.input['connection'];
    final tags =
        oldConnection is Map &&
        ModelConnection.fromJson(oldConnection.cast<String, dynamic>())
                .protocol ==
            ModelProtocol.novelAI;
    final source = (prompt ?? sourcePrompt(asset, tags: tags)).trim();
    if (source.isEmpty) throw const FormatException('这张图片没有生成提示词，请先填写画面描述');
    String? referencePrompt;
    if (source != sourcePrompt(asset, tags: tags).trim() &&
        (asset.metadata['referenceKind'] != null ||
            graph.lore.any(
              (e) => (e.data['images'] as List? ?? []).contains(asset.id),
            ))) {
      referencePrompt = source;
      for (final framing in [_characterFraming, _locationFraming]) {
        if (referencePrompt!.startsWith(framing)) {
          referencePrompt = referencePrompt.substring(framing.length).trim();
        }
      }
      if (referencePrompt!.isEmpty || referencePrompt.length > 4000) {
        throw const FormatException('参考图的画面描述须为不超过 4000 字的文本');
      }
    }
    final savedVisual = IllustrationGraph.visualSnapshots(asset);
    final currentVisual = graph.visualReferences(asset);
    for (var i = 0; i < savedVisual.length; i++) {
      if (savedVisual[i]['assetId'] != null &&
          currentVisual[i]['assetId'] == null) {
        throw const FormatException('参考图已移除，请先补充参考图或重新规划这张插图');
      }
    }
    for (final id in graph.referenceIds(asset)) {
      if (!graph.assets.containsKey(id)) {
        throw const FormatException('关联图片不存在，请先恢复参考图');
      }
    }
    final visual = <VisualReference>[];
    for (final raw in currentVisual) {
      final entry = graph.lore.where((e) => e.id == raw['loreId']).firstOrNull;
      if (raw['loreId'] != null && entry == null) {
        throw const FormatException('参考资料已删除，请先恢复资料或重新规划这张插图');
      }
      visual.add(
        VisualReference(
          kind: LoreKind.values.byName(raw['kind'] as String),
          name: raw['name'] as String,
          prompt: raw['prompt'] as String,
          assetId: raw['assetId'] as String?,
          entry: entry,
        ),
      );
    }
    final stored = previous?.input['imageRequest'];
    final request = stored is Map
        ? ImageRequest.fromJson({
            ...stored.cast<String, dynamic>(),
            'prompt': source,
          })
        : requestFrom(connection, source, await savedDefaults(connection));
    final previousScene =
        asset.metadata['previousSceneAssetId'] as String? ??
        (asset.metadata['references'] as List? ?? [])
                .whereType<Map>()
                .where(
                  (r) =>
                      !IllustrationGraph.visualSnapshots(asset)
                          .any((v) => v['assetId'] == r['id']),
                )
                .firstOrNull?['id']
            as String?;
    final chapters = {
      for (final chapter in graph.placements(asset.id))
        chapter.id: chapter.revisionId,
    };
    final sourceChapter = graph.chapters
        .where((c) => c.id == asset.sourceChapterId)
        .firstOrNull;
    if (sourceChapter != null) {
      chapters[sourceChapter.id] = sourceChapter.revisionId;
    }
    return generate(
      branchId: branchId,
      connection: connection,
      name: asset.name,
      chapterId: sourceChapter?.id,
      request: request,
      purpose: asset.purpose,
      referenceAssetIds: graph.referenceIds(asset),
      visualReferences: visual,
      scene: (asset.metadata['scene'] as Map?)?.cast<String, dynamic>(),
      previousSceneAssetId: previousScene == null
          ? null
          : graph.current(previousScene).id,
      illustrationAnchor: (asset.metadata['illustrationAnchor'] as Map?)
          ?.cast<String, dynamic>(),
      regeneration: {
        'assetId': asset.id,
        'referencePrompt': ?referencePrompt,
        'referenceState': graph.referenceState(asset),
        'chapters': chapters,
        'lore': {
          for (final e in graph.lore)
            if ((e.data['images'] as List? ?? []).contains(asset.id))
              e.id: e.revisionId,
        },
      },
    );
  }

  /// What the author last chose on the illustration page for [connection]:
  /// size, quality, extra parameters and download hosts.
  Future<Map<String, dynamic>> savedDefaults(
    ModelConnection connection,
  ) async =>
      await repository.getSetting(
        'imageDefaults/${connection.id}/${Uri.encodeComponent(connection.model)}',
      ) ??
      (connection.protocol != ModelProtocol.comfyUI
          ? await repository.getSetting('imageDefaults/${connection.id}')
          : null) ??
      {};

  /// [prompt] with [saved] defaults, as the illustration page would send it.
  static ImageRequest requestFrom(
    ModelConnection connection,
    String prompt,
    Map<String, dynamic> saved,
  ) {
    final comfy = connection.protocol == ModelProtocol.comfyUI,
        novelAI = connection.protocol == ModelProtocol.novelAI,
        size = saved['size'] as String? ?? '',
        quality = saved['quality'] as String? ?? '';
    return ImageRequest(
      prompt: prompt,
      parameters: {
        ...(saved['parameters'] as Map? ?? {}).cast<String, dynamic>(),
        if (!comfy && size.isNotEmpty) 'size': size,
        if (!comfy && !novelAI && quality.isNotEmpty) 'quality': quality,
      },
      allowedDownloadHosts: (saved['allowedDownloadHosts'] as List? ?? [])
          .cast<String>(),
    );
  }

  /// [connection] with the ComfyUI workflow a run uses re-read from the
  /// server, so it runs the nodes the author last saved there. Runs with
  /// [references] use the edit workflow when there is one; the other stays
  /// as saved, so a broken file only fails the runs that need it.
  Future<ModelConnection> withLatestWorkflow(
    ModelConnection connection, {
    bool references = false,
  }) async {
    final edit = references && connection.comfyEditWorkflow != null;
    final workflow = edit
        ? connection.comfyEditWorkflow
        : connection.comfyWorkflow;
    if (connection.protocol != ModelProtocol.comfyUI ||
        workflow == null ||
        workflow.filename.isEmpty) {
      return connection;
    }
    final factory = runner.imageProviderFactory;
    if (factory == null) throw StateError('未配置生图执行器');
    final provider = await factory(connection);
    final label = '${edit ? '图生图工作流' : '工作流'} ${workflow.filename}';
    try {
      if (provider is! WorkflowSource) {
        throw const ProviderException('comfy_workflow', '此执行器无法读取 ComfyUI 工作流');
      }
      final source = provider as WorkflowSource;
      return ModelConnection.fromJson({
        ...connection.raw,
        edit ? 'comfyEditWorkflow' : 'comfyWorkflow': ComfyWorkflow.fromJson({
          ...workflow.raw,
          'nodes': await source.readWorkflow(workflow.filename),
        }).raw,
      });
    } on ProviderException catch (e) {
      throw ProviderException(
        e.code,
        '$label：${e.message}',
        statusCode: e.statusCode,
      );
    } on FormatException catch (e) {
      throw FormatException('$label：${e.message}');
    } finally {
      provider.close();
    }
  }

  Future<List<VisualReference>> planReferences({
    required String branchId,
    required List<dynamic> subjects,
    String? chapterId,
  }) async {
    if (subjects.length > 16) throw const FormatException('最多指定 16 个人物或地点');
    final lore = await repository.listLore(
      branchId,
      throughChapterId: chapterId,
    );
    final result = <VisualReference>[];
    for (final subject in subjects) {
      if (subject is! Map ||
          subject.keys.any(
            (k) => !['kind', 'name', 'prompt', 'loreId'].contains(k),
          ) ||
          !['character', 'location'].contains(subject['kind']) ||
          subject['name'] is! String ||
          (subject['name'] as String).trim().isEmpty ||
          (subject['name'] as String).length > 100 ||
          subject['prompt'] is! String ||
          (subject['prompt'] as String).trim().isEmpty ||
          (subject['prompt'] as String).length > 4000 ||
          (subject['loreId'] != null && subject['loreId'] is! String)) {
        throw const FormatException('人物和地点须提供类型、名称及固定外观描述');
      }
      final kind = LoreKind.values.byName(subject['kind'] as String);
      final name = (subject['name'] as String).trim();
      final matches = lore
          .where(
            (e) => (subject['loreId'] != null
                ? e.id == subject['loreId']
                : e.kind == kind && e.name == name),
          )
          .toList();
      if (matches.length > 1 ||
          (subject['loreId'] != null && matches.isEmpty)) {
        throw const FormatException('人物或地点资料不明确，请使用当前参考范围可见的资料 id');
      }
      final entry = matches.firstOrNull;
      if (entry != null && entry.kind != kind) {
        throw FormatException(
          'subjects.loreId=${entry.id} 的资料类型是 ${entry.kind.name}，'
          '与 subjects.kind=${kind.name} 不匹配。'
          '请用 list_lore 选择当前参考范围可见且 kind=${kind.name} 的资料 id。',
        );
      }
      final saved = entry?.data['referencePrompt'] as String? ?? '';
      final ref = VisualReference(
        kind: kind,
        name: entry?.name ?? name,
        prompt: saved.trim().isEmpty
            ? (subject['prompt'] as String).trim()
            : saved,
        entry: entry,
        assetId: (entry?.data['images'] as List?)?.firstOrNull as String?,
      );
      if (result.any((r) => r.key == ref.key)) {
        throw const FormatException('同一画面的人物或地点重复');
      }
      if (ref.assetId != null) {
        final asset = await repository.getAsset(ref.assetId!);
        if (asset.novelId != (await repository.getBranch(branchId)).novelId) {
          throw const FormatException('参考图不属于当前作品');
        }
      }
      result.add(ref);
    }
    return result;
  }

  Future<void> ensureReference({
    required String branchId,
    required ModelConnection connection,
    required VisualReference reference,
    String? chapterId,
    Map<String, dynamic> defaults = const {},
    GenerationCancellation? cancellation,
  }) async {
    cancellation?.check();
    final old = reference.entry;
    if (old != null) {
      final current = await repository.getLoreEntry(
        branchId: branchId,
        id: old.id,
        throughChapterId: chapterId,
      );
      if (current.revisionId != old.revisionId) throw const LoreConflict();
    } else {
      final current = await repository.listLore(
        branchId,
        throughChapterId: chapterId,
        kind: reference.kind,
      );
      if (current.any((e) => e.name == reference.name)) {
        throw const LoreConflict();
      }
    }
    if (reference.assetId == null) {
      final framing = reference.kind == LoreKind.character
          ? _characterFraming
          : _locationFraming;
      final child = await generate(
        branchId: branchId,
        connection: connection,
        name: '${reference.name} · 参考图',
        chapterId: chapterId,
        request: requestFrom(
          connection,
          '$framing${reference.prompt}',
          defaults,
        ),
        purpose: AssetPurpose.reference,
      );
      final remove = cancellation?.onCancel(
        () => unawaited(runner.cancel(child.id)),
      );
      try {
        cancellation?.check();
        final done = await runner.wait(child.id);
        cancellation?.check();
        if (done.status != TaskStatus.completed ||
            done.result['assetId'] is! String) {
          throw ProviderException(
            'reference_failed',
            '${reference.name}参考图未完成：${done.error}',
          );
        }
        reference.assetId = done.result['assetId'] as String;
      } finally {
        remove?.call();
      }
    }
    if (old?.data['referencePrompt'] == reference.prompt &&
        (old?.data['images'] as List? ?? []).contains(reference.assetId)) {
      return;
    }
    cancellation?.check();
    reference.entry = await repository.saveLoreEntry(
      branchId: branchId,
      id: old?.id,
      expectedRevisionId: old?.revisionId,
      kind: reference.kind,
      name: reference.name,
      content: old?.content ?? reference.prompt,
      certainty: old?.certainty ?? LoreCertainty.inference,
      atChapterId: chapterId,
      data: {
        ...?old?.data,
        'referencePrompt': reference.prompt,
        'images': [
          reference.assetId!,
          ...?(old?.data['images'] as List?)?.where(
            (id) => id != reference.assetId,
          ),
        ],
      },
      // Approved visual baselines must survive automatic sidecar refreshes.
      provenance: {'type': 'visualReference', 'source': ?old?.provenance},
    );
  }

  Future<List<Map<String, dynamic>>> savedScenes(
    String branchId,
    String? chapterId,
  ) async {
    if (chapterId == null) return [];
    final branch = await repository.getBranch(branchId);
    final chapter = await repository.getChapter(
      branchId: branchId,
      chapterId: chapterId,
    );
    final scenes = <String, Map<String, dynamic>>{};
    // Inserting an illustration changes the revision, but not the scene's prose.
    String prose(String text) => text
        .replaceAll('\uFFFC', '')
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .join('\n');
    final sourceText = <String, String>{
      chapter.revisionId: prose(chapter.content.text),
    };
    for (final asset in await repository.listAssets(branch.novelId)) {
      if (asset.branchId != branchId ||
          asset.sourceChapterId != chapterId ||
          asset.sourceRevisionId == null ||
          asset.metadata['scene'] is! Map) {
        continue;
      }
      final revision = asset.sourceRevisionId!;
      sourceText[revision] ??= prose(
        (await repository.getRevision(revision)).content.text,
      );
      if (sourceText[revision] != sourceText[chapter.revisionId]) continue;
      final scene = validateImageScene(asset.metadata['scene']);
      scenes.putIfAbsent(
        scene['id'] as String,
        () => {...scene, 'assetId': asset.id},
      );
    }
    return scenes.values.toList();
  }

  Future<void> addAssetReferences(
    String branchId,
    String? chapterId,
    List<VisualReference> visual,
    List<String> assetIds,
  ) async {
    final novelId = (await repository.getBranch(branchId)).novelId;
    final lore = assetIds.isEmpty
        ? <LoreEntry>[]
        : await repository.listLore(branchId, throughChapterId: chapterId);
    for (final id in assetIds) {
      if (visual.any((r) => r.assetId == id)) continue;
      final asset = await repository.getAsset(id);
      if (asset.novelId != novelId) throw const FormatException('参考图不属于当前作品');
      final entry = lore
          .where(
            (e) =>
                [LoreKind.character, LoreKind.location].contains(e.kind) &&
                (e.data['images'] as List? ?? []).contains(id),
          )
          .firstOrNull;
      final kind =
          entry?.kind ??
          switch (asset.metadata['referenceKind']) {
            'character' => LoreKind.character,
            'location' => LoreKind.location,
            _ => null,
          };
      if (kind == null) throw const FormatException('请先为参考图设置人物或地点类型');
      final saved = entry?.data['referencePrompt'];
      final description = saved is String && saved.trim().isNotEmpty
          ? saved
          : asset.metadata['referencePrompt'] ?? asset.metadata['prompt'];
      if (description is String && description.trim().isNotEmpty) {
        final name = entry?.name ?? asset.name;
        final index = visual.indexWhere(
          (r) =>
              (entry != null && r.entry?.id == entry.id) ||
              (r.kind == kind && r.name == name),
        );
        final reference = VisualReference(
          kind: kind,
          name: name,
          prompt: description,
          entry: entry ?? (index < 0 ? null : visual[index].entry),
          assetId: id,
        );
        final images = reference.entry?.data['images'] as List? ?? [];
        if (images.length >= 8 && !images.contains(id)) {
          throw FormatException('${reference.name}已有 8 张参考图，请先在资料中移除不再使用的图片');
        }
        // An explicitly selected image replaces the planned default for that subject.
        if (index < 0) {
          visual.add(reference);
        } else {
          visual[index] = reference;
        }
      } else {
        throw const FormatException('参考图缺少固定外观描述，请先在生图页面或人物／地点资料中补充');
      }
    }
  }

  Future<GenerationTask> generate({
    required String branchId,
    required ModelConnection connection,
    required String name,
    required ImageRequest request,
    String? chapterId,
    Map<String, dynamic>? illustrationAnchor,
    List<String> referenceAssetIds = const [],
    AssetPurpose purpose = AssetPurpose.illustration,
    List<VisualReference> visualReferences = const [],
    Map<String, dynamic>? scene,
    String? previousSceneAssetId,
    Map<String, dynamic>? regeneration,
  }) async {
    if (name.trim().isEmpty) throw const FormatException('请为图片命名');
    if (referenceAssetIds.length > 16) {
      throw const FormatException('最多使用 16 张参考图');
    }
    final branch = await repository.getBranch(branchId);
    final chapter = chapterId == null
        ? null
        : await repository.getChapter(branchId: branchId, chapterId: chapterId);
    final visual = [...visualReferences];
    if (regeneration == null) {
      await addAssetReferences(branchId, chapterId, visual, referenceAssetIds);
    }
    if (scene != null) {
      scene = validateImageScene(scene);
      validateSceneReferences(scene, visual);
    }
    connection = await withLatestWorkflow(
      connection,
      references:
          referenceLimit(connection) > 0 &&
          (visual.any((r) => r.assetId != null) ||
              referenceAssetIds.isNotEmpty ||
              previousSceneAssetId != null),
    );
    final ids = <String>{
      for (final r in visual.where((r) => r.kind == LoreKind.character))
        ?r.assetId,
      ?previousSceneAssetId,
      for (final r in visual.where((r) => r.kind != LoreKind.character))
        ?r.assetId,
      ...referenceAssetIds,
    };
    final references = <Map<String, dynamic>>[];
    final imageLabels = <String>[];
    for (final id in ids) {
      final asset = await repository.getAsset(id);
      if (asset.novelId != branch.novelId) {
        throw const FormatException('参考图不属于当前作品');
      }
      if (references.length < referenceLimit(connection)) {
        references.add({'id': id, 'hash': asset.hash});
        final ref = visual.where((r) => r.assetId == id).firstOrNull;
        imageLabels.add(
          ref == null
              ? 'previous view of this scene'
              : '${ref.kind.name} ${ref.name}',
        );
      }
    }
    final sourcePrompt = request.prompt;
    request = ImageRequest.fromJson({
      ...request.raw,
      'prompt': visualPrompt(
        request.prompt,
        visual,
        scene,
        tags: connection.protocol == ModelProtocol.novelAI,
        imageLabels: imageLabels,
      ),
    });
    return runner.start(
      branchId: branchId,
      kind: TaskKind.illustration,
      chapterId: chapter?.id,
      baseRevisionId: chapter?.revisionId,
      input: {
        'connection': connection.raw,
        'imageRequest': request.raw,
        'name': name.trim(),
        'purpose': purpose.name,
        'references': references,
        'sourcePrompt': sourcePrompt,
        'previousSceneAssetId': ?previousSceneAssetId,
        'regeneration': ?regeneration,
        if (visual.isNotEmpty)
          'visualReferences': [for (final ref in visual) ref.preview],
        'scene': ?scene,
        'illustrationAnchor': ?illustrationAnchor,
      },
    );
  }
}
