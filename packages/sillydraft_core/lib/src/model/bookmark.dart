final class ReadingBookmark {
  const ReadingBookmark({
    required this.id,
    required this.branchId,
    required this.sceneId,
    required this.label,
    required this.offset,
    required this.createdAt,
  });
  final String id, branchId, sceneId, label;
  final int offset;
  final DateTime createdAt;
}
