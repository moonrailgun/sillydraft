part of 'story_repository.dart';

extension TaskOperations on StoryRepository {
  Future<GenerationTask> createTask({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? sceneId,
    String? baseRevisionId,
    String? retryOf,
  }) => _write(() async {
    await getBranch(branchId);
    if (sceneId != null) {
      final scene = await getScene(branchId: branchId, sceneId: sceneId);
      if (baseRevisionId != null && scene.revisionId != baseRevisionId) {
        final historicalImage =
            kind == TaskKind.illustration &&
            (await listRevisions(
              branchId: branchId,
              sceneId: sceneId,
            )).any((r) => r.id == baseRevisionId);
        if (!historicalImage) {
          throw RevisionConflict(
            expected: baseRevisionId,
            actual: scene.revisionId,
          );
        }
      }
    }
    final id = _id(), now = _now();
    await _execute(
      '''INSERT INTO generation_tasks
      (id, branch_id, kind, status, scene_id, base_revision_id, input_json, retry_of, created_at, updated_at)
      VALUES (?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?)''',
      [
        id,
        branchId,
        kind.name,
        sceneId,
        baseRevisionId,
        jsonEncode(redactCredentials(input)),
        retryOf,
        now,
        now,
      ],
    );
    return getTask(id);
  });

  Future<GenerationTask> getTask(String id) async => _task(
    await _one('SELECT * FROM generation_tasks WHERE id = ?', [id], '生成任务'),
  );

  Future<List<GenerationTask>> listTasks({
    String? branchId,
    bool activeOnly = false,
  }) async => (await _rows(
    '''SELECT * FROM generation_tasks WHERE (? IS NULL OR branch_id = ?)
      AND (? = 0 OR status IN ('queued','running')) ORDER BY created_at DESC, id''',
    [branchId, branchId, activeOnly ? 1 : 0],
  )).map(_task).toList();

  Future<GenerationTask> updateTask(
    String id, {
    required TaskStatus status,
    String? partialText,
    String? reasoning,
    String? error,
    Map<String, dynamic>? result,
  }) => _write(() async {
    final old = await getTask(id);
    if (!old.isActive) return old;
    if (old.status == TaskStatus.running && status == TaskStatus.queued) {
      throw StateError('不能将运行中任务重新排队');
    }
    await _execute(
      '''UPDATE generation_tasks SET status = ?, partial_text = ?, reasoning = ?, error = ?, result_json = ?, updated_at = ? WHERE id = ?''',
      [
        status.name,
        partialText ?? old.partialText,
        reasoning ?? old.reasoning,
        error ?? old.error,
        jsonEncode({...old.result, ...?result}),
        _now(),
        id,
      ],
    );
    return getTask(id);
  });

  Future<int> recoverInterruptedTasks() => _write(() async {
    final rows = await _rows(
      "SELECT id FROM generation_tasks WHERE status IN ('queued','running')",
    );
    await _execute(
      "UPDATE generation_tasks SET status = 'interrupted', error = ?, updated_at = ? WHERE status IN ('queued','running')",
      ['应用上次退出时任务未完成，可保留已有结果或重新生成。', _now()],
    );
    return rows.length;
  });

  /// Reattach only to the same immutable remote request. Historical scene bases
  /// remain valid for retrieval; accepting the eventual proposal still uses CAS.
  Future<GenerationTask> requeueRemoteTask(String id) => _write(() async {
    final task = await getTask(id);
    if (!task.isRemote ||
        task.kind == TaskKind.agent ||
        ![TaskStatus.failed, TaskStatus.interrupted].contains(task.status) ||
        task.result.containsKey('proposalId') ||
        task.result.containsKey('assetId')) {
      throw StateError('此任务不能重新连接；已完成的结果无需再次获取');
    }
    await _execute(
      "UPDATE generation_tasks SET status = 'queued', error = '', result_json = ?, updated_at = ? WHERE id = ?",
      [
        jsonEncode({...task.result, 'remoteReconnect': true}),
        _now(),
        id,
      ],
    );
    return getTask(id);
  });

