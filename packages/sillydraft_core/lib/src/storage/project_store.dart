part of 'story_repository.dart';

extension ProjectOperations on StoryRepository {
  Future<ProjectSnapshot> exportProject(
    String novelId,
  ) => _db.transaction(() async {
    await getNovel(novelId);
    const branches = 'SELECT id FROM branches WHERE novel_id = ?';
    const tasks =
        'SELECT id FROM generation_tasks WHERE branch_id IN ($branches)';
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in projectTables) {
      String filter;
      if (table == 'library_resources' || table == 'app_settings') continue;
      if (table == 'novels') {
        filter = 'id = ?';
      } else if (['branches', 'revisions', 'story_assets'].contains(table)) {
        filter = 'novel_id = ?';
      } else if (table == 'agent_messages') {
        filter =
            'conversation_id IN (SELECT id FROM agent_conversations WHERE branch_id IN ($branches))';
      } else if ([
        'analysis_acceptances',
        'branch_candidate_selections',
      ].contains(table)) {
        filter = 'task_id IN ($tasks)';
      } else {
        filter = 'branch_id IN ($branches)';
      }
      final rows = await _rows(
        'SELECT * FROM $table WHERE $filter${table == 'lore_versions' ? ' ORDER BY sequence' : ''}',
        [novelId],
      );
      for (final row in rows) {
        if (table == 'lore_versions') row.remove('sequence');
      }
      if (table != 'lore_versions') {
        rows.sort((a, b) => canonicalJson(a).compareTo(canonicalJson(b)));
      }
      result[table] = rows;
    }
    final settingKeys = {
      'goal/$novelId',
      for (final row in result['branches']!) ...[
        'writing/${row['id']}',
        'progress/${row['id']}',
      ],
    };
    result['app_settings'] = (await _rows(
      'SELECT * FROM app_settings ORDER BY key',
    )).where((r) => settingKeys.contains(r['key'])).toList();
    final candidates = await _rows(
      'SELECT id,kind,name,filename,source_hash,data_json,parent_id,archived,created_at FROM library_resources ORDER BY id',
    );
    final resourceIds = candidates.map((r) => r['id'] as String).toSet(),
        referenced = <String>{};
    void visit(Object? value) {
      if (value is String && resourceIds.contains(value)) referenced.add(value);
      if (value is Map) {
        for (final v in value.values) {
          visit(v);
        }
      }
      if (value is List) {
        for (final v in value) {
          visit(v);
        }
      }
    }

    for (final rows in result.values) {
      for (final row in rows) {
        for (final e in row.entries) {
          visit(
            e.key.endsWith('_json') ? jsonDecode(e.value as String) : e.value,
          );
        }
      }
    }
    var changed = true;
    while (changed) {
      changed = false;
      for (final row in candidates.where((r) => referenced.contains(r['id']))) {
        final parent = row['parent_id'];
        if (parent is String && referenced.add(parent)) changed = true;
      }
    }
    result['library_resources'] = candidates
        .where((r) => referenced.contains(r['id']))
        .toList();
    return ProjectSnapshot.fromJson({
      'format': 'sillydraft-project',
      'version': 1,
      'schema': 6,
      'tables': result,
    });
  });

  /// The caller encrypts exact resource originals for this installation and
  /// installs verified content-addressed asset files before this transaction.
  /// Existing project replacement requires an exact observed fingerprint.
  Future<Novel> restoreProject(
    ProjectSnapshot snapshot, {
    required Map<String, List<int>> encryptedSources,
    String? expectedFingerprint,
    Map<String, dynamic>? syncState,
  }) => _write(() async {
    final tables = snapshot.tables;
    await _validateProjectRows(tables);
    _validateProjectGraph(tables);
    final novelId = snapshot.novelId;
    final existing = await _rows('SELECT id FROM novels WHERE id = ?', [
      novelId,
    ]);
    if (existing.isNotEmpty) {
      if (expectedFingerprint == null ||
          (await exportProject(novelId)).fingerprint != expectedFingerprint) {
        throw const ProjectConflict();
      }
      if ((await _rows(
        "SELECT id FROM generation_tasks WHERE branch_id IN (SELECT id FROM branches WHERE novel_id = ?) AND status IN ('queued','running')",
        [novelId],
      )).isNotEmpty) {
        throw StateError('请先停止本机正在运行的生成任务');
      }
    } else if (expectedFingerprint != null) {
      throw const ProjectConflict();
    }
    for (final resource in tables['library_resources']!) {
      final id = resource['id'] as String;
      if (!encryptedSources.containsKey(id) ||
          encryptedSources[id]!.length < 28) {
        throw const FormatException('备份缺少 ST 原始资源');
      }
    }
    await _execute('PRAGMA defer_foreign_keys = ON');
    if (existing.isNotEmpty) await _removeProjectRows(novelId);
    for (final table in projectTables) {
      for (final row in tables[table]!) {
        if (table == 'library_resources') {
          final previous = await _rows(
            'SELECT source_hash,data_json FROM library_resources WHERE id = ?',
            [row['id']],
          );
          if (previous.isNotEmpty) {
            if (previous.single['source_hash'] != row['source_hash'] ||
                previous.single['data_json'] != row['data_json']) {
              throw const FormatException('ST 资源标识与本机内容冲突');
            }
            continue;
          }
          row['encrypted_source'] = Uint8List.fromList(
            encryptedSources[row['id']]!,
          );
        }
        if (table == 'generation_tasks' &&
            ['queued', 'running'].contains(row['status'])) {
          row['status'] = 'interrupted';
          row['error'] = '从备份恢复：原生成连接已中断，可手动重新生成。';
        }
        final keys = row.keys.toList();
        await _execute(
          'INSERT INTO $table (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})',
          keys.map((k) => row[k]).toList(),
        );
      }
    }
    if ((await _rows('PRAGMA foreign_key_check')).isNotEmpty) {
      throw const FormatException('备份包含无效引用');
    }
    // Validate documents against imported local assets, including every old
    // revision and pending proposal, before committing any visible project.
    for (final table in ['revisions', 'proposals']) {
      for (final row in tables[table]!) {
        await _validateManuscriptAssets(
          novelId,
          ManuscriptContent.decode(row['content_json'] as String),
        );
      }
    }
    if (syncState != null) {
      await setSetting('syncState/$novelId', {
        ...syncState,
        'localFingerprint': (await exportProject(novelId)).fingerprint,
      });
    }
    return getNovel(novelId);
  });

  Future<void> _removeProjectRows(String id) async {
    final previous = (await exportProject(id)).tables;
    for (final table in projectTables.reversed) {
      if (table == 'library_resources') continue;
      if (table == 'app_settings') {
        for (final row in previous[table]!) {
          await _execute('DELETE FROM app_settings WHERE key = ?', [
            row['key'],
          ]);
        }
      } else if (table == 'novels') {
        await _execute('DELETE FROM novels WHERE id = ?', [id]);
      } else if (['branches', 'revisions', 'story_assets'].contains(table)) {
        await _execute('DELETE FROM $table WHERE novel_id = ?', [id]);
      } else if (table == 'agent_messages') {
        for (final row in previous[table]!) {
          await _execute('DELETE FROM agent_messages WHERE id = ?', [
            row['id'],
          ]);
        }
      } else if ([
        'analysis_acceptances',
        'branch_candidate_selections',
      ].contains(table)) {
        for (final row in previous['generation_tasks']!) {
          await _execute('DELETE FROM $table WHERE task_id = ?', [row['id']]);
        }
      } else {
        for (final row in previous['branches']!) {
          await _execute('DELETE FROM $table WHERE branch_id = ?', [row['id']]);
        }
      }
    }
  }

  Future<void> _validateProjectRows(
    Map<String, List<Map<String, dynamic>>> tables,
  ) async {
    for (final table in projectTables) {
      final info = await _rows('PRAGMA table_info($table)');
      final columns = {
        for (final c in info)
          if (c['name'] != 'encrypted_source' && c['name'] != 'sequence')
            c['name'] as String: c,
      };
      for (final row in tables[table]!) {
        if (row.length != columns.length ||
            row.keys.any((k) => !columns.containsKey(k))) {
          throw FormatException('备份字段不匹配：$table');
        }
        for (final e in row.entries) {
          final column = columns[e.key]!, value = e.value;
          if (value == null) {
            if (column['notnull'] == 1 || column['pk'] == 1) {
              throw const FormatException('备份必填字段为空');
            }
            continue;
          }
          if ((column['type'] == 'TEXT' && value is! String) ||
              (column['type'] == 'INTEGER' && value is! int)) {
            throw const FormatException('备份字段类型错误');
          }
          if (e.key.endsWith('_json')) {
            final decoded = jsonDecode(value as String);
            if (decoded is! Map<String, dynamic>) {
              throw const FormatException('备份结构化字段错误');
            }
            if (e.key == 'content_json') ManuscriptContent.fromJson(decoded);
          }
          if (['archived', 'deleted'].contains(e.key) &&
              value != 0 &&
              value != 1) {
            throw const FormatException('备份状态错误');
          }
          if ([
                'position',
                'offset',
                'version',
                'entry_index',
                'candidate_index',
              ].contains(e.key) &&
              (value as int) < 0) {
            throw const FormatException('备份位置错误');
          }
        }
      }
    }
  }
}

