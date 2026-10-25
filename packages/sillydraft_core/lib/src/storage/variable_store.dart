part of 'story_repository.dart';

extension VariableOperations on StoryRepository {
  Future<BranchVariables> _variablesAt(
    String branchId, {
    String? throughChapterId,
  }) async {
    final story = await getStory(branchId);
    final positions = {for (final (i, s) in story.chapters.indexed) s.id: i};
    if (throughChapterId != null && !positions.containsKey(throughChapterId)) {
      throw const StoryNotFound('变量查询位置');
    }
    final cutoff = throughChapterId == null
        ? story.chapters.length - 1
        : positions[throughChapterId]!;
    final heads = await _rows(
      'SELECT version FROM branch_variables WHERE branch_id = ?',
      [branchId],
    );
    Map<String, Object?>? selected;
    var selectedPosition = -1;
    for (final row in await _rows(
      'SELECT * FROM variable_revisions WHERE branch_id = ? ORDER BY version',
      [branchId],
    )) {
      final position = positions[row['chapter_id']];
      if (position != null &&
          position <= cutoff &&
          position >= selectedPosition) {
        selected = row;
        selectedPosition = position;
      }
    }
    return BranchVariables(
      version: heads.isEmpty ? 0 : heads.single['version'] as int,
      local: selected == null
          ? {}
          : (jsonDecode(selected['local_json'] as String) as Map)
                .cast<String, String>(),
      global: selected == null
          ? {}
          : (jsonDecode(selected['global_json'] as String) as Map)
                .cast<String, String>(),
    );
  }

  Future<BranchVariables> setBranchVariables({
    required String branchId,
    required String chapterId,
    required int expectedVersion,
    Map<String, String> local = const {},
    Map<String, String> global = const {},
  }) => _write(() async {
    final chapter = await getChapter(branchId: branchId, chapterId: chapterId);
    await _setBranchVariables(
      branchId: branchId,
      chapter: chapter,
      expectedVersion: expectedVersion,
      local: local,
      global: global,
    );
    return getBranchVariables(branchId, throughChapterId: chapterId);
  });

  /// Writes a chapter's variables, keeping whatever table ([local] or
  /// [global]) is not given as it stands at that chapter. Conflicts with a
  /// concurrent writer surface as [VariableConflict].
  Future<BranchVariables> patchBranchVariables({
    required String branchId,
    required String chapterId,
    Map<String, String>? local,
    Map<String, String>? global,
  }) async {
    final current = await getBranchVariables(
      branchId,
      throughChapterId: chapterId,
    );
    return setBranchVariables(
      branchId: branchId,
      chapterId: chapterId,
      expectedVersion: current.version,
      local: local ?? current.local,
      global: global ?? current.global,
    );
  }

  Future<void> _setBranchVariables({
    required String branchId,
    required Chapter chapter,
    required int expectedVersion,
    required Map<String, String> local,
    required Map<String, String> global,
  }) async {
    final current = await getBranchVariables(branchId);
    if (current.version != expectedVersion) throw const VariableConflict();
    final version = current.version + 1;
    await _execute(
      '''INSERT INTO variable_revisions (id,branch_id,version,chapter_id,revision_id,local_json,global_json,created_at)
        VALUES (?,?,?,?,?,?,?,?)''',
      [
        _id(),
        branchId,
        version,
        chapter.id,
        chapter.revisionId,
        jsonEncode(local),
        jsonEncode(global),
        _now(),
      ],
    );
    // Editing an earlier chapter must not replace later narrative state. The
    // monotonically increasing version still detects concurrent acceptance.
    final projected = await _variablesAt(branchId);
    await _execute(
      '''INSERT INTO branch_variables (branch_id,version,local_json,global_json) VALUES (?,?,?,?)
        ON CONFLICT(branch_id) DO UPDATE SET version=excluded.version,local_json=excluded.local_json,global_json=excluded.global_json''',
      [
        branchId,
        version,
        jsonEncode(projected.local),
        jsonEncode(projected.global),
      ],
    );
  }

