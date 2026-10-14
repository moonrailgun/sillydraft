import '../model/asset.dart';
import '../model/task.dart';
import '../providers/image_provider.dart';
import '../providers/comfy_workflow.dart';
import '../providers/comfyui.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';

final class IllustrationService {
  const IllustrationService({required this.repository, required this.runner});
  final StoryRepository repository;
  final TaskRunner runner;

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

  /// [connection] with its ComfyUI workflow re-read from the server, so a
  /// run uses the nodes the author last saved there.
  Future<ModelConnection> withLatestWorkflow(ModelConnection connection) async {
    final workflow = connection.comfyWorkflow;
    if (connection.protocol != ModelProtocol.comfyUI ||
        workflow == null ||
        workflow.filename.isEmpty) {
      return connection;
    }
    final factory = runner.imageProviderFactory;
    if (factory == null) throw StateError('未配置生图执行器');
    final provider = await factory(connection);
    try {
      if (provider is! ComfyUIProvider) {
        throw const ProviderException('comfy_workflow', '此执行器无法读取 ComfyUI 工作流');
      }
      final nodes = await provider.readWorkflow(workflow.filename);
      return ModelConnection.fromJson({
        ...connection.raw,
        'comfyWorkflow': ComfyWorkflow.fromJson({
          ...workflow.raw,
          'nodes': nodes,
        }).raw,
      });
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
    connection = await withLatestWorkflow(connection);
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
