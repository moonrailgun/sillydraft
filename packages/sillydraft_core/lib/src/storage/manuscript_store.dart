part of 'story_repository.dart';

extension ManuscriptOperations on StoryRepository {
  Future<Chapter> getChapter({
    required String branchId,
    required String chapterId,
  }) async => _chapter(
    await _one(
      '${StoryRepository._chapterQuery} WHERE s.branch_id = ? AND s.chapter_id = ?',
      [branchId, chapterId],
      '章节',
    ),
  );

  Future<Chapter> createChapter({
    required String branchId,
    String title = '新章节',
    ManuscriptContent? content,
  }) => _write(() async {
    _validateTitle(title);
    final branch = await getBranch(branchId);
    final id = _id();
    final revisionId = await _insertRevision(
      novelId: branch.novelId,
      branchId: branchId,
      chapterId: id,
      content: content ?? ManuscriptContent.plainText(''),
      reason: 'create',
    );
    final next = await _one(
      '''SELECT coalesce(max(position), -1) + 1 AS position
      FROM branch_chapters WHERE branch_id = ?''',
      [branchId],
      '章节位置',
    );
    await _execute(
      '''INSERT INTO branch_chapters
      (branch_id, chapter_id, title, position, revision_id) VALUES (?, ?, ?, ?, ?)''',
      [branchId, id, title.trim(), next['position'], revisionId],
    );
    await _touchNovel(branch.novelId);
    return getChapter(branchId: branchId, chapterId: id);
  });

  Future<Chapter> saveChapter({
    required String branchId,
    required String chapterId,
    required String expectedRevisionId,
    required ManuscriptContent content,
    String reason = 'edit',
  }) => _write(
    () => _saveChapter(
      branchId: branchId,
      chapterId: chapterId,
      expectedRevisionId: expectedRevisionId,
      content: content,
      reason: reason,
    ),
  );

