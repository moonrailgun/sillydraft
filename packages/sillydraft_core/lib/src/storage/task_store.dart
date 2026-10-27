part of 'story_repository.dart';

extension TaskOperations on StoryRepository {
  Future<GenerationTask> createTask({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? chapterId,
    String? baseRevisionId,
    String? retryOf,
  }) => _write(() async {
    await getBranch(branchId);
    if (chapterId != null) {
      final chapter = await getChapter(
        branchId: branchId,
        chapterId: chapterId,
      );
      if (baseRevisionId != null && chapter.revisionId != baseRevisionId) {
        final historicalImage =
            kind == TaskKind.illustration &&
            (await listRevisions(
              branchId: branchId,
              chapterId: chapterId,
            )).any((r) => r.id == baseRevisionId);
        if (!historicalImage) {
          throw RevisionConflict(
            expected: baseRevisionId,
            actual: chapter.revisionId,
          );
        }
      }
    }
    final id = _id(), now = _now();
    await _execute(
      '''INSERT INTO generation_tasks
      (id, branch_id, kind, status, chapter_id, base_revision_id, input_json, retry_of, created_at, updated_at)
      VALUES (?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?)''',
      [
        id,
        branchId,
        kind.name,
        chapterId,
        baseRevisionId,
        jsonEncode(redactCredentials(input)),
        retryOf,
        now,
        now,
      ],
    );
    return getTask(id);
  }, tasksOnly: true);

  /// Appending the user turn and freezing its input must succeed together.
  Future<GenerationTask> prepareAgentTask(
    String id,
    Future<Map<String, dynamic>> Function() prepare,
  ) => _write(() async {
    final task = await getTask(id);
    if (task.status != TaskStatus.queued) return task;
    if (task.kind != TaskKind.agent || task.input['pendingAgent'] == null) {
      throw StateError('此任务不是待发送的助手消息');
    }
    final input = await prepare();
    await _execute(
      "UPDATE generation_tasks SET input_json = ?, status = 'running', updated_at = ? WHERE id = ?",
      [jsonEncode(redactCredentials(input)), _now(), id],
    );
    _listedInputs.remove(id);
    return getTask(id);
  });

  /// With [snapshots] false the input leaves out the frozen request
  /// snapshots, as in [listTasks].
  Future<GenerationTask> getTask(String id, {bool snapshots = true}) async {
    if (snapshots) {
      return _task(
        await _one(
          'SELECT $_taskColumns, input_json FROM generation_tasks WHERE id = ?',
          [id],
          '生成任务',
        ),
      );
    }
    final listed = await _listed(
      await _rows('SELECT $_taskColumns FROM generation_tasks WHERE id = ?', [
        id,
      ]),
    );
    if (listed.isEmpty) throw const StoryNotFound('生成任务');
    return listed.single;
  }

  /// Tasks without the frozen request snapshots in their input
  /// ([_snapshotKeys]) or a sidecar's transcript in their result: task views
  /// re-read this list on every repository change, and one preset snapshot
  /// can be most of a megabyte. Running or inspecting a task reads it whole
  /// with [getTask].
  Future<List<GenerationTask>> listTasks({
    String? branchId,
    bool activeOnly = false,
  }) async => _listed(
    await _rows(
      '''SELECT $_listedColumns FROM generation_tasks WHERE (? IS NULL OR branch_id = ?)
      AND (? = 0 OR status IN ('queued','running')) ORDER BY created_at DESC, rowid DESC''',
      [branchId, branchId, activeOnly ? 1 : 0],
    ),
  );

  /// [rows] as tasks with their trimmed inputs, trimming only inputs not yet
  /// in [_listedInputs]. A task deleted in between is left out.
  Future<List<GenerationTask>> _listed(List<Map<String, Object?>> rows) async {
    final missing = [
      for (final row in rows)
        if (!_listedInputs.containsKey(row['id'])) row['id'],
    ];
    for (var i = 0; i < missing.length; i += 500) {
      final ids = missing.skip(i).take(500).toList();
      for (final row in await _rows(
        'SELECT id, $_listedInput AS input_json FROM generation_tasks '
        'WHERE id IN (${List.filled(ids.length, '?').join(',')})',
        ids,
      )) {
        _listedInputs[row['id'] as String] = row['input_json'] as String;
      }
    }
    final tasks = [
      for (final row in rows)
        if (_listedInputs[row['id']] case final input?)
          _task({...row, 'input_json': input}),
    ];
    // A queued agent's input is replaced atomically when its turn starts,
    // including on the remote host. Cache only the frozen input.
    for (final task in tasks) {
      if (task.kind == TaskKind.agent && task.status == TaskStatus.queued) {
        _listedInputs.remove(task.id);
      }
    }
    return tasks;
  }

  /// Returns the task without its request snapshots, like [listTasks].
  Future<GenerationTask> updateTask(
    String id, {
    required TaskStatus status,
    String? partialText,
    String? reasoning,
    String? error,
    Map<String, dynamic>? result,
  }) => _write(() async {
    final old = await getTask(id, snapshots: false);
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
    await _execute('DELETE FROM task_progress WHERE task_id = ?', [id]);
    return getTask(id, snapshots: false);
  }, tasksOnly: true);

