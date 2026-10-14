part of 'story_repository.dart';

extension LoreReviewOperations on StoryRepository {
  Future<Map<int, String>> selectedCandidateBranches(String taskId) async => {
    for (final row in await _rows(
      'SELECT candidate_index,branch_id FROM branch_candidate_selections WHERE task_id = ?',
      [taskId],
    ))
      row['candidate_index'] as int: row['branch_id'] as String,
  };

  /// Views re-check this on every repository change, so it reads the task
  /// without its request snapshots.
  Future<bool> taskSourcesCurrent(String taskId) async {
    final task = await getTask(taskId, snapshots: false);
    final story = await getStory(task.branchId);
    final throughChapterId = task.input['throughChapterId'] as String?;
    final cutoff = throughChapterId == null
        ? story.chapters.length - 1
        : story.chapters.indexWhere((s) => s.id == throughChapterId);
    if (throughChapterId != null && cutoff < 0) return false;
    final chapters = story.chapters.take(cutoff + 1).toList();
    final sources = task.input['sourceRevisions'];
    if (sources is! List || sources.length != chapters.length) return false;
    for (final (i, chapter) in chapters.indexed) {
      final source = sources[i];
      if (source is! Map ||
          source['chapterId'] != chapter.id ||
          source['revisionId'] != chapter.revisionId) {
        return false;
      }
    }
    return true;
  }

  Future<LoreEntry> acceptAnalysisEntry({
    required String taskId,
    required int index,
    String? targetEntityId,
    String? expectedRevisionId,
    String? name,
    String? content,
    LoreCertainty? certainty,
    Map<String, dynamic>? details,
  }) => _write(() async {
    final accepted = await _rows(
      'SELECT revision_id FROM analysis_acceptances WHERE task_id = ? AND entry_index = ?',
      [taskId, index],
    );
    if (accepted.isNotEmpty) {
      return getLoreRevision(accepted.single['revision_id'] as String);
    }
    final task = await getTask(taskId);
    if (task.kind != TaskKind.analysis || task.status != TaskStatus.completed) {
      throw const FormatException('分析任务尚未完成');
    }
    if (!await taskSourcesCurrent(taskId)) throw const StaleAnalysis();
    final entries = task.result['entries'];
    if (entries is! List || index < 0 || index >= entries.length) {
      throw const FormatException('分析条目不存在');
    }
    final data = jsonObject(entries[index], '分析条目');
    final kind = LoreKind.values
        .where((e) => e.name == data['kind'])
        .firstOrNull;
    final confidence =
        certainty ??
        LoreCertainty.values
            .where((e) => e.name == data['certainty'])
            .firstOrNull;
    if (kind == null || kind == LoreKind.map || confidence == null) {
      throw const FormatException('分析资料类型无效');
    }
    final chapterId = stringField(data, 'sourceChapterId');
    if (!(task.input['sourceRevisions'] as List).any(
      (s) => s is Map && s['chapterId'] == chapterId,
    )) {
      throw const FormatException('资料依据不在这次分析的正文快照中');
    }
    final source = await getChapter(
      branchId: task.branchId,
      chapterId: chapterId,
    );
    final entryName = name ?? stringField(data, 'name');
    final existing = await listLore(
      task.branchId,
      throughChapterId: chapterId,
      kind: kind,
    );
    if (targetEntityId == null &&
        existing.any(
          (e) => e.name.trim().toLowerCase() == entryName.trim().toLowerCase(),
        )) {
      throw const LoreConflict('已有同名资料，请选择更新目标并比较内容。');
    }
    final old = targetEntityId == null
        ? null
        : await getLoreEntry(
            branchId: task.branchId,
            id: targetEntityId,
            throughChapterId: chapterId,
          );
    if (old?.data['worldBookOnly'] == true) {
      throw const LoreConflict('世界书快照应在来源角色卡中编辑。');
    }
    final entry = await saveLoreEntry(
      branchId: task.branchId,
      id: targetEntityId,
      expectedRevisionId: expectedRevisionId,
      kind: kind,
      name: entryName,
      content: content ?? stringField(data, 'content'),
      certainty: confidence,
      atChapterId: chapterId,
      data: {
        ...?old?.data,
        if (data['data'] is Map<String, dynamic>)
          ...data['data'] as Map<String, dynamic>,
        ...?details,
      },
      provenance: {
        'type': 'analysis',
        'taskId': taskId,
        'entryIndex': index,
        'chapterId': chapterId,
        'revisionId': source.revisionId,
      },
    );
    await _execute(
      'INSERT INTO analysis_acceptances(task_id,entry_index,entity_id,revision_id) VALUES (?,?,?,?)',
      [taskId, index, entry.id, entry.revisionId],
    );
    return entry;
  });

  Future<Map<int, String>> acceptedAnalysisEntries(String taskId) async => {
    for (final row in await _rows(
      'SELECT entry_index,entity_id FROM analysis_acceptances WHERE task_id = ?',
      [taskId],
    ))
      row['entry_index'] as int: row['entity_id'] as String,
  };

  Future<StoryBranch> branchFromCandidate({
    required String taskId,
    required int index,
    String? name,
  }) => _write(() async {
    final previous = await _rows(
      'SELECT branch_id FROM branch_candidate_selections WHERE task_id = ? AND candidate_index = ?',
      [taskId, index],
    );
    if (previous.isNotEmpty) {
      return getBranch(previous.single['branch_id'] as String);
    }
    final task = await getTask(taskId);
    if (task.kind != TaskKind.branches || task.status != TaskStatus.completed) {
      throw const FormatException('走向候选尚未完成');
    }
    if (!await taskSourcesCurrent(taskId)) throw const StaleAnalysis();
    final candidates = task.result['candidates'];
    if (candidates is! List || index < 0 || index >= candidates.length) {
      throw const FormatException('候选不存在');
    }
    final candidate = jsonObject(candidates[index], '走向候选');
    final branch = await forkBranch(
      branchId: task.branchId,
      name: name ?? stringField(candidate, 'title'),
    );
    final opening = await createChapter(
      branchId: branch.id,
      title: stringField(candidate, 'title'),
      content: ManuscriptContent.plainText(stringField(candidate, 'opening')),
    );
    await saveLoreEntry(
      branchId: branch.id,
      kind: LoreKind.world,
      name: '剧情计划：${candidate['title']}',
      content: stringField(candidate, 'summary'),
      certainty: LoreCertainty.plan,
      atChapterId: opening.id,
      provenance: {
        'type': 'candidate',
        'taskId': taskId,
        'candidateIndex': index,
      },
    );
    await _execute(
      'INSERT INTO branch_candidate_selections(task_id,candidate_index,branch_id) VALUES (?,?,?)',
      [taskId, index, branch.id],
    );
    await setActiveBranch(branch.id);
    return branch;
  });
}
