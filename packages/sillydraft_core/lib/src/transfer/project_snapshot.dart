import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../model/comic.dart';

/// Versioned, portable project graph. Encrypted ST sources and image bytes are
/// separate archive members; no global connection settings or secrets are here.
final class ProjectSnapshot {
  factory ProjectSnapshot.fromJson(Map<String, dynamic> json) {
    json = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
    final legacy = json['version'] == 1 && json['schema'] == 9;
    if (json['format'] != 'sillydraft-project' ||
        (!legacy && (json['version'] != 2 || json['schema'] != 12)) ||
        json['tables'] is! Map) {
      throw const FormatException('不支持的项目备份格式');
    }
    final tables = json['tables'] as Map;
    final expected = projectTables
        .where(
          (t) => !legacy || !['comic_revisions', 'branch_comics'].contains(t),
        )
        .toList();
    if (tables.length != expected.length ||
        tables.keys.any((k) => !expected.contains(k))) {
      throw const FormatException('备份数据表不完整');
    }
    var count = 0;
    for (final name in expected) {
      final rows = tables[name];
      if (rows is! List) throw const FormatException('备份数据表无效');
      count += rows.length;
      if (count > 200000 || rows.any((r) => r is! Map<String, dynamic>)) {
        throw const FormatException('备份记录无效或过多');
      }
    }
    if ((tables['novels'] as List).length != 1) {
      throw const FormatException('备份须包含一部作品');
    }
    if (legacy) {
      final novel = (tables['novels'] as List).single as Map;
      if (novel.containsKey('work_format')) {
        throw const FormatException('旧备份包含未知字段');
      }
      novel['work_format'] = 'novel';
      tables['comic_revisions'] = <dynamic>[];
      tables['branch_comics'] = <dynamic>[];
      json['version'] = 2;
      json['schema'] = 12;
    }
    return ProjectSnapshot._(jsonEncode(json));
  }
  ProjectSnapshot._(this._encoded);
  final String _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  Map<String, List<Map<String, dynamic>>> get tables => {
    for (final e in (toJson()['tables'] as Map<String, dynamic>).entries)
      e.key: (e.value as List).cast<Map<String, dynamic>>(),
  };
  String get novelId => tables['novels']!.single['id'] as String;
  String get title => tables['novels']!.single['title'] as String;
  String get fingerprint {
    final json = toJson();
    // Reading on another device does not create a manuscript sync conflict.
    ((json['tables'] as Map)['app_settings'] as List).removeWhere(
      (row) => (row['key'] as String).startsWith('progress/'),
    );
    return sha256.convert(utf8.encode(canonicalJson(json))).toString();
  }

  ({ProjectSnapshot snapshot, Map<String, String> ids}) copy({String? title}) {
    final rows = tables, ids = <String, String>{};
    for (final name in projectTables) {
      if (name == 'app_settings') continue;
      for (final row in rows[name]!) {
        for (final key in [
          'id',
          'chapter_id',
          'entity_id',
          if (name == 'lore_versions') 'revision_id',
        ]) {
          final id = row[key];
          if (id is String) ids.putIfAbsent(id, () => const Uuid().v4());
        }
      }
    }
    for (final table in projectTables) {
      for (final row in rows[table]!) {
        if (table == 'generation_tasks' && row['kind'] == 'illustration') {
          final input = jsonDecode(row['input_json'] as String) as Map;
          if (input['frozenComic'] is Map &&
              (input['connection'] as Map?)?['protocol'] ==
                  'sillyDraftRunner') {
            final result = jsonDecode(row['result_json'] as String) as Map;
            // Reconnecting a copied task must retrieve the original remote job.
            result['remoteExecutionId'] ??= row['id'];
            row['result_json'] = jsonEncode(result);
          }
        }
        for (final key in row.keys.toList()) {
          final value = row[key];
          if (key == 'key' && table == 'app_settings' && value is String) {
            final split = value.indexOf('/');
            row[key] =
                '${value.substring(0, split + 1)}${ids[value.substring(split + 1)] ?? value.substring(split + 1)}';
          } else if (key.endsWith('_json') && value is String) {
            if (['local_json', 'global_json'].contains(key) ||
                (table == 'library_resources' && key == 'data_json')) {
              continue;
            }
            row[key] = jsonEncode(_remapJson(jsonDecode(value), ids));
          } else if (value is String && (key == 'id' || key.endsWith('_id'))) {
            row[key] = ids[value] ?? value;
          }
        }
      }
    }
    if (title != null) rows['novels']!.single['title'] = title;
    return (
      snapshot: ProjectSnapshot.fromJson({
        'format': 'sillydraft-project',
        'version': 2,
        'schema': 12,
        'tables': rows,
      }),
      ids: Map.unmodifiable(ids),
    );
  }
}

