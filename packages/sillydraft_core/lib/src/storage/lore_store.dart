part of 'story_repository.dart';

extension LoreOperations on StoryRepository {
  /// Each entity's latest version through [throughChapterId], or before it
  /// when [includeCurrentChapter] is false. Versions the
  /// sidecar wrote for [ignoreSidecarOf], and with [skipStaleVersions] those
  /// whose source chapter changed since, are passed over for the version
  /// before them, as writing that chapter or after it needs. [staleLatest]
  /// receives each listed entity's latest version whose source changed,
  /// passed over or not, from the same scan.
  Future<List<LoreEntry>> listLore(
    String branchId, {
    String? throughChapterId,
    bool includeCurrentChapter = true,
    LoreKind? kind,
    bool includeDeleted = false,
    String query = '',
    String? ignoreSidecarOf,
    bool skipStaleVersions = false,
    List<LoreEntry>? staleLatest,
  }) async {
    final story = await getStory(branchId);
    final positions = {for (final (i, s) in story.chapters.indexed) s.id: i};
    if (throughChapterId != null && !positions.containsKey(throughChapterId)) {
      throw const StoryNotFound('资料查询位置');
    }
    final cutoff = throughChapterId == null
        ? story.chapters.length - 1
        : positions[throughChapterId]! - (includeCurrentChapter ? 0 : 1);
    final heads = {
      for (final chapter in story.chapters) chapter.id: chapter.revisionId,
    };
    Map<String, dynamic> provenance(Map<String, Object?> row) =>
        jsonDecode(row['provenance_json'] as String) as Map<String, dynamic>;
    bool stale(Map<String, dynamic> provenance) {
      final source = provenance['chapterId'] as String?;
      return source != null && heads[source] != provenance['revisionId'];
    }

    final selected = <String, Map<String, Object?>>{};
    final ranks = <String, int>{};
    final latest = <String, (int, Map<String, Object?>)>{};
    for (final row in await _rows(
      'SELECT * FROM lore_versions WHERE branch_id = ? ORDER BY sequence',
      [branchId],
    )) {
      final anchor = row['at_chapter_id'] as String?;
      if (anchor != null && !positions.containsKey(anchor)) continue;
      final position = anchor == null ? -1 : positions[anchor]!;
      if (position > cutoff) continue;
      final id = row['entity_id'] as String;
      if (position >= (latest[id]?.$1 ?? -2)) latest[id] = (position, row);
      if (skipStaleVersions || ignoreSidecarOf != null) {
        final source = provenance(row);
        if ((skipStaleVersions && stale(source)) ||
            (ignoreSidecarOf != null && sidecarOwns(source, ignoreSidecarOf))) {
          continue;
        }
      }
      if (position >= (ranks[id] ?? -2)) {
        selected[id] = row;
        ranks[id] = position;
      }
    }
    bool listed(LoreEntry entry) =>
        (includeDeleted || !entry.deleted) &&
        (kind == null || entry.kind == kind) &&
        '${entry.name} ${entry.content}'.toLowerCase().contains(
          query.toLowerCase(),
        );
    if (staleLatest != null) {
      for (final (_, row) in latest.values) {
        if (!stale(provenance(row))) continue;
        final entry = _lore(row, stale: true);
        if (listed(entry)) staleLatest.add(entry);
      }
    }
    final result = <LoreEntry>[];
    for (final row in selected.values) {
      final entry = _lore(row, stale: stale(provenance(row)));
      if (listed(entry)) result.add(entry);
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<LoreEntry> getLoreEntry({
    required String branchId,
    required String id,
    String? throughChapterId,
    bool includeDeleted = false,
  }) async {
    final entry = (await listLore(
      branchId,
      throughChapterId: throughChapterId,
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
    String? atChapterId,
    Map<String, dynamic> data = const {},
    Map<String, dynamic> provenance = const {'type': 'manual'},
    bool deleted = false,
  }) => _write(() async {
    _validateTitle(name);
    final story = await getStory(branchId);
    final anchor = atChapterId ?? story.chapters.lastOrNull?.id;
    if (anchor != null && !story.chapters.any((s) => s.id == anchor)) {
      throw const StoryNotFound('资料所在章节');
    }
    LoreEntry? previous;
    if (id != null) {
      previous = await getLoreEntry(
        branchId: branchId,
        id: id,
        throughChapterId: anchor,
        includeDeleted: true,
      );
      if (previous.revisionId != expectedRevisionId) throw const LoreConflict();
      if (previous.kind != kind) {
        throw const FormatException('已有资料不能改变类型，请新建条目');
      }
    } else if (expectedRevisionId != null) {
      throw const LoreConflict();
    }
    if (provenance['chapterId'] case final String sourceId) {
      final index = story.chapters.indexWhere((s) => s.id == sourceId),
          position = story.chapters.indexWhere((s) => s.id == anchor);
      if (index < 0 || index > position) {
        throw const FormatException('资料不能早于证据出现的位置');
      }
      final history = await listRevisions(
        branchId: branchId,
        chapterId: sourceId,
      );
      if (!history.any((r) => r.id == provenance['revisionId'])) {
        throw const StoryNotFound('资料依据版本');
      }
    }
    if (!deleted) await _validateLoreData(branchId, kind, data, anchor);
    final entityId = id ?? _id(), revisionId = _id();
    await _execute(
      '''INSERT INTO lore_versions
        (revision_id,entity_id,branch_id,previous_revision_id,kind,name,content,certainty,data_json,provenance_json,at_chapter_id,deleted,created_at)
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
    String? atChapterId,
  }) async {
    final old = await getLoreEntry(
      branchId: branchId,
      id: id,
      throughChapterId: atChapterId,
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
      atChapterId: atChapterId,
      deleted: true,
    );
  }

  Future<void> _validateLoreData(
    String branchId,
    LoreKind kind,
    Map<String, dynamic> data,
    String? throughChapterId,
  ) async {
    if (data['images'] case final Object images) {
      if (kind != LoreKind.character ||
          images is! List ||
          images.length > maxCharacterImages ||
          images.any((id) => id is! String)) {
        throw const FormatException('只有人物可以有形象图，最多 8 张');
      }
      final novel = (await getBranch(branchId)).novelId;
      for (final id in images.cast<String>()) {
        if ((await getAsset(id)).novelId != novel) {
          throw const StoryNotFound('本作品的人物形象图');
        }
      }
    }
    if (kind == LoreKind.relationship) {
      for (final key in ['fromId', 'toId']) {
        if (data[key] is! String) throw const FormatException('关系需要两个端点');
        final entry = await getLoreEntry(
          branchId: branchId,
          id: data[key] as String,
          throughChapterId: throughChapterId,
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
      if (data['backgroundAssetId'] case final String assetId) {
        final asset = await getAsset(assetId),
            branch = await getBranch(branchId);
        if (asset.novelId != branch.novelId) {
          throw const StoryNotFound('本作品的地图底图');
        }
      }
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
            throughChapterId: throughChapterId,
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
  atChapterId: r['at_chapter_id'] as String?,
  previousRevisionId: r['previous_revision_id'] as String?,
  deleted: r['deleted'] == 1,
  sourceStale: stale,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    r['created_at'] as int,
    isUtc: true,
  ),
);
