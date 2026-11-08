part of 'story_repository.dart';

extension ComicOperations on StoryRepository {
  Future<void> resolveComicCandidate({
    required String taskId,
    required String chapterId,
    required String? expectedRevisionId,
    required bool adopt,
  }) => _write(() async {
    final task = await getTask(taskId);
    final candidates = List<String>.from(
      task.result['comicCandidates'] as List? ?? const [],
    );
    if (task.kind != TaskKind.comic ||
        task.isActive ||
        !candidates.contains(chapterId)) {
      throw StateError('此候选尚未完成或已处理');
    }
    if (adopt) {
      final doc = ComicDocument.fromJson(
        Map<String, dynamic>.from(
          (task.result['comicDocuments'] as Map)[chapterId] as Map,
        ),
      );
      await saveComic(
        branchId: task.branchId,
        chapterId: chapterId,
        document: doc.edit({}),
        expectedRevisionId: expectedRevisionId,
        taskId: taskId,
        reason: '采用候选分镜',
      );
    }
    candidates.remove(chapterId);
    await _execute(
      'UPDATE generation_tasks SET result_json = ?, updated_at = ? WHERE id = ?',
      [
        jsonEncode({...task.result, 'comicCandidates': candidates}),
        _now(),
        taskId,
      ],
    );
  });

  /// The new head and checkpoint commit together, including conflicted candidates.
  Future<bool> saveComicTaskDocument(
    String taskId,
    ComicDocument doc, {
    bool candidateOnly = false,
    String? drawn,
  }) => _write(() async {
    final task = await getTask(taskId);
    if (task.kind != TaskKind.comic || !task.isActive) return false;
    final heads = Map<String, dynamic>.from(
      task.result['comicHeads'] as Map? ?? task.input['comicHeads'] as Map,
    );
    var saved = false;
    if (!candidateOnly && await comicImageInputsCurrent(task, doc)) {
      try {
        final revision = await saveComic(
          branchId: task.branchId,
          chapterId: doc.chapterId,
          document: doc,
          expectedRevisionId: heads[doc.chapterId] as String?,
          taskId: task.id,
          reason: '漫画任务',
        );
        heads[doc.chapterId] = revision.id;
        doc = revision.document;
        saved = true;
      } on ComicConflict {
        /* Preserve the full candidate for comparison. */
      }
    }
    await updateTask(
      taskId,
      status: TaskStatus.running,
      result: {
        'comicHeads': heads,
        'comicDocuments': {
          ...?(task.result['comicDocuments'] as Map?),
          doc.chapterId: doc.toJson(),
        },
        'comicCandidates': {
          ...?(task.result['comicCandidates'] as List?),
          if (!saved) doc.chapterId,
        }.toList(),
        'comicDrawn': [
          ...?(task.result['comicDrawn'] as List?),
          if (drawn != null && saved) drawn,
        ],
      },
    );
    return saved;
  });

  Future<ComicRevision?> getComic(String branchId, String chapterId) async {
    final rows = await _rows(
      '''SELECT r.* FROM branch_comics h
      JOIN comic_revisions r ON r.id = h.comic_revision_id
      WHERE h.branch_id = ? AND h.chapter_id = ?''',
      [branchId, chapterId],
    );
    return rows.isEmpty ? null : _comicRevision(rows.single);
  }

  Future<List<ComicRevision>> listComicRevisions(
    String branchId,
    String chapterId,
  ) async {
    final branch = await getBranch(branchId);
    return (await _rows(
      'SELECT * FROM comic_revisions WHERE novel_id = ? AND chapter_id = ? ORDER BY created_at DESC, rowid DESC',
      [branch.novelId, chapterId],
    )).map(_comicRevision).toList();
  }

