part of 'story_repository.dart';

extension BranchOperations on StoryRepository {
  Future<StoryBranch> getBranch(String id) async =>
      _branch(await _one('SELECT * FROM branches WHERE id = ?', [id], '故事分支'));

  Future<List<StoryBranch>> listBranches(String novelId) async {
    final rows = await _rows(
      'SELECT * FROM branches WHERE novel_id = ? ORDER BY created_at, id',
      [novelId],
    );
    return rows.map(_branch).toList(growable: false);
  }

  Future<void> setActiveBranch(String branchId) => _write(() async {
    final branch = await getBranch(branchId);
    await _execute(
      'UPDATE novels SET active_branch_id = ?, updated_at = ? WHERE id = ?',
      [branch.id, _now(), branch.novelId],
    );
  });

  Future<void> renameBranch(String branchId, String name) => _write(() async {
    _validateTitle(name);
    final branch = await getBranch(branchId);
    await _execute('UPDATE branches SET name = ? WHERE id = ?', [
      name.trim(),
      branchId,
    ]);
    await _touchNovel(branch.novelId);
  });

  Future<StoryBranch> forkBranch({
    required String branchId,
    required String name,
    String? atChapterId,
  }) => _write(() async {
    _validateTitle(name);
    final source = await getStory(branchId);
    final index = atChapterId == null
        ? source.chapters.length - 1
        : source.chapters.indexWhere((s) => s.id == atChapterId);
    if (atChapterId != null && index < 0) throw const StoryNotFound('分叉章节');
    final forkChapter = index < 0 ? null : source.chapters[index];
    final selectedChapters = atChapterId == null
        ? source.chapters
        : source.chapters.take(index + 1).toList();
    final id = _id();
    await _execute(
      '''INSERT INTO branches
      (id, novel_id, name, parent_branch_id, fork_chapter_id, fork_revision_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        source.novel.id,
        name.trim(),
        branchId,
        forkChapter?.id,
        forkChapter?.revisionId,
        _now(),
      ],
    );
    for (final chapter in selectedChapters) {
      await _execute(
        '''INSERT INTO branch_chapters
        (branch_id, chapter_id, title, position, revision_id) VALUES (?, ?, ?, ?, ?)''',
        [id, chapter.id, chapter.title, chapter.position, chapter.revisionId],
      );
    }
    await _forkSideData(source, id, selectedChapters);
    await _touchNovel(source.novel.id);
    return getBranch(id);
  });
}