  Future<Chapter> _saveChapter({
    required String branchId,
    required String chapterId,
    required String expectedRevisionId,
    required ManuscriptContent content,
    required String reason,
    String? sourceProposalId,
  }) async {
    final current = await getChapter(branchId: branchId, chapterId: chapterId);
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
      chapterId: chapterId,
      content: content,
      parentRevisionId: current.revisionId,
      reason: reason,
      sourceProposalId: sourceProposalId,
    );
    final changed = await _db.customUpdate(
      '''UPDATE branch_chapters SET revision_id = ?
      WHERE branch_id = ? AND chapter_id = ? AND revision_id = ?''',
      variables: _variables([
        revisionId,
        branchId,
        chapterId,
        expectedRevisionId,
      ]),
    );
    if (changed != 1) {
      final actual = await getChapter(branchId: branchId, chapterId: chapterId);
      throw RevisionConflict(
        expected: expectedRevisionId,
        actual: actual.revisionId,
      );
    }
    await _touchNovel(branch.novelId);
    return getChapter(branchId: branchId, chapterId: chapterId);
  }

  Future<String> _insertRevision({
    required String novelId,
    required String branchId,
    required String chapterId,
    required ManuscriptContent content,
    required String reason,
    String? parentRevisionId,
    String? sourceProposalId,
  }) async {
    final id = _id();
    await _validateManuscriptAssets(novelId, content);
    await _execute(
      '''INSERT INTO revisions
      (id, novel_id, chapter_id, origin_branch_id, parent_revision_id, content_json,
       created_at, reason, source_proposal_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        novelId,
        chapterId,
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
    required String chapterId,
  }) async {
    final current = await getChapter(branchId: branchId, chapterId: chapterId);
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

  Future<Chapter> restoreRevision({
    required String branchId,
    required String chapterId,
    required String expectedRevisionId,
    required String revisionId,
  }) => _write(() async {
    final history = await listRevisions(
      branchId: branchId,
      chapterId: chapterId,
    );
    final matching = history.where((r) => r.id == revisionId);
    if (matching.isEmpty) throw const StoryNotFound('当前分支的历史版本');
    return _saveChapter(
      branchId: branchId,
      chapterId: chapterId,
      expectedRevisionId: expectedRevisionId,
      content: matching.single.content,
      reason: 'restore:$revisionId',
    );
  });

  Future<List<GenerationTask>> activeChapterTasks({
    required String branchId,
    required String chapterId,
  }) async => [
    for (final task in await listTasks(branchId: branchId, activeOnly: true))
      if ([
        task.chapterId,
        task.input['throughChapterId'],
        task.input['editChapterId'],
      ].contains(chapterId))
        task,
  ];

  /// Removes this branch's chapter; shared revision history remains available.
  Future<void> deleteChapter({
    required String branchId,
    required String chapterId,
  }) => _write(() async {
    await getChapter(branchId: branchId, chapterId: chapterId);
    if ((await activeChapterTasks(
      branchId: branchId,
      chapterId: chapterId,
    )).isNotEmpty) {
      throw StateError('这一章还有正在进行的任务，请先停止。');
    }
    final story = await getStory(branchId);
    final before = story.chapters
        .takeWhile((c) => c.id != chapterId)
        .lastOrNull
        ?.id;
    final where = [branchId, chapterId];
    await _execute(
      '''UPDATE revisions SET source_proposal_id = NULL WHERE source_proposal_id IN
      (SELECT id FROM proposals WHERE branch_id = ? AND chapter_id = ?)''',
      where,
    );
    for (final table in [
      'proposals',
      'reading_bookmarks',
      'variable_revisions',
    ]) {
      await _execute(
        'DELETE FROM $table WHERE branch_id = ? AND chapter_id = ?',
        where,
      );
    }
    await _execute(
      'DELETE FROM agent_conversations WHERE branch_id = ? AND through_chapter_id = ?',
      where,
    );
    await _execute(
      'UPDATE generation_tasks SET chapter_id = NULL WHERE branch_id = ? AND chapter_id = ?',
      where,
    );
    await _execute(
      'UPDATE lore_versions SET at_chapter_id = ? WHERE branch_id = ? AND at_chapter_id = ?',
      [before, ...where],
    );
    await _execute(
      'DELETE FROM branch_chapters WHERE branch_id = ? AND chapter_id = ?',
      where,
    );
    if ((await getReadingProgress(branchId))?['chapterId'] == chapterId) {
      await _execute('DELETE FROM app_settings WHERE key = ?', [
        'progress/$branchId',
      ]);
    }
    final head = await _rows(
      'SELECT version FROM branch_variables WHERE branch_id = ?',
      [branchId],
    );
    if (head.isNotEmpty) {
      final projected = await _variablesAt(branchId);
      await _execute(
        'UPDATE branch_variables SET version = ?, local_json = ?, global_json = ? WHERE branch_id = ?',
        [
          projected.version + 1,
          jsonEncode(projected.local),
          jsonEncode(projected.global),
          branchId,
        ],
      );
    }
    await _touchNovel(story.branch.novelId);
  });

  Future<void> renameChapter({
    required String branchId,
    required String chapterId,
    required String title,
  }) => _write(() async {
    _validateTitle(title);
    await getChapter(branchId: branchId, chapterId: chapterId);
    await _execute(
      'UPDATE branch_chapters SET title = ? WHERE branch_id = ? AND chapter_id = ?',
      [title.trim(), branchId, chapterId],
    );
    await _touchNovel((await getBranch(branchId)).novelId);
  });

  Future<void> reorderChapters({
    required String branchId,
    required List<String> chapterIds,
  }) => _write(() async {
    final current = await _rows(
      'SELECT chapter_id FROM branch_chapters WHERE branch_id = ?',
      [branchId],
    );
    final ids = current.map((r) => r['chapter_id'] as String).toSet();
    if (chapterIds.length != ids.length ||
        chapterIds.toSet().length != ids.length ||
        !ids.containsAll(chapterIds)) {
      throw ArgumentError('章节顺序必须完整包含当前分支的每一章，且不能重复。');
    }
    for (var index = 0; index < chapterIds.length; index++) {
      await _execute(
        'UPDATE branch_chapters SET position = ? WHERE branch_id = ? AND chapter_id = ?',
        [index, branchId, chapterIds[index]],
      );
    }
    await _touchNovel((await getBranch(branchId)).novelId);
  });
}