  Future<bool> comicSourcesCurrent(String branchId, ComicDocument doc) async {
    final chapters = (await getStory(branchId)).chapters;
    final index = chapters.indexWhere((c) => c.id == doc.chapterId);
    if (doc.isOriginal) {
      if (index < 0 || doc.priorComics.length != index) return false;
      for (var i = 0; i < index; i++) {
        final ref = doc.priorComics[i];
        if (ref['chapterId'] != chapters[i].id ||
            ref['revisionId'] !=
                (await getComic(branchId, chapters[i].id))?.id) {
          return false;
        }
      }
      return true;
    }
    if (index < 0 || chapters[index].revisionId != doc.sourceRevisionId) {
      return false;
    }
    final prior = doc.priorSources;
    if (prior.length != index) return false;
    for (var i = 0; i < index; i++) {
      if (prior[i]['chapterId'] != chapters[i].id ||
          prior[i]['revisionId'] != chapters[i].revisionId) {
        return false;
      }
    }
    return true;
  }

  Future<bool> comicReferencesNeedReview(
    String branchId,
    Set<String> assetIds,
  ) async {
    if (assetIds.isEmpty) return false;
    final history = await _rows(
      '''WITH RECURSIVE history AS (
      SELECT r.*, 0 AS distance FROM branch_comics h
      JOIN comic_revisions r ON r.id = h.comic_revision_id
      WHERE h.branch_id = ?
      UNION ALL
      SELECT r.*, h.distance + 1 FROM comic_revisions r
      JOIN history h ON r.id = h.parent_revision_id
      ) SELECT * FROM history ORDER BY distance''',
      [branchId],
    );
    final seen = <(String, String)>{};
    for (final row in history) {
      final revision = _comicRevision(row);
      final states = <String, bool>{};
      for (final panel in revision.document.imageItems) {
        final id = panel['assetId'] as String?;
        if (id != null && assetIds.contains(id)) {
          states[id] = states[id] == true || panel['visualReview'] == true;
        }
      }
      // Keep the latest state per chapter, including explicit confirmations.
      for (final entry in states.entries) {
        if (seen.add((revision.chapterId, entry.key)) && entry.value) {
          return true;
        }
      }
    }
    return false;
  }

  Future<ComicRevision> restoreComic({
    required String branchId,
    required String chapterId,
    required String revisionId,
    required String? expectedRevisionId,
  }) async {
    final revision = _comicRevision(
      await _one('SELECT * FROM comic_revisions WHERE id = ?', [
        revisionId,
      ], '漫画版本'),
    );
    final panels = revision.document.imageItems;
    // Historical approval does not establish continuity in the current branch.
    for (final panel in panels) {
      if (panel['assetId'] != null) panel['visualReview'] = true;
    }
    return saveComic(
      branchId: branchId,
      chapterId: chapterId,
      document: ComicDocument.fromJson({
        ...revision.document.toJson(),
        revision.document.hasPages ? 'pages' : 'panels': panels,
      }),
      expectedRevisionId: expectedRevisionId,
      reason: '恢复漫画历史',
      requireCurrentSource: false,
    );
  }

  Future<bool> comicImageInputsCurrent(
    GenerationTask task,
    ComicDocument doc,
  ) async {
    if (!await comicSourcesCurrent(task.branchId, doc)) return false;
    final previous = task.input['comicPreviousChapterId'] as String?;
    return previous == null ||
        (await getComic(task.branchId, previous))?.id ==
            task.input['comicPreviousRevisionId'];
  }

