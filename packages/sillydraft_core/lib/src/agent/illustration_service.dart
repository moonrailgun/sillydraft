import '../model/asset.dart';
import '../model/task.dart';
import '../providers/image_provider.dart';
import '../providers/comfy_workflow.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';

final class IllustrationService {
  const IllustrationService({required this.repository, required this.runner});
  final StoryRepository repository;
  final TaskControl runner;

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

  Future<GenerationTask> generate({
    required String branchId,
    required ModelConnection connection,
    required String name,
    required ImageRequest request,
    String? chapterId,
    List<String> referenceAssetIds = const [],
    AssetPurpose purpose = AssetPurpose.illustration,
  }) async {
    if (name.trim().isEmpty) throw const FormatException('请为图片命名');
    if (referenceAssetIds.length > 16) {
      throw const FormatException('最多使用 16 张参考图');
    }
    final branch = await repository.getBranch(branchId);
    final chapter = chapterId == null
        ? null
        : await repository.getChapter(branchId: branchId, chapterId: chapterId);
    final references = <Map<String, dynamic>>[];
    for (final id in referenceAssetIds) {
      final asset = await repository.getAsset(id);
      if (asset.novelId != branch.novelId) {
        throw const FormatException('参考图不属于当前作品');
      }
      references.add({'id': id, 'hash': asset.hash});
    }
    // Freeze before creating the task; resume keeps this exact snapshot.
    connection = await withLatestWorkflow(
      connection,
      references: references.isNotEmpty,
    );
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
      },
    );
  }
}
