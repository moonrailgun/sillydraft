import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model/manuscript.dart';

typedef _Row = Map<String, dynamic>;

/// Turns the v6/v7 chapter/scene graph into complete, branch-local chapters.
/// Revision IDs are deterministic so importing a backup twice has one fingerprint.
Map<String, List<Map<String, dynamic>>> migrateLegacyChapters(
  Map<String, List<Map<String, dynamic>>> tables,
) {
  final result = {
    for (final entry in tables.entries)
      entry.key: [
        for (final row in entry.value) Map<String, dynamic>.from(row),
      ],
  };
  if (!tables.containsKey('branch_scenes')) return result;
  final oldRevisions = {
    for (final row in tables['revisions'] ?? <_Row>[]) row['id'] as String: row,
  };
  final branches = {
    for (final row in tables['branches'] ?? <_Row>[]) row['id'] as String: row,
  };
  final sceneChapters = <String, String>{};
  final scenesByBranch = <String, Map<String, _Row>>{};
  for (final scene in tables['branch_scenes']!) {
    final id = scene['scene_id'] as String;
    final chapter = scene['chapter_id'] as String;
    if (sceneChapters[id] != null && sceneChapters[id] != chapter) {
      throw const FormatException('旧场景的章节归属不一致');
    }
    sceneChapters[id] = chapter;
    (scenesByBranch[scene['branch_id'] as String] ??= {})[id] = scene;
  }
  final contexts = <String, _ChapterMigration>{};
  final revisions = <String, _Row>{};
  final chapters = tables['branch_chapters'] ?? <_Row>[];
  for (final chapter in chapters) {
    final branchId = chapter['branch_id'] as String;
    final chapterId = chapter['chapter_id'] as String;
    final branch = branches[branchId];
    if (branch == null) throw const FormatException('旧章节缺少分支');
    final scenes =
        (scenesByBranch[branchId]?.values ?? <_Row>[])
            .where((s) => s['chapter_id'] == chapterId)
            .toList()
          ..sort(_positionOrder);
    final context = _ChapterMigration(
      branchId,
      chapterId,
      branch,
      chapter,
      scenes,
      oldRevisions,
      revisions,
    );
    contexts['$branchId/$chapterId'] = context;
    context.build();
  }
  _ChapterMigration? contextFor(String? branch, Object? scene) =>
      contexts['$branch/${sceneChapters[scene] ?? scene}'];
  String? mapRevision(String? id, String? branch, {bool current = false}) {
    if (id == null) return null;
    final old = oldRevisions[id];
    if (old == null) return id;
    final context = contextFor(branch, old['scene_id']);
    if (current && context?.isHead(id) == true) return context!.head;
    return context?.revisionIds[id] ?? id;
  }

  // Deleted chapters have no surviving membership rows. Retain their history
  // under the old scene ID instead of inventing a visible chapter.
  for (final entry in oldRevisions.entries) {
    if (revisions.containsKey(entry.key)) continue;
    final old = entry.value;
    final context = contextFor(
      old['origin_branch_id'] as String?,
      old['scene_id'],
    );
    final mapped = context?.revisionIds[entry.key];
    revisions[entry.key] = mapped == null
        ? {
            ...old,
            'chapter_id': sceneChapters[old['scene_id']] ?? old['scene_id'],
          }
        : {...revisions[mapped]!, 'id': entry.key};
    revisions[entry.key]!.remove('scene_id');
    if (mapped == null) {
      revisions[entry.key]!['parent_revision_id'] = mapRevision(
        old['parent_revision_id'] as String?,
        old['origin_branch_id'] as String?,
      );
    }
  }

  Object? remapJson(Object? value, String? branch, [String key = '']) {
    // These are author data, not application references.
    if (['local', 'global', 'variables', 'delta'].contains(key)) return value;
    if (value is List) {
      if (key == 'sourceRevisions') {
        final groups = <String, List<_Row>>{};
        for (final item in value) {
          if (item is! Map<String, dynamic> || item['sceneId'] is! String) {
            return value.map((v) => remapJson(v, branch)).toList();
          }
          final chapter =
              sceneChapters[item['sceneId']] ?? item['sceneId'] as String;
          (groups[chapter] ??= []).add(item);
        }
        return [
          for (final entry in groups.entries)
            {
              'chapterId': entry.key,
              'revisionId':
                  contexts['$branch/${entry.key}']?.pin(entry.value) ??
                  mapRevision(
                    entry.value.last['revisionId'] as String?,
                    branch,
                  ),
            },
        ];
      }
      if (key == 'sceneSnapshot') {
        final groups = <String, List<_Row>>{};
        for (final item in value) {
          if (item is! Map<String, dynamic> || item['id'] is! String) {
            return value.map((v) => remapJson(v, branch)).toList();
          }
          final chapter = sceneChapters[item['id']] ?? item['id'] as String;
          (groups[chapter] ??= []).add(item);
        }
        return [
          for (final entry in groups.entries)
            {
              ...entry.value.first,
              'id': entry.key,
              'title':
                  contexts['$branch/${entry.key}']?.chapter['title'] ??
                  entry.value.first['title'],
              'text': entry.value.map((v) => v['text'] as String? ?? '').join(),
              'revisionId':
                  contexts['$branch/${entry.key}']?.pin([
                    for (final item in entry.value)
                      {'sceneId': item['id'], 'revisionId': item['revisionId']},
                  ]) ??
                  mapRevision(
                    entry.value.last['revisionId'] as String?,
                    branch,
                  ),
            },
        ];
      }
      return value.map((v) => remapJson(v, branch, key)).toList();
    }
    if (value is Map) {
      final mapped = <String, dynamic>{};
      for (final entry in value.entries) {
        final oldKey = entry.key as String;
        final newKey = _rename(oldKey);
        mapped[newKey] = remapJson(entry.value, branch, oldKey);
      }
      return mapped;
    }
    if (value is String) {
      if (_sceneIdKey(key)) return sceneChapters[value] ?? value;
      if (key.endsWith('RevisionId') || key == 'revisionId') {
        return mapRevision(value, branch, current: true);
      }
      if (['name', 'tool', 'toolName'].contains(key)) return _rename(value);
      if (['arguments', 'result'].contains(key)) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is Map || decoded is List) {
            return jsonEncode(remapJson(decoded, branch));
          }
        } on FormatException {
          // Plain tool output remains plain text.
        }
      }
    }
    return value;
  }

  final conversationBranches = {
    for (final row in tables['agent_conversations'] ?? <_Row>[])
      row['id']: row['branch_id'] as String,
  };
  for (final entry in result.entries) {
    if (['revisions', 'branch_chapters', 'branch_scenes'].contains(entry.key))
      continue;
    for (final row in entry.value) {
      final branchId =
          row['branch_id'] as String? ??
          conversationBranches[row['conversation_id']] ??
          (entry.key == 'branches' ? row['id'] as String? : null) ??
          (entry.key == 'app_settings'
              ? (row['key'] as String).split('/').last
              : null);
      final oldScene = row['scene_id'];
      final context = contextFor(branchId, oldScene);
      final oldBase = row['base_revision_id'] as String?;
      if (entry.key == 'proposals' && context != null && oldScene is String) {
        row['content_json'] = context
            .mergeAt(
              oldBase,
              replaceScene: oldScene,
              replacement: ManuscriptContent.decode(
                row['content_json'] as String,
              ),
              current: context.isHead(oldBase),
            )
            .encoded;
      }
      if (entry.key == 'reading_bookmarks' && oldScene is String) {
        row['offset'] =
            (row['offset'] as int) + (context?.offset(oldScene) ?? 0);
      }
      for (final key in row.keys.toList()) {
        final value = row[key];
        final renamed = _rename(key);
        if (renamed != key) row.remove(key);
        if (_sceneIdKey(key)) {
          row[renamed] = sceneChapters[value] ?? value;
        } else if (key.endsWith('revision_id') &&
            !['lore_versions', 'analysis_acceptances'].contains(entry.key)) {
          row[renamed] = mapRevision(
            value as String?,
            branchId,
            current:
                key == 'base_revision_id' ||
                entry.key == 'variable_revisions' ||
                entry.key == 'story_assets',
          );
        } else if (key.endsWith('_json') &&
            value is String &&
            !['content_json', 'local_json', 'global_json'].contains(key) &&
            !(entry.key == 'library_resources' && key == 'data_json')) {
          final decoded = jsonDecode(value);
          if (entry.key == 'generation_tasks' &&
              key == 'input_json' &&
              decoded is Map<String, dynamic> &&
              context != null &&
              oldScene is String &&
              decoded['originalContent'] is Map<String, dynamic>) {
            final original = ManuscriptContent.fromJson(
              decoded['originalContent'] as Map<String, dynamic>,
            );
            final isCurrent = context.isHead(oldBase);
            final start = context.offset(
              oldScene,
              at: isCurrent ? null : oldBase,
            );
            final range = decoded['replacementRange'] as Map<String, dynamic>?;
            decoded['originalContent'] = context
                .mergeAt(
                  oldBase,
                  replaceScene: oldScene,
                  replacement: original,
                  current: isCurrent,
                )
                .toJson();
            decoded['replacementRange'] = {
              'start':
                  start +
                  (range?['start'] as int? ??
                      (decoded['append'] == true &&
                              original.text.trim().isNotEmpty
                          ? original.text.length - 1
                          : 0)),
              'end':
                  start + (range?['end'] as int? ?? original.text.length - 1),
            };
          }
          if (entry.key == 'app_settings' &&
              (row['key'] as String).startsWith('progress/') &&
              decoded is Map<String, dynamic>) {
            final scene = decoded['sceneId'];
            final progressContext = contextFor(branchId, scene);
            if (scene is String &&
                progressContext != null &&
                decoded['fraction'] is num) {
              final length = progressContext.sceneContent(scene).text.length;
              decoded['fraction'] =
                  (progressContext.offset(scene) +
                      (decoded['fraction'] as num) * length) /
                  progressContext.mergeAt(null, current: true).text.length;
            }
          }
          row[renamed] = jsonEncode(remapJson(decoded, branchId));
        } else {
          row[renamed] = value;
        }
      }
    }
  }
  // Collapsing several positions must not let a later edit of an earlier scene
  // override narrative state from a later scene in the same chapter.
  void retainNarrativeOrder(String table, String order, String? entity) {
    final groups = <String, List<_Row>>{};
    final originals = tables[table] ?? <_Row>[];
    final migrated = result[table] ?? <_Row>[];
    for (var i = 0; i < originals.length; i++) {
      final row = originals[i];
      final scene = row[table == 'lore_versions' ? 'at_scene_id' : 'scene_id'];
      final chapter = sceneChapters[scene];
      if (chapter == null) continue;
      final group =
          '${row['branch_id']}/$chapter/${entity == null ? '' : row[entity]}';
      (groups[group] ??= []).add({'old': row, 'new': migrated[i]});
    }
    for (final group in groups.values) {
      final slots = [
        for (final pair in group) (pair['old'] as _Row)[order] as int,
      ]..sort();
      group.sort((a, b) {
        final left = a['old'] as _Row, right = b['old'] as _Row;
        final key = table == 'lore_versions' ? 'at_scene_id' : 'scene_id';
        final scenes = scenesByBranch[left['branch_id']];
        final position = (scenes?[left[key]]?['position'] as int? ?? -1)
            .compareTo(scenes?[right[key]]?['position'] as int? ?? -1);
        return position != 0
            ? position
            : (left[order] as int).compareTo(right[order] as int);
      });
      for (var i = 0; i < group.length; i++) {
        (group[i]['new'] as _Row)[order] = slots[i];
      }
    }
  }

  retainNarrativeOrder('variable_revisions', 'version', null);
  retainNarrativeOrder('lore_versions', 'sequence', 'entity_id');
  result['branch_chapters'] = [
    for (final chapter in chapters)
      {
        ...chapter,
        'revision_id':
            contexts['${chapter['branch_id']}/${chapter['chapter_id']}']!.head,
      },
  ];
  result['revisions'] = revisions.values.toList();
  result.remove('branch_scenes');
  return result;
}