  Future<ComicRevision> saveComic({
    required String branchId,
    required String chapterId,
    required ComicDocument document,
    required String? expectedRevisionId,
    String reason = '编辑漫画',
    String? taskId,
    bool requireCurrentSource = true,
  }) => _write(() async {
    final branch = await getBranch(branchId);
    await getChapter(branchId: branchId, chapterId: chapterId);
    final head = await getComic(branchId, chapterId);
    if (head?.id != expectedRevisionId ||
        requireCurrentSource &&
            !await comicSourcesCurrent(branchId, document)) {
      throw const ComicConflict();
    }
    if (document.chapterId != chapterId) {
      throw const FormatException('漫画不属于此章节');
    }
    if (head != null && head.document.isOriginal != document.isOriginal) {
      throw const FormatException('不能更改漫画来源类型');
    }
    if (!document.isOriginal) {
      final source = await getRevision(document.sourceRevisionId!);
      if (source.novelId != branch.novelId ||
          source.chapterId != chapterId ||
          source.content.text != document.sourceText) {
        throw const FormatException('漫画来源不匹配');
      }
      for (final prior in document.priorSources) {
        final revision = await getRevision(prior['revisionId'] as String);
        if (revision.novelId != branch.novelId ||
            revision.chapterId != prior['chapterId']) {
          throw const FormatException('漫画前情不属于此作品');
        }
      }
    } else {
      for (final ref in document.priorComics) {
        await _one(
          'SELECT id FROM revisions WHERE novel_id = ? AND chapter_id = ? LIMIT 1',
          [branch.novelId, ref['chapterId']],
          '漫画前情章节',
        );
        if (ref['revisionId'] == null) continue;
        final row = await _one('SELECT * FROM comic_revisions WHERE id = ?', [
          ref['revisionId'],
        ], '漫画前情');
        if (row['novel_id'] != branch.novelId ||
            row['chapter_id'] != ref['chapterId']) {
          throw const FormatException('漫画前情不属于此作品');
        }
      }
    }
    for (final id in document.assetIds) {
      if ((await getAsset(id)).novelId != branch.novelId) {
        throw const FormatException('漫画图片不属于此作品');
      }
    }
    for (final id in {
      ?taskId,
      for (final panel in document.imageItems)
        if (panel['imageTaskId'] is String) panel['imageTaskId'] as String,
    }) {
      if ((await getBranch((await getTask(id)).branchId)).novelId !=
          branch.novelId) {
        throw const FormatException('漫画任务不属于此作品');
      }
    }
    if (head != null) {
      document = await _invalidateDependentComicImages(
        branch,
        head.document,
        document,
      );
    }
    final revision = await _insertComicRevision(
      branch: branch,
      document: document,
      parentRevisionId: head?.id,
      taskId: taskId,
      reason: reason,
    );
    await _touchNovel(branch.novelId);
    return revision;
  });