  /// Called only after the remote service confirms that execution has stopped.
  Future<GenerationTask> acknowledgeRemoteCancellation(String id) =>
      _write(() async {
        final task = await getTask(id);
        if (!task.isRemote) throw StateError('此任务不是远程任务');
        if (task.status == TaskStatus.completed) return task;
        await _execute(
          "UPDATE generation_tasks SET status = 'cancelled', error = '', updated_at = ? WHERE id = ?",
          [_now(), id],
        );
        return getTask(id);
      });

  Future<GenerationTask> completeWritingTask(
    String id, {
    required ManuscriptContent content,
    required String rawText,
    String reasoning = '',
    String summary = '',
    Map<String, dynamic>? variableResult,
    Map<String, dynamic>? mvuResult,
  }) => _write(() async {
    final task = await getTask(id);
    if (task.status != TaskStatus.running) return task;
    if (task.sceneId == null || task.baseRevisionId == null) {
      throw StateError('写作任务缺少正文依据');
    }
    if (![TaskKind.writing, TaskKind.rewrite].contains(task.kind)) {
      throw StateError('此任务不能生成正文提案');
    }
    final history = await listRevisions(
      branchId: task.branchId,
      sceneId: task.sceneId!,
    );
    if (!history.any((r) => r.id == task.baseRevisionId)) {
      throw const StoryNotFound('任务依据版本');
    }
    final proposalId = _id();
    await _execute(
      '''INSERT INTO proposals
      (id, branch_id, scene_id, base_revision_id, content_json, summary, status, task_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)''',
      [
        proposalId,
        task.branchId,
        task.sceneId,
        task.baseRevisionId,
        content.encoded,
        summary,
        task.id,
        _now(),
      ],
    );
    await _execute(
      "UPDATE generation_tasks SET status = 'completed', partial_text = ?, reasoning = ?, result_json = ?, updated_at = ? WHERE id = ?",
      [
        rawText,
        reasoning,
        jsonEncode({
          ...task.result,
          'proposalId': proposalId,
          'variableResult': ?variableResult,
          'mvu': ?mvuResult,
        }),
        _now(),
        id,
      ],
    );
    return getTask(id);
  });

  Future<BranchVariables> getBranchVariables(
    String branchId, {
    String? throughSceneId,
  }) => _variablesAt(branchId, throughSceneId: throughSceneId);

  Future<void> _commitProposalVariables(
    ManuscriptProposal proposal,
    Scene scene,
  ) async {
    if (proposal.taskId == null) return;
    final task = await getTask(proposal.taskId!);
    final result =
        task.result['variableResult'] ?? task.input['variableResult'];
    if (result is! Map<String, dynamic>) return;
    final variables = await getBranchVariables(proposal.branchId);
    if (variables.version != task.input['variableBaseVersion']) {
      throw const VariableConflict();
    }
    await _setBranchVariables(
      branchId: proposal.branchId,
      scene: scene,
      expectedVersion: variables.version,
      local: (result['local'] as Map? ?? {}).cast<String, String>(),
      global: (result['global'] as Map? ?? {}).cast<String, String>(),
    );
  }
}

GenerationTask _task(Map<String, Object?> row) => GenerationTask(
  id: row['id'] as String,
  branchId: row['branch_id'] as String,
  kind: TaskKind.values.byName(row['kind'] as String),
  status: TaskStatus.values.byName(row['status'] as String),
  input: jsonDecode(row['input_json'] as String) as Map<String, dynamic>,
  partialText: row['partial_text'] as String,
  reasoning: row['reasoning'] as String,
  error: row['error'] as String,
  result: jsonDecode(row['result_json'] as String) as Map<String, dynamic>,
  sceneId: row['scene_id'] as String?,
  baseRevisionId: row['base_revision_id'] as String?,
  retryOf: row['retry_of'] as String?,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    row['created_at'] as int,
    isUtc: true,
  ),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(
    row['updated_at'] as int,
    isUtc: true,
  ),
);
