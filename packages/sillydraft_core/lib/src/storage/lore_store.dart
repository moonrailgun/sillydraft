part of 'story_repository.dart';

extension LoreOperations on StoryRepository {
  Future<List<LoreEntry>> listLore(
    String branchId, {
    String? throughSceneId,
    LoreKind? kind,
    bool includeDeleted = false,
    String query = '',
  }) async {
    final story = await getStory(branchId);
    final positions = {for (final (i, s) in story.scenes.indexed) s.id: i};
    if (throughSceneId != null && !positions.containsKey(throughSceneId)) {
      throw const StoryNotFound('资料查询位置');
    }
    final cutoff = throughSceneId == null
        ? story.scenes.length - 1
        : positions[throughSceneId]!;
    final selected = <String, Map<String, Object?>>{};
    final ranks = <String, int>{};
    for (final row in await _rows(
      'SELECT * FROM lore_versions WHERE branch_id = ? ORDER BY sequence',
      [branchId],
    )) {
      final anchor = row['at_scene_id'] as String?;
      if (anchor != null && !positions.containsKey(anchor)) continue;
      final position = anchor == null ? -1 : positions[anchor]!;
      if (position > cutoff) continue;
      final id = row['entity_id'] as String;
      if (position >= (ranks[id] ?? -2)) {
        selected[id] = row;
        ranks[id] = position;
      }
    }
    final heads = {
      for (final scene in story.scenes) scene.id: scene.revisionId,
    };
    final result = <LoreEntry>[];
    for (final row in selected.values) {
      final provenance =
          jsonDecode(row['provenance_json'] as String) as Map<String, dynamic>;
      final source = provenance['sceneId'] as String?;
      final stale = source != null && heads[source] != provenance['revisionId'];
      final entry = _lore(row, stale: stale);
      if ((includeDeleted || !entry.deleted) &&
          (kind == null || entry.kind == kind) &&
          '${entry.name} ${entry.content}'.toLowerCase().contains(
            query.toLowerCase(),
          )) {
        result.add(entry);
      }
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<LoreEntry> getLoreEntry({
    required String branchId,
    required String id,
    String? throughSceneId,
    bool includeDeleted = false,
  }) async {
    final entry = (await listLore(
      branchId,
      throughSceneId: throughSceneId,
      includeDeleted: includeDeleted,
    )).where((e) => e.id == id).firstOrNull;
    if (entry == null) throw const StoryNotFound('当前分支的资料条目');
    return entry;
  }

  Future<LoreEntry> getLoreRevision(String revisionId) async => _lore(
    await _one('SELECT * FROM lore_versions WHERE revision_id = ?', [
      revisionId,
    ], '资料版本'),
  );

  Future<LoreEntry> saveLoreEntry({
    required String branchId,
    required LoreKind kind,
    required String name,
    required String content,
    LoreCertainty certainty = LoreCertainty.fact,
    String? id,
    String? expectedRevisionId,
    String? atSceneId,
    Map<String, dynamic> data = const {},
    Map<String, dynamic> provenance = const {'type': 'manual'},
    bool deleted = false,
  }) => _write(() async {
    _validateTitle(name);
    final story = await getStory(branchId);
    final anchor = atSceneId ?? story.scenes.lastOrNull?.id;
    if (anchor != null && !story.scenes.any((s) => s.id == anchor)) {
      throw const StoryNotFound('资料所在场景');
    }
    LoreEntry? previous;
    if (id != null) {
      previous = await getLoreEntry(
        branchId: branchId,
        id: id,
        throughSceneId: anchor,
        includeDeleted: true,
      );
      if (previous.revisionId != expectedRevisionId) throw const LoreConflict();
      if (previous.kind != kind) {
        throw const FormatException('已有资料不能改变类型，请新建条目');
      }
    } else if (expectedRevisionId != null) {
      throw const LoreConflict();
    }
    if (provenance['sceneId'] case final String sourceId) {
      final index = story.scenes.indexWhere((s) => s.id == sourceId),
          position = story.scenes.indexWhere((s) => s.id == anchor);
      if (index < 0 || index > position) {
        throw const FormatException('资料不能早于证据出现的位置');
      }
      final history = await listRevisions(
        branchId: branchId,
        sceneId: sourceId,
      );
      if (!history.any((r) => r.id == provenance['revisionId'])) {
        throw const StoryNotFound('资料依据版本');
      }
    }
    if (!deleted) await _validateLoreData(branchId, kind, data, anchor);
    final entityId = id ?? _id(), revisionId = _id();
    await _execute(
      '''INSERT INTO lore_versions
        (revision_id,entity_id,branch_id,previous_revision_id,kind,name,content,certainty,data_json,provenance_json,at_scene_id,deleted,created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        revisionId,
        entityId,
        branchId,
        previous?.revisionId,
        kind.name,
        name.trim(),
        content,
        certainty.name,
        jsonEncode(redactCredentials(data)),
        jsonEncode(redactCredentials(provenance)),
        anchor,
        deleted ? 1 : 0,
        _now(),
      ],
    );
    await _touchNovel(story.novel.id);
    return getLoreRevision(revisionId);
  });

  Future<void> deleteLoreEntry({
    required String branchId,
    required String id,
    required String expectedRevisionId,
    String? atSceneId,
  }) async {
    final old = await getLoreEntry(
      branchId: branchId,
      id: id,
      throughSceneId: atSceneId,
    );
    await saveLoreEntry(
      branchId: branchId,
      id: id,
      expectedRevisionId: expectedRevisionId,
      kind: old.kind,
      name: old.name,
      content: old.content,
      certainty: old.certainty,
      data: old.data,
      provenance: old.provenance,
      atSceneId: atSceneId,
      deleted: true,
    );
  }

  Future<void> _validateLoreData(
    String branchId,
    LoreKind kind,
    Map<String, dynamic> data,
    String? throughSceneId,
  ) async {
    if (kind == LoreKind.relationship) {
      for (final key in ['fromId', 'toId']) {
        if (data[key] is! String) throw const FormatException('关系需要两个端点');
        final entry = await getLoreEntry(
          branchId: branchId,
          id: data[key] as String,
          throughSceneId: throughSceneId,
        );
        if (entry.kind == LoreKind.relationship || entry.kind == LoreKind.map) {
          throw const FormatException('关系端点应是人物或世界资料');
        }
      }
      if (data['fromId'] == data['toId']) {
        throw const FormatException('关系需要不同的端点');
      }
    }
    if (kind == LoreKind.map) {
      final points = data['points'] as List? ?? [],
          routes = data['routes'] as List? ?? [];
      if (points.length > 2000 || routes.length > 500) {
        throw const FormatException('地图标记或路线过多');
      }
      final ids = <String>{};
      for (final value in points) {
        final point = jsonObject(value, '地图标记');
        final id = point['id'];
        if (id is! String || id.isEmpty || !ids.add(id)) {
          throw const FormatException('地图标记 ID 重复或为空');
        }
        for (final coordinate in ['x', 'y']) {
          final n = point[coordinate];
          if (n is! num || !n.isFinite || n < 0 || n > 1) {
            throw const FormatException('地图坐标必须在 0 到 1 之间');
          }
        }
        if (point['entityId'] case final String entityId) {
          final entry = await getLoreEntry(
            branchId: branchId,
            id: entityId,
            throughSceneId: throughSceneId,
          );
          if (entry.kind != LoreKind.location) {
            throw const FormatException('地图地点只能关联地点条目');
          }
        }
      }
      final routeIds = <String>{};
      for (final value in routes) {
        final route = jsonObject(value, '地图路线');
        final path = route['pointIds'];
        if (route['id'] is! String ||
            !routeIds.add(route['id'] as String) ||
            path is! List ||
            path.length < 2 ||
            path.any((p) => !ids.contains(p))) {
          throw const FormatException('地图路线包含不存在的地点');
        }
      }
    }
  }
}

LoreEntry _lore(Map<String, Object?> r, {bool stale = false}) => LoreEntry(
  id: r['entity_id'] as String,
  revisionId: r['revision_id'] as String,
  branchId: r['branch_id'] as String,
  kind: LoreKind.values.byName(r['kind'] as String),
  name: r['name'] as String,
  content: r['content'] as String,
  certainty: LoreCertainty.values.byName(r['certainty'] as String),
  data: jsonDecode(r['data_json'] as String) as Map<String, dynamic>,
  provenance:
      jsonDecode(r['provenance_json'] as String) as Map<String, dynamic>,
  atSceneId: r['at_scene_id'] as String?,
  previousRevisionId: r['previous_revision_id'] as String?,
  deleted: r['deleted'] == 1,
  sourceStale: stale,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    r['created_at'] as int,
    isUtc: true,
  ),
);