  // Call only inside a validated save transaction, after dependency propagation.
  Future<ComicRevision> _insertComicRevision({
    required StoryBranch branch,
    required ComicDocument document,
    required String? parentRevisionId,
    required String reason,
    String? taskId,
  }) async {
    final id = _id();
    await _execute(
      '''INSERT INTO comic_revisions
      (id, novel_id, chapter_id, origin_branch_id, parent_revision_id, document_json, task_id, reason, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        branch.novelId,
        document.chapterId,
        branch.id,
        parentRevisionId,
        jsonEncode(document.toJson()),
        taskId,
        reason,
        _now(),
      ],
    );
    await _execute(
      'INSERT OR REPLACE INTO branch_comics (branch_id, chapter_id, comic_revision_id) VALUES (?, ?, ?)',
      [branch.id, document.chapterId, id],
    );
    return _comicRevision(
      await _one('SELECT * FROM comic_revisions WHERE id = ?', [id], '漫画版本'),
    );
  }

  Future<ComicDocument> _invalidateDependentComicImages(
    StoryBranch branch,
    ComicDocument before,
    ComicDocument after,
  ) async {
    final nextPanels = after.imageItems;
    final next = {for (final p in nextPanels) p['id']: p};
    final order = nextPanels.map((p) => p['id']).toList();
    final changedPanels = <String>{}, affectedAssets = <String>{};
    final factsChanged =
        canonicalJson(before.facts) != canonicalJson(after.facts);
    for (final (i, panel) in before.imageItems.indexed) {
      final replacement = next[panel['id']];
      if (replacement == null ||
          factsChanged ||
          before.style != after.style ||
          before.hasPages &&
              after.hasPages &&
              before.pageFingerprint(panel) !=
                  after.pageFingerprint(replacement) ||
          panel['visualReview'] != true &&
              replacement['visualReview'] == true ||
          i >= order.length ||
          order[i] != panel['id'] ||
          [
            'assetId',
            'description',
            'continuity',
            'sceneId',
            'previousPanelId',
            'referenceAssetIds',
          ].any(
            (key) =>
                canonicalJson(panel[key]) != canonicalJson(replacement[key]),
          )) {
        changedPanels.add(panel['id'] as String);
        if (panel['assetId'] case final String id) affectedAssets.add(id);
      }
    }
    if (affectedAssets.isEmpty) return after;
    final story = await getStory(branch.id);
    // Use frozen inputs: a requested reference may exceed the provider's limit.
    final references = {
      for (final asset in await listAssets(
        story.novel.id,
        includeArchived: true,
      ))
        asset.id: {
          for (final ref
              in (asset.metadata['references'] as List? ?? []).whereType<Map>())
            if (ref['id'] is String) ref['id'] as String,
        },
    };
    final heads = <String, ComicRevision>{};
    final panelsByChapter = <String, List<Map<String, dynamic>>>{};
    final affectedPanels = <String, Set<String>>{};
    for (final chapter in story.chapters) {
      final head = await getComic(branch.id, chapter.id);
      if (head == null) continue;
      heads[chapter.id] = head;
      panelsByChapter[chapter.id] = chapter.id == after.chapterId
          ? nextPanels
          : head.document.imageItems;
      affectedPanels[chapter.id] = chapter.id == after.chapterId
          ? changedPanels
          : <String>{};
    }
    final changedChapters = <String>{};
    // Gallery references can run in either direction, including across chapters.
    bool expanded;
    do {
      expanded = false;
      for (final entry in panelsByChapter.entries) {
        final affected = affectedPanels[entry.key]!;
        for (final panel in entry.value) {
          final assetId = panel['assetId'] as String?;
          if (!affectedAssets.contains(assetId) &&
              !affected.contains(panel['previousPanelId']) &&
              !(panel['referenceAssetIds'] as List).any(
                affectedAssets.contains,
              ) &&
              !(references[assetId] ?? const <String>{}).any(
                affectedAssets.contains,
              )) {
            continue;
          }
          if (affected.add(panel['id'] as String)) expanded = true;
          if (assetId != null) {
            if (affectedAssets.add(assetId)) expanded = true;
            if (panel['visualReview'] != true) {
              panel['visualReview'] = true;
              changedChapters.add(entry.key);
            }
          }
        }
      }
    } while (expanded);
    for (final chapterId in changedChapters) {
      final head = heads[chapterId]!;
      final document = ComicDocument.fromJson({
        ...(chapterId == after.chapterId ? after : head.document).toJson(),
        head.document.hasPages ? 'pages' : 'panels': panelsByChapter[chapterId],
      });
      if (chapterId == after.chapterId) {
        after = document;
      } else {
        await _insertComicRevision(
          branch: branch,
          document: document,
          parentRevisionId: head.id,
          reason: '参考画面变更，衔接待复核',
        );
      }
    }
    return after;
  }
}

ComicRevision _comicRevision(Map<String, Object?> r) => ComicRevision(
  id: r['id'] as String,
  novelId: r['novel_id'] as String,
  chapterId: r['chapter_id'] as String,
  originBranchId: r['origin_branch_id'] as String,
  parentRevisionId: r['parent_revision_id'] as String?,
  taskId: r['task_id'] as String?,
  document: ComicDocument.fromJson(
    jsonDecode(r['document_json'] as String) as Map<String, dynamic>,
  ),
  createdAt: _date(r['created_at']),
  reason: r['reason'] as String,
);
