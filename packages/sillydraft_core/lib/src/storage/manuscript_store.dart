part of 'story_repository.dart';

extension ManuscriptOperations on StoryRepository {
  Future<Chapter> createChapter({
    required String branchId,
    String title = '新章节',
  }) => _write(() async {
    _validateTitle(title);
    final branch = await getBranch(branchId);
    final id = _id();
    final next = await _one(
      'SELECT coalesce(max(position), -1) + 1 AS position FROM branch_chapters WHERE branch_id = ?',
      [branchId],
      '章节位置',
    );
    await _execute(
      'INSERT INTO branch_chapters (branch_id, chapter_id, title, position) VALUES (?, ?, ?, ?)',
      [branchId, id, title.trim(), next['position']],
    );
    await _touchNovel(branch.novelId);
    return _getChapter(branchId, id);
  });

  Future<Chapter> _getChapter(
    String branchId,
    String chapterId,
  ) async => _chapter(
    await _one(
      'SELECT * FROM branch_chapters WHERE branch_id = ? AND chapter_id = ?',
      [branchId, chapterId],
      '章节',
    ),
  );

  Future<Scene> getScene({
    required String branchId,
    required String sceneId,
  }) async => _scene(
    await _one(
      '${StoryRepository._sceneQuery} WHERE s.branch_id = ? AND s.scene_id = ?',
      [branchId, sceneId],
      '场景',
    ),
  );

  Future<Scene> createScene({
    required String branchId,
    required String chapterId,
    String title = '新场景',
    ManuscriptContent? content,
  }) => _write(() async {
    _validateTitle(title);
    final branch = await getBranch(branchId);
    await _getChapter(branchId, chapterId);
    final id = _id();
    final revisionId = await _insertRevision(
      novelId: branch.novelId,
      branchId: branchId,
      sceneId: id,
      content: content ?? ManuscriptContent.plainText(''),
      reason: 'create',
    );
    final next = await _one(
      '''SELECT coalesce(max(position), -1) + 1 AS position
      FROM branch_scenes WHERE branch_id = ? AND chapter_id = ?''',
      [branchId, chapterId],
      '场景位置',
    );
    await _execute(
      '''INSERT INTO branch_scenes
      (branch_id, scene_id, chapter_id, title, position, revision_id) VALUES (?, ?, ?, ?, ?, ?)''',
      [branchId, id, chapterId, title.trim(), next['position'], revisionId],
    );
    await _touchNovel(branch.novelId);
    return getScene(branchId: branchId, sceneId: id);
  });

  Future<Scene> saveScene({
    required String branchId,
    required String sceneId,
    required String expectedRevisionId,
    required ManuscriptContent content,
    String reason = 'edit',
  }) => _write(
    () => _saveScene(
      branchId: branchId,
      sceneId: sceneId,
      expectedRevisionId: expectedRevisionId,
      content: content,
      reason: reason,
    ),
  );

  Future<Scene> _saveScene({
    required String branchId,
    required String sceneId,
    required String expectedRevisionId,
    required ManuscriptContent content,
    required String reason,
    String? sourceProposalId,
  }) async {
    final current = await getScene(branchId: branchId, sceneId: sceneId);
    if (current.revisionId != expectedRevisionId) {
      throw RevisionConflict(
        expected: expectedRevisionId,
        actual: current.revisionId,
      );
    }
    final branch = await getBranch(branchId);
    final revisionId = await _insertRevision(
      novelId: branch.novelId,
      branchId: branchId,
      sceneId: sceneId,
      content: content,
      parentRevisionId: current.revisionId,
      reason: reason,
      sourceProposalId: sourceProposalId,
    );
    final changed = await _db.customUpdate(
      '''UPDATE branch_scenes SET revision_id = ?
      WHERE branch_id = ? AND scene_id = ? AND revision_id = ?''',
      variables: _variables([
        revisionId,
        branchId,
        sceneId,
        expectedRevisionId,
      ]),
    );
    if (changed != 1) {
      final actual = await getScene(branchId: branchId, sceneId: sceneId);
      throw RevisionConflict(
        expected: expectedRevisionId,
        actual: actual.revisionId,
      );
    }
    await _touchNovel(branch.novelId);
    return getScene(branchId: branchId, sceneId: sceneId);
  }

