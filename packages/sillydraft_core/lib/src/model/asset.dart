import '../st/import_types.dart';

enum AssetPurpose { illustration, cover, map, reference }

final class StoryAsset extends JsonSource {
  StoryAsset({
    required this.id,
    required this.novelId,
    required this.branchId,
    required this.name,
    required this.hash,
    required this.thumbnailHash,
    required this.width,
    required this.height,
    required this.byteLength,
    required this.purpose,
    required this.createdAt,
    required Map<String, dynamic> metadata,
    this.sourceChapterId,
    this.sourceRevisionId,
    this.taskId,
    this.archived = false,
  }) : super(metadata);
  final String id, novelId, branchId, name, hash, thumbnailHash;
  final String? sourceChapterId, sourceRevisionId, taskId;
  final int width, height, byteLength;
  final AssetPurpose purpose;
  final DateTime createdAt;
  final bool archived;
  Map<String, dynamic> get metadata => raw;
}

/// Metadata for normalized files. Only AssetLibrary produces these after decode.
final class PreparedAsset {
  const PreparedAsset({
    required this.hash,
    required this.thumbnailHash,
    required this.width,
    required this.height,
    required this.byteLength,
  });
  final String hash, thumbnailHash;
  final int width, height, byteLength;
}
