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
    final novel = await createNovel(
      title: title ?? book.title,
      synopsis: book.synopsis,
      genre: genre,
      pointOfView: pointOfView,
    );
    final branchId = novel.activeBranchId;
    for (final (position, chapter) in book.chapters.indexed) {
      final chapterId = _id();
      await _execute(
        'INSERT INTO branch_chapters (branch_id, chapter_id, title, position) VALUES (?, ?, ?, ?)',
        [
          branchId,
          chapterId,
          _importTitle(chapter.title, '第${position + 1}章'),
          position,
        ],
      );
      for (final (index, scene) in chapter.scenes.indexed) {
        final sceneId = _id();
        final revisionId = await _insertRevision(
          novelId: novel.id,
          branchId: branchId,
          sceneId: sceneId,
          content: ManuscriptContent.plainText(scene.text),
          reason: 'import',
        );
        await _execute(
          '''INSERT INTO branch_scenes
          (branch_id, scene_id, chapter_id, title, position, revision_id) VALUES (?, ?, ?, ?, ?, ?)''',
          [
            branchId,
            sceneId,
            chapterId,
            _importTitle(scene.title, '正文'),
            index,
            revisionId,
          ],
        );
      }
    }
    await _touchNovel(novel.id);
    return getNovel(novel.id);
  });
}

String _importTitle(String title, String fallback) {
  final trimmed = title.trim();
  if (trimmed.isEmpty) return fallback;
  return trimmed.length > 120 ? '${trimmed.substring(0, 120)}…' : trimmed;
}
