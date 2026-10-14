part of 'story_repository.dart';

extension ManuscriptImportOperations on StoryRepository {
  /// Creates a work from an imported book in one transaction, so a book of
  /// thousands of chapters lands at once and nothing half-imported remains.
  Future<Novel> createNovelFromManuscript(
    ImportedManuscript book, {
    String? title,
    String genre = '自由创作',
    String pointOfView = '第三人称',
  }) => _write(() async {
    if (book.chapters.isEmpty) throw const FormatException('没有可导入的章节');
    // Headings keep how they read; those the order numbers join it.
    final titles = [for (final c in book.chapters) _importTitle(c.title)];
    final numbering = numberChapterTitles(titles);
    final novel = await createNovel(
      title: title ?? book.title,
      synopsis: book.synopsis,
      genre: genre,
      pointOfView: pointOfView,
      chapterNumerals: inferNumerals([
        for (final (i, t) in titles.indexed)
          if (numbering[i].numbered) t,
      ]),
    );
    final branchId = novel.activeBranchId;
    for (final (position, chapter) in book.chapters.indexed) {
      final chapterId = _id();
      final revisionId = await _insertRevision(
        novelId: novel.id,
        branchId: branchId,
        chapterId: chapterId,
        content: ManuscriptContent.plainText(chapter.text),
        reason: 'import',
      );
      await _execute(
        '''INSERT INTO branch_chapters
        (branch_id, chapter_id, title, numbered, position, revision_id)
        VALUES (?, ?, ?, ?, ?, ?)''',
        [
          branchId,
          chapterId,
          numbering[position].name,
          numbering[position].numbered ? 1 : 0,
          position,
          revisionId,
        ],
      );
    }
    await _touchNovel(novel.id);
    return getNovel(novel.id);
  });
}

String _importTitle(String title) {
  final trimmed = title.trim();
  return trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
}
