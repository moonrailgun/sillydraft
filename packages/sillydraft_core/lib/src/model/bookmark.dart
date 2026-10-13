final class ReadingBookmark {
  const ReadingBookmark({
    required this.id,
    required this.branchId,
    required this.chapterId,
    required this.label,
    required this.offset,
    required this.createdAt,
  });
  final String id, branchId, chapterId, label;
  final int offset;
  final DateTime createdAt;
}