const projectTables = [
  'novels',
  'branches',
  'revisions',
  'branch_chapters',
  'proposals',
  'generation_tasks',
  'branch_variables',
  'variable_revisions',
  'agent_conversations',
  'agent_messages',
  'reading_bookmarks',
  'library_resources',
  'lore_versions',
  'analysis_acceptances',
  'branch_candidate_selections',
  'story_assets',
  'comic_revisions',
  'branch_comics',
  'app_settings',
];

String canonicalJson(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      return {
        for (final k in v.keys.cast<String>().toList()..sort()) k: sort(v[k]),
      };
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  return jsonEncode(sort(value));
}

Object? _remapJson(Object? value, Map<String, String> ids, [String key = '']) {
  if ([
    'local',
    'global',
    'variables',
    'executionId',
    'remoteExecutionId',
  ].contains(key)) {
    return value;
  }
  if (value is List) return value.map((v) => _remapJson(v, ids, key)).toList();
  if (value is Map) {
    if (value.containsKey('adaptationId') && value.containsKey('units')) {
      return remapComicDocument(
        ComicDocument.fromJson(Map<String, dynamic>.from(value)),
        ids,
      ).toJson();
    }
    if (key == 'presetOverrides') {
      return {for (final e in value.entries) ids[e.key] ?? e.key: e.value};
    }
    if (key == 'sourceRevisions' || key == 'comicHeads') {
      return {
        for (final e in value.entries)
          ids[e.key] ?? e.key: ids[e.value] ?? e.value,
      };
    }
    if (key == 'comicDocuments' || key == 'comicSnapshot') {
      return {
        for (final e in value.entries)
          ids[e.key] ?? e.key: _remapJson(e.value, ids),
      };
    }
    if (key == 'agentComicCalls') {
      return {
        for (final e in value.entries)
          e.key: _remapJson(e.value, ids, 'agentComicCall'),
      };
    }
    if (key == 'comicChildren' || key == 'comicCalls') {
      return {
        for (final e in value.entries)
          _remapComicKey(e.key as String, ids): key == 'comicChildren'
              ? ids[e.value] ?? e.value
              : _remapJson(e.value, ids),
      };
    }
    return {
      for (final e in value.entries)
        e.key: key == 'frozenComic' && e.key == 'key'
            ? _remapComicKey(e.value as String, ids)
            : key == 'agentComicCall' && e.key == 'signature'
            ? canonicalJson(_remapJson(jsonDecode(e.value as String), ids))
            : key == 'agentComicCall' && e.key == 'heads'
            ? _remapJson(e.value, ids, 'comicHeads')
            : _remapJson(e.value, ids, e.key as String),
    };
  }
  if (value is String) {
    if (key == 'comicDrawn') return _remapComicKey(value, ids);
    if (key == 'comicCandidates') return ids[value] ?? value;
    if (key == 'image' && value.startsWith('asset:')) {
      return 'asset:${ids[value.substring(6)] ?? value.substring(6)}';
    }
    if (key == 'id' ||
        key.endsWith('Id') ||
        key.endsWith('Ids') ||
        key.endsWith('_id')) {
      return ids[value] ?? value;
    }
  }
  return value;
}

String _remapComicKey(String value, Map<String, String> ids) {
  for (final prefix in ['', 'context-']) {
    if (!value.startsWith(prefix)) continue;
    final key = value.substring(prefix.length);
    for (var i = key.length - 1; i > 0; i--) {
      if (key[i] != '-' && key[i] != '/') continue;
      final id = ids[key.substring(0, i)];
      if (id != null) return '$prefix$id${key.substring(i)}';
    }
  }
  return value;
}

final class ProjectConflict implements Exception {
  const ProjectConflict();
  @override
  String toString() => '作品已在本机或其他设备修改。请保留两个版本后比较。';
}