  /// Saves a running task's streamed text beside its row, which keeps it
  /// until the task's next update: SQLite rewrites a whole row whose size
  /// changes, and a task row carries its frozen snapshots. Readers see it as
  /// the task's text. A task no longer running keeps the text it has.
  Future<void> saveTaskProgress(
    String id, {
    required String partialText,
    required String reasoning,
  }) => _write(
    () => _execute(
      '''INSERT INTO task_progress (task_id, partial_text, reasoning)
      SELECT id, ?, ? FROM generation_tasks WHERE id = ? AND status = 'running'
      ON CONFLICT(task_id) DO UPDATE SET
        partial_text = excluded.partial_text, reasoning = excluded.reasoning''',
      [partialText, reasoning, id],
    ),
    tasksOnly: true,
  );

  /// Sets a sidecar run's [transcript] whatever state the task is in:
  /// cancelling marks the task before its run stops.
  Future<void> saveTaskTranscript(
    String id,
    List<Map<String, dynamic>> transcript,
  ) => _write(
    () => _execute(
      "UPDATE generation_tasks SET result_json = json_set(result_json, '\$.transcript', json(?)), updated_at = ? WHERE id = ?",
      [jsonEncode(transcript), _now(), id],
    ),
    tasksOnly: true,
  );

  Future<int> recoverInterruptedTasks() => _write(() async {
    final rows = await _rows(
      "SELECT id FROM generation_tasks WHERE status IN ('queued','running')",
    );
    await _execute(
      "UPDATE generation_tasks SET status = 'interrupted', error = ?, updated_at = ?, $_settleProgress WHERE status IN ('queued','running')",
      ['应用上次退出时任务未完成，可保留已有结果或重新生成。', _now()],
    );
    await _execute('DELETE FROM task_progress');
    return rows.length;
  });

  /// Reattach only to the same immutable remote request. Historical chapter bases
  /// remain valid for retrieval; accepting the eventual proposal still uses CAS.
  Future<GenerationTask> requeueRemoteTask(String id) => _write(() async {
    final task = await getTask(id);
    if (!task.isRemote ||
        task.kind == TaskKind.agent ||
        task.kind == TaskKind.sidecar ||
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
          "UPDATE generation_tasks SET status = 'cancelled', error = '', updated_at = ?, "
          '$_settleProgress WHERE id = ?',
          [_now(), id],
        );
        await _execute('DELETE FROM task_progress WHERE task_id = ?', [id]);
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
    if (task.chapterId == null || task.baseRevisionId == null) {
      throw StateError('写作任务缺少正文依据');
    }
    if (![TaskKind.writing, TaskKind.rewrite].contains(task.kind)) {
      throw StateError('此任务不能生成正文提案');
    }
    final history = await listRevisions(
      branchId: task.branchId,
      chapterId: task.chapterId!,
    );
    if (!history.any((r) => r.id == task.baseRevisionId)) {
      throw const StoryNotFound('任务依据版本');
    }
    final proposalId = _id();
    await _execute(
      '''INSERT INTO proposals
      (id, branch_id, chapter_id, base_revision_id, content_json, summary, status, task_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)''',
      [
        proposalId,
        task.branchId,
        task.chapterId,
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
    await _execute('DELETE FROM task_progress WHERE task_id = ?', [id]);
    return getTask(id);
  });

  Future<BranchVariables> getBranchVariables(
    String branchId, {
    String? throughChapterId,
    bool includeCurrentChapter = true,
  }) => _variablesAt(
    branchId,
    throughChapterId: throughChapterId,
    includeCurrentChapter: includeCurrentChapter,
  );

  Future<void> _commitProposalVariables(
    ManuscriptProposal proposal,
    Chapter chapter,
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
      chapter: chapter,
      expectedVersion: variables.version,
      local: (result['local'] as Map? ?? {}).cast<String, String>(),
      global: (result['global'] as Map? ?? {}).cast<String, String>(),
    );
  }
}

/// Input keys holding frozen request snapshots: what replays or inspects one
/// task, and most of its size.
const _snapshotKeys = [
  'pendingAgent',
  'preset',
  'writingPreset',
  'agentPreset',
  'card',
  'compiled',
  'request',
  'outputRegex',
  'chapterSnapshot',
  'loreSnapshot',
  'skills',
  'originalContent',
  'writingContext',
  'mvu',
  'macroEnv',
  'chatMacros',
  'outlets',
];

/// A task's [column], streamed text included ([saveTaskProgress]).
String _live(String column) =>
    'coalesce((SELECT p.$column FROM task_progress p '
    'WHERE p.task_id = generation_tasks.id), $column)';

/// Moves a task's streamed text onto its row.
final _settleProgress =
    'partial_text = ${_live('partial_text')}, reasoning = ${_live('reasoning')}';
final _taskColumns =
    'id, branch_id, kind, status, chapter_id, base_revision_id, '
    '${_live('partial_text')} AS partial_text, ${_live('reasoning')} AS reasoning, '
    'error, result_json, retry_of, created_at, updated_at';
final _listedColumns = _taskColumns.replaceFirst(
  'result_json',
  "json_remove(result_json, '\$.transcript') AS result_json",
);
final _listedInput =
    'json_remove(input_json, ${_snapshotKeys.map((k) => "'\$.$k'").join(', ')})';

GenerationTask _task(Map<String, Object?> row) => GenerationTask.fromStoredJson(
  id: row['id'] as String,
  branchId: row['branch_id'] as String,
  kind: TaskKind.values.byName(row['kind'] as String),
  status: TaskStatus.values.byName(row['status'] as String),
  inputJson: row['input_json'] as String,
  partialText: row['partial_text'] as String,
  reasoning: row['reasoning'] as String,
  error: row['error'] as String,
  result: jsonDecode(row['result_json'] as String) as Map<String, dynamic>,
  chapterId: row['chapter_id'] as String?,
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