bool _sceneIdKey(String key) =>
    key == 'sceneId' ||
    key.endsWith('SceneId') ||
    key == 'scene_id' ||
    key.endsWith('_scene_id') ||
    key == 'sceneIds' ||
    key.endsWith('SceneIds');

String _rename(String key) => (key == 'scenes' ? 'chapters' : key)
    .replaceAll('scene_', 'chapter_')
    .replaceAll('_scenes', '_chapters')
    .replaceAll('_scene', '_chapter')
    .replaceAll('sceneId', 'chapterId')
    .replaceAll('SceneId', 'ChapterId')
    .replaceAll('sceneSnapshot', 'chapterSnapshot');

int _positionOrder(_Row a, _Row b) {
  final position = (a['position'] as int).compareTo(b['position'] as int);
  return position != 0
      ? position
      : (a['scene_id'] as String).compareTo(b['scene_id'] as String);
}

final class _ChapterMigration {
  _ChapterMigration(
    this.branchId,
    this.chapterId,
    this.branch,
    this.chapter,
    this.scenes,
    this.oldRevisions,
    this.output,
  );
  final String branchId, chapterId;
  final _Row branch, chapter;
  final List<_Row> scenes;
  final Map<String, _Row> oldRevisions, output;
  final revisionIds = <String, String>{};
  final events = <String>[];
  late String head;