void _validateProjectGraph(Map<String, List<Map<String, dynamic>>> t) {
  Never invalid() => throw const FormatException('备份包含不完整、越界或循环的项目引用');
  Map<String, Map<String, dynamic>> index(String table, [String key = 'id']) {
    final out = <String, Map<String, dynamic>>{};
    for (final row in t[table]!) {
      final id = row[key];
      if (id is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id) ||
          out.containsKey(id)) {
        invalid();
      }
      out[id] = row;
    }
    return out;
  }

  final novels = index('novels'),
      branches = index('branches'),
      revisions = index('revisions'),
      tasks = index('generation_tasks'),
      conversations = index('agent_conversations'),
      assets = index('story_assets'),
      resources = index('library_resources'),
      lore = index('lore_versions', 'revision_id'),
      proposals = index('proposals');
  final novel = novels.values.single, novelId = novel['id'];
  if ((novel['title'] as String).trim().isEmpty ||
      !branches.containsKey(novel['active_branch_id'])) {
    invalid();
  }
  void ref(Object? id, Map<String, dynamic> set, {bool nullable = true}) {
    if (id == null && nullable) return;
    if (!set.containsKey(id)) invalid();
  }

  void cycle(Map<String, Map<String, dynamic>> rows, String parent) {
    final done = <String>{};
    for (final id in rows.keys) {
      final chain = <String>{};
      String? current = id;
      while (current != null && !done.contains(current)) {
        if (!chain.add(current) || !rows.containsKey(current)) invalid();
        current = rows[current]![parent] as String?;
      }
      done.addAll(chain);
    }
  }

  final chapterKeys = {
    for (final r in t['branch_chapters']!)
      '${r['branch_id']}/${r['chapter_id']}',
  };
  final sceneKeys = {
    for (final r in t['branch_scenes']!) '${r['branch_id']}/${r['scene_id']}',
  };
  if (chapterKeys.length != t['branch_chapters']!.length ||
      sceneKeys.length != t['branch_scenes']!.length) {
    invalid();
  }
  for (final name in projectTables) {
    for (final row in t[name]!) {
      if (row.containsKey('novel_id') && row['novel_id'] != novelId) invalid();
      if (row.containsKey('branch_id')) {
        ref(row['branch_id'], branches, nullable: false);
      }
      if (row.containsKey('origin_branch_id')) {
        ref(row['origin_branch_id'], branches, nullable: false);
      }
    }
  }
  ref(novel['cover_asset_id'], assets);
  for (final b in branches.values) {
    ref(b['parent_branch_id'], branches);
    ref(b['fork_revision_id'], revisions);
  }
  cycle(branches, 'parent_branch_id');
  cycle(revisions, 'parent_revision_id');
  cycle(resources, 'parent_id');
  cycle(lore, 'previous_revision_id');
  cycle(tasks, 'retry_of');
  for (final row in revisions.values) {
    ref(row['source_proposal_id'], proposals);
    final parent = revisions[row['parent_revision_id']];
    if (parent != null && parent['scene_id'] != row['scene_id']) invalid();
  }
  for (final row in t['branch_scenes']!) {
    if (!chapterKeys.contains('${row['branch_id']}/${row['chapter_id']}')) {
      invalid();
    }
    ref(row['revision_id'], revisions, nullable: false);
    if (revisions[row['revision_id']]!['scene_id'] != row['scene_id']) {
      invalid();
    }
  }
  for (final row in proposals.values) {
    if (!sceneKeys.contains('${row['branch_id']}/${row['scene_id']}')) {
      invalid();
    }
    ref(row['base_revision_id'], revisions, nullable: false);
    ref(row['accepted_revision_id'], revisions);
    ref(row['task_id'], tasks);
    if (!['pending', 'accepted', 'rejected'].contains(row['status'])) invalid();
    if (row['status'] == 'accepted' && row['accepted_revision_id'] == null) {
      invalid();
    }
  }
  for (final row in tasks.values) {
    if (!TaskKind.values.any((v) => v.name == row['kind']) ||
        !TaskStatus.values.any((v) => v.name == row['status'])) {
      invalid();
    }
    ref(row['base_revision_id'], revisions);
    if (row['scene_id'] != null &&
        !sceneKeys.contains('${row['branch_id']}/${row['scene_id']}')) {
      invalid();
    }
  }
  for (final row in conversations.values) {
    if (row['through_scene_id'] != null &&
        !sceneKeys.contains('${row['branch_id']}/${row['through_scene_id']}')) {
      invalid();
    }
  }
  for (final row in t['agent_messages']!) {
    ref(row['conversation_id'], conversations, nullable: false);
    if (!['user', 'assistant', 'tool', 'system'].contains(row['role'])) {
      invalid();
    }
  }
  for (final row in [...t['reading_bookmarks']!, ...t['variable_revisions']!]) {
    if (!sceneKeys.contains('${row['branch_id']}/${row['scene_id']}')) {
      invalid();
    }
    if (row.containsKey('revision_id')) {
      ref(row['revision_id'], revisions, nullable: false);
    }
  }
  for (final row in assets.values) {
    ref(row['source_revision_id'], revisions);
    ref(row['task_id'], tasks);
    if (!AssetPurpose.values.any((v) => v.name == row['purpose']) ||
        (row['width'] as int) < 1 ||
        (row['height'] as int) < 1 ||
        (row['width'] as int) * (row['height'] as int) > 16 * 1024 * 1024 ||
        (row['byte_length'] as int) < 1 ||
        (row['byte_length'] as int) > 32 * 1024 * 1024) {
      invalid();
    }
    for (final key in ['content_hash', 'thumbnail_hash']) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(row[key] as String)) invalid();
    }
  }
  for (final row in resources.values) {
    if (!ResourceKind.values.any((v) => v.name == row['kind']) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['source_hash'] as String)) {
      invalid();
    }
  }
  final entities = {
    for (final row in lore.values)
      '${row['branch_id']}/${row['entity_id']}': row,
  };
  for (final row in lore.values) {
    if (!LoreKind.values.any((v) => v.name == row['kind']) ||
        !LoreCertainty.values.any((v) => v.name == row['certainty'])) {
      invalid();
    }
    if (row['at_scene_id'] != null &&
        !sceneKeys.contains('${row['branch_id']}/${row['at_scene_id']}')) {
      invalid();
    }
    final data = jsonDecode(row['data_json'] as String) as Map<String, dynamic>;
    if (row['kind'] == 'relationship') {
      for (final key in ['fromId', 'toId']) {
        if (!entities.containsKey('${row['branch_id']}/${data[key]}')) {
          invalid();
        }
      }
    }
    if (row['kind'] == 'map') {
      ref(data['backgroundAssetId'], assets);
      final aspect = data['backgroundAspect'];
      if (aspect != null &&
          (aspect is! num || !aspect.isFinite || aspect <= 0)) {
        invalid();
      }
      final points = data['points'] ?? <dynamic>[],
          routes = data['routes'] ?? <dynamic>[];
      if (points is! List ||
          routes is! List ||
          points.length > 2000 ||
          routes.length > 500) {
        invalid();
      }
      final pointIds = <String>{};
      for (final point in points) {
        if (point is! Map ||
            point['id'] is! String ||
            !pointIds.add(point['id'] as String) ||
            point['label'] != null && point['label'] is! String) {
          invalid();
        }
        for (final k in ['x', 'y']) {
          final n = point[k];
          if (n is! num || !n.isFinite || n < 0 || n > 1) invalid();
        }
        if (point['entityId'] != null &&
            !entities.containsKey('${row['branch_id']}/${point['entityId']}')) {
          invalid();
        }
      }
      final routeIds = <String>{};
      for (final route in routes) {
        if (route is! Map ||
            route['id'] is! String ||
            !routeIds.add(route['id'] as String) ||
            route['pointIds'] is! List ||
            (route['pointIds'] as List).length < 2 ||
            (route['pointIds'] as List).any((p) => !pointIds.contains(p))) {
          invalid();
        }
      }
    }
    final provenance = jsonDecode(row['provenance_json'] as String) as Map;
    ref(provenance['revisionId'], revisions);
    ref(provenance['resourceId'], resources);
    ref(provenance['taskId'], tasks);
  }
  for (final row in t['analysis_acceptances']!) {
    ref(row['task_id'], tasks, nullable: false);
    ref(row['revision_id'], lore, nullable: false);
  }
  for (final row in t['branch_candidate_selections']!) {
    ref(row['task_id'], tasks, nullable: false);
  }
  final settingKeys = {
    'goal/$novelId',
    for (final id in branches.keys) ...['writing/$id', 'progress/$id'],
  };
  for (final row in t['app_settings']!) {
    if (!settingKeys.contains(row['key'])) invalid();
    final value = jsonDecode(row['value_json'] as String) as Map;
    if ((row['key'] as String).startsWith('writing/')) {
      for (final key in [
        'presetId',
        'cardId',
        'contextId',
        'instructId',
        'systemPromptId',
        'reasoningId',
      ]) {
        ref(value[key], resources);
      }
      for (final key in ['worldBookIds', 'regexIds']) {
        if (value[key] != null && value[key] is! List) invalid();
        for (final id in value[key] as List? ?? []) {
          ref(id, resources, nullable: false);
        }
      }
    }
  }
}
