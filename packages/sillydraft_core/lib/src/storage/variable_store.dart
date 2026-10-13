part of 'story_repository.dart';

extension VariableOperations on StoryRepository {
  Future<BranchVariables> _variablesAt(
    String branchId, {
    String? throughSceneId,
  }) async {
    final story = await getStory(branchId);
    final positions = {for (final (i, s) in story.scenes.indexed) s.id: i};
    if (throughSceneId != null && !positions.containsKey(throughSceneId)) {
      throw const StoryNotFound('变量查询位置');
    }
    final cutoff = throughSceneId == null
        ? story.scenes.length - 1
        : positions[throughSceneId]!;
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
      final position = positions[row['scene_id']];
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
    required String sceneId,
    required int expectedVersion,
    Map<String, String> local = const {},
    Map<String, String> global = const {},
  }) => _write(() async {
    final scene = await getScene(branchId: branchId, sceneId: sceneId);
    await _setBranchVariables(
      branchId: branchId,
      scene: scene,
      expectedVersion: expectedVersion,
      local: local,
      global: global,
    );
    return getBranchVariables(branchId, throughSceneId: sceneId);
  });

  /// Writes a scene's variables, keeping whatever table ([local] or
  /// [global]) is not given as it stands at that scene. Conflicts with a
  /// concurrent writer surface as [VariableConflict].
  Future<BranchVariables> patchBranchVariables({
    required String branchId,
    required String sceneId,
    Map<String, String>? local,
    Map<String, String>? global,
  }) async {
    final current = await getBranchVariables(branchId, throughSceneId: sceneId);
    final head = await getBranchVariables(branchId);
    return setBranchVariables(
      branchId: branchId,
      sceneId: sceneId,
      expectedVersion: head.version,
      local: local ?? current.local,
      global: global ?? current.global,
    );
  }

  Future<void> _setBranchVariables({
    required String branchId,
    required Scene scene,
    required int expectedVersion,
    required Map<String, String> local,
    required Map<String, String> global,
  }) async {
    final current = await getBranchVariables(branchId);
    if (current.version != expectedVersion) throw const VariableConflict();
    final version = current.version + 1;
    await _execute(
      '''INSERT INTO variable_revisions (id,branch_id,version,scene_id,revision_id,local_json,global_json,created_at)
        VALUES (?,?,?,?,?,?,?,?)''',
      [
        _id(),
        branchId,
        version,
        scene.id,
        scene.revisionId,
        jsonEncode(local),
        jsonEncode(global),
        _now(),
      ],
    );
    // Editing an earlier scene must not replace later narrative state. The
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

  Future<void> _forkSideData(
    StorySnapshot source,
    String branchId,
    List<Scene> included,
  ) async {
    final scenes = included.map((s) => s.id).toSet();
    final revisions = <String, String>{};
    for (final row in await _rows(
      'SELECT * FROM lore_versions WHERE branch_id = ? ORDER BY sequence',
      [source.branch.id],
    )) {
      if (row['at_scene_id'] != null && !scenes.contains(row['at_scene_id'])) {
        continue;
      }
      final id = _id();
      revisions[row['revision_id'] as String] = id;
      await _execute(
        '''INSERT INTO lore_versions
        (revision_id,entity_id,branch_id,previous_revision_id,kind,name,content,certainty,data_json,provenance_json,at_scene_id,deleted,created_at)
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
          row['at_scene_id'],
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
      if (!scenes.contains(row['scene_id'])) continue;
      version = row['version'] as int;
      await _execute(
        '''INSERT INTO variable_revisions(id,branch_id,version,scene_id,revision_id,local_json,global_json,created_at)
        VALUES (?,?,?,?,?,?,?,?)''',
        [
          _id(),
          branchId,
          version,
          row['scene_id'],
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