  String id(String kind, Object value) =>
      'chapter_${sha256.convert(utf8.encode(jsonEncode([kind, branchId, chapterId, value])))}';

  void build() {
    final ancestors = <String>{};
    for (final scene in scenes) {
      String? cursor = scene['revision_id'] as String;
      final seen = <String>{};
      while (cursor != null) {
        if (!seen.add(cursor)) throw const FormatException('旧正文历史存在循环');
        final revision = oldRevisions[cursor];
        if (revision == null || revision['scene_id'] != scene['scene_id']) {
          throw const FormatException('旧正文历史不完整');
        }
        ancestors.add(cursor);
        cursor = revision['parent_revision_id'] as String?;
      }
    }
    final ordered = ancestors.toList()
      ..sort((a, b) {
        final time = (oldRevisions[a]!['created_at'] as int).compareTo(
          oldRevisions[b]!['created_at'] as int,
        );
        return time != 0 ? time : a.compareTo(b);
      });
    final visited = <String>{};
    void visit(String event) {
      if (visited.contains(event)) return;
      final parent = oldRevisions[event]!['parent_revision_id'] as String?;
      if (parent != null && ancestors.contains(parent)) visit(parent);
      visited.add(event);
      events.add(event);
    }

    for (final event in ordered) {
      visit(event);
    }
    String? previous;
    final state = <String, String>{};
    for (final event in events) {
      final old = oldRevisions[event]!;
      state[old['scene_id'] as String] = event;
      final next = old['origin_branch_id'] == branchId
          ? event
          : id('revision', event);
      revisionIds[event] = next;
      output[next] = {
        ...old,
        'id': next,
        'chapter_id': chapterId,
        'origin_branch_id': branchId,
        'parent_revision_id': previous,
        'content_json': merge(state).encoded,
      }..remove('scene_id');
      previous = next;
    }
    if (previous == null) {
      previous = id('empty', chapterId);
      output[previous] = {
        'id': previous,
        'novel_id': branch['novel_id'],
        'chapter_id': chapterId,
        'origin_branch_id': branchId,
        'parent_revision_id': null,
        'content_json': ManuscriptContent.plainText('').encoded,
        'created_at': branch['created_at'],
        'reason': 'migration',
        'source_proposal_id': null,
      };
    }
    head = previous;
  }

