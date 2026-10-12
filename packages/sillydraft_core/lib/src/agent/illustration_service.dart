import '../model/asset.dart';
import '../model/task.dart';
import '../providers/image_provider.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';

final class IllustrationService {
  const IllustrationService({required this.repository, required this.runner});
  final StoryRepository repository;
  final TaskRunner runner;
  Future<GenerationTask> generate({
    required String branchId,
    required ModelConnection connection,
    required String name,
    required ImageRequest request,
    String? sceneId,
    List<String> referenceAssetIds = const [],
    AssetPurpose purpose = AssetPurpose.illustration,
  }) async {
    if (name.trim().isEmpty) throw const FormatException('请为图片命名');
    if (referenceAssetIds.length > 16) {
      throw const FormatException('最多使用 16 张参考图');
    }
    final branch = await repository.getBranch(branchId);
    final scene = sceneId == null
        ? null
        : await repository.getScene(branchId: branchId, sceneId: sceneId);
    final references = <Map<String, dynamic>>[];
    for (final id in referenceAssetIds) {
      final asset = await repository.getAsset(id);
      if (asset.novelId != branch.novelId) {
        throw const FormatException('参考图不属于当前作品');
      }
      references.add({'id': id, 'hash': asset.hash});
    }
    return runner.start(
      branchId: branchId,
      kind: TaskKind.illustration,
      sceneId: scene?.id,
      baseRevisionId: scene?.revisionId,
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