  /// Brings back the variables [chapter] had at the version it was just
  /// restored to, as MVU keeps them per message swipe: the newest record
  /// made with the first version on [lineage] that has one, or without any
  /// what the chapters before it hand down. Later chapters keep their own
  /// records, as ST leaves later messages alone.
  Future<void> _restoreVariables(
    String branchId,
    Chapter chapter,
    List<String> lineage,
  ) async {
    final records = await _rows(
      '''SELECT * FROM variable_revisions WHERE branch_id = ? AND chapter_id = ?
      ORDER BY version DESC''',
      [branchId, chapter.id],
    );
    // A chapter that never had variables of its own has none to restore.
    if (records.isEmpty) return;
    Map<String, Object?>? record;
    for (final id in lineage) {
      record = records.where((r) => r['revision_id'] == id).firstOrNull;
      if (record != null) break;
    }
    final BranchVariables restored;
    if (record != null) {
      restored = BranchVariables(
        version: 0,
        local: (jsonDecode(record['local_json'] as String) as Map)
            .cast<String, String>(),
        global: (jsonDecode(record['global_json'] as String) as Map)
            .cast<String, String>(),
      );
    } else {
      final chapters = (await getStory(branchId)).chapters;
      final at = chapters.indexWhere((s) => s.id == chapter.id);
      restored = at == 0
          ? BranchVariables(version: 0)
          : await _variablesAt(branchId, throughChapterId: chapters[at - 1].id);
    }
    final current = await _variablesAt(branchId, throughChapterId: chapter.id);
    bool same(Map<String, String> a, Map<String, String> b) =>
        a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
    // An unchanged state is not written, so it cannot fail a generation that
    // is waiting to commit its own.
    if (same(current.local, restored.local) &&
        same(current.global, restored.global)) {
      return;
    }
    await _setBranchVariables(
      branchId: branchId,
      chapter: chapter,
      expectedVersion: current.version,
      local: restored.local,
      global: restored.global,
    );
  }

  Future<void> _forkSideData(
    StorySnapshot source,
    String branchId,
    List<Chapter> included,
  ) async {
    final chapters = included.map((s) => s.id).toSet();
    final revisions = <String, String>{};
    for (final row in await _rows(
      'SELECT * FROM lore_versions WHERE branch_id = ? ORDER BY sequence',
      [source.branch.id],
    )) {
      if (row['at_chapter_id'] != null &&
          !chapters.contains(row['at_chapter_id'])) {
        continue;
      }
      final id = _id();
      revisions[row['revision_id'] as String] = id;
      await _execute(
        '''INSERT INTO lore_versions
        (revision_id,entity_id,branch_id,previous_revision_id,kind,name,content,certainty,data_json,provenance_json,at_chapter_id,deleted,created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [
          id,
          row['entity_id'],
          branchId,
          revisions[row['previous_revision_id']] ?? row['revision_id'],
          row['kind'],
          row['name'],
          row['content'],
          row['certainty'],
          row['data_json'],
          row['provenance_json'],
          row['at_chapter_id'],
          row['deleted'],
          row['created_at'],
        ],
      );
    }
    var version = 0;
    for (final row in await _rows(
      'SELECT * FROM variable_revisions WHERE branch_id = ? ORDER BY version',
      [source.branch.id],
    )) {
      if (!chapters.contains(row['chapter_id'])) continue;
      version = row['version'] as int;
      await _execute(
        '''INSERT INTO variable_revisions(id,branch_id,version,chapter_id,revision_id,local_json,global_json,created_at)
        VALUES (?,?,?,?,?,?,?,?)''',
        [
          _id(),
          branchId,
          version,
          row['chapter_id'],
          row['revision_id'],
          row['local_json'],
          row['global_json'],
          row['created_at'],
        ],
      );
    }
    final variables = await _variablesAt(branchId);
    await _execute(
      'INSERT INTO branch_variables(branch_id,version,local_json,global_json) VALUES (?,?,?,?)',
      [
        branchId,
        version,
        jsonEncode(variables.local),
        jsonEncode(variables.global),
      ],
    );
    final profile = await getSetting('writing/${source.branch.id}');
    if (profile != null) await setSetting('writing/$branchId', profile);
  }
}