  bool isHead(String? revision) =>
      scenes.any((scene) => scene['revision_id'] == revision);

  Map<String, String> stateAt(String? event, {bool current = false}) {
    if (current || event == null)
      return {
        for (final scene in scenes)
          scene['scene_id'] as String: scene['revision_id'] as String,
      };
    final state = <String, String>{};
    for (final id in events) {
      state[oldRevisions[id]!['scene_id'] as String] = id;
      if (id == event) return state;
    }
    throw const FormatException('旧正文基线不在分支历史中');
  }

  ManuscriptContent sceneContent(String scene) => ManuscriptContent.decode(
    oldRevisions[scenes.firstWhere(
          (s) => s['scene_id'] == scene,
        )['revision_id']]!['content_json']
        as String,
  );

  ManuscriptContent merge(
    Map<String, String> state, {
    String? replaceScene,
    ManuscriptContent? replacement,
  }) => ManuscriptContent.fromDelta([
    for (final scene in scenes)
      if (scene['scene_id'] == replaceScene)
        ...replacement!.delta
      else if (state[scene['scene_id']] case final String revision)
        ...ManuscriptContent.decode(
          oldRevisions[revision]!['content_json'] as String,
        ).delta,
  ]);

  ManuscriptContent mergeAt(
    String? revision, {
    String? replaceScene,
    ManuscriptContent? replacement,
    bool current = false,
  }) => merge(
    stateAt(revision, current: current),
    replaceScene: replaceScene,
    replacement: replacement,
  );

  int offset(String scene, {String? at}) {
    final state = stateAt(at);
    var offset = 0;
    for (final item in scenes) {
      if (item['scene_id'] == scene) break;
      final revision = state[item['scene_id']];
      if (revision != null)
        offset += ManuscriptContent.decode(
          oldRevisions[revision]!['content_json'] as String,
        ).text.length;
    }
    return offset;
  }

  String pin(List<_Row> sources) {
    final state = {
      for (final source in sources)
        source['sceneId'] as String: source['revisionId'] as String,
    };
    if (scenes.length == state.length &&
        scenes.every((s) => state[s['scene_id']] == s['revision_id']))
      return head;
    final key = id('snapshot', [
      for (final scene in scenes)
        if (state[scene['scene_id']] != null)
          [scene['scene_id'], state[scene['scene_id']]],
    ]);
    final source = oldRevisions[state.values.last];
    if (source == null) throw const FormatException('旧任务的正文快照不完整');
    output.putIfAbsent(
      key,
      () => {
        ...source,
        'id': key,
        'chapter_id': chapterId,
        'origin_branch_id': branchId,
        'parent_revision_id': null,
        'content_json': merge(state).encoded,
      }..remove('scene_id'),
    );
    return key;
  }
}