  Future<String> _insertRevision({
    required String novelId,
    required String branchId,
    required String sceneId,
    required ManuscriptContent content,
    required String reason,
    String? parentRevisionId,
    String? sourceProposalId,
  }) async {
    final id = _id();
    await _execute(
      '''INSERT INTO revisions
      (id, novel_id, scene_id, origin_branch_id, parent_revision_id, content_json,
       created_at, reason, source_proposal_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        novelId,
        sceneId,
        branchId,
        parentRevisionId,
        content.encoded,
        _now(),
        reason,
        sourceProposalId,
      ],
    );
    return id;
  }

  Future<DocumentRevision> getRevision(String id) async => _revision(
    await _one('SELECT * FROM revisions WHERE id = ?', [id], '正文版本'),
  );

  Future<List<DocumentRevision>> listRevisions({
    required String branchId,
    required String sceneId,
  }) async {
    final current = await getScene(branchId: branchId, sceneId: sceneId);
    final rows = await _rows(
      '''WITH RECURSIVE history AS (
      SELECT *, 0 AS distance FROM revisions WHERE id = ?
      UNION ALL
      SELECT r.*, h.distance + 1 FROM revisions r JOIN history h ON r.id = h.parent_revision_id
    ) SELECT * FROM history ORDER BY distance''',
      [current.revisionId],
    );
    return rows.map(_revision).toList(growable: false);
  }

  Future<Scene> restoreRevision({
    required String branchId,
    required String sceneId,
    required String expectedRevisionId,
    required String revisionId,
  }) => _write(() async {
    final history = await listRevisions(branchId: branchId, sceneId: sceneId);
    final matching = history.where((r) => r.id == revisionId);
    if (matching.isEmpty) throw const StoryNotFound('当前分支的历史版本');
    return _saveScene(
      branchId: branchId,
      sceneId: sceneId,
      expectedRevisionId: expectedRevisionId,
      content: matching.single.content,
      reason: 'restore:$revisionId',
    );
  });

  Future<void> renameChapter({
    required String branchId,
    required String chapterId,
    required String title,
  }) => _write(() async {
    _validateTitle(title);
    await _getChapter(branchId, chapterId);
    await _execute(
      'UPDATE branch_chapters SET title = ? WHERE branch_id = ? AND chapter_id = ?',
      [title.trim(), branchId, chapterId],
    );
    await _touchNovel((await getBranch(branchId)).novelId);
  });

  Future<void> renameScene({
    required String branchId,
    required String sceneId,
    required String title,
  }) => _write(() async {
    _validateTitle(title);
    await getScene(branchId: branchId, sceneId: sceneId);
    await _execute(
      'UPDATE branch_scenes SET title = ? WHERE branch_id = ? AND scene_id = ?',
      [title.trim(), branchId, sceneId],
    );
    await _touchNovel((await getBranch(branchId)).novelId);
  });

  Future<void> reorderScenes({
    required String branchId,
    required String chapterId,
    required List<String> sceneIds,
  }) => _write(() async {
    await _getChapter(branchId, chapterId);
    final current = await _rows(
      'SELECT scene_id FROM branch_scenes WHERE branch_id = ? AND chapter_id = ?',
      [branchId, chapterId],
    );
    final ids = current.map((r) => r['scene_id'] as String).toSet();
    if (sceneIds.length != ids.length ||
        sceneIds.toSet().length != ids.length ||
        !ids.containsAll(sceneIds)) {
      throw ArgumentError('场景顺序必须完整包含本章的每个场景，且不能重复。');
    }
    for (var index = 0; index < sceneIds.length; index++) {
      await _execute(
        'UPDATE branch_scenes SET position = ? WHERE branch_id = ? AND scene_id = ?',
        [index, branchId, sceneIds[index]],
      );
    }
    await _touchNovel((await getBranch(branchId)).novelId);
  });
}
