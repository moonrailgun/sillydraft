import 'asset.dart';
import 'lore.dart';
import 'story.dart';

/// Branch-local versions and the frozen inputs that connect their images.
final class IllustrationGraph {
  IllustrationGraph({
    required this.branchId,
    required List<StoryAsset> assets,
    required this.lore,
    required this.chapters,
  }) : assets = {for (final a in assets) a.id: a} {
    void include(String id) {
      if (!_visible.add(id)) return;
      final asset = this.assets[id];
      if (asset == null) return;
      for (final raw in asset.metadata['references'] as List? ?? []) {
        if (raw is Map && raw['id'] is String) include(raw['id'] as String);
      }
      for (final ref in visualSnapshots(asset)) {
        if (ref['assetId'] case final String id) include(id);
      }
      if (asset.metadata['replacesAssetId'] case final String old) include(old);
    }

    // Inherited images bring their input history, never later edits in a sibling branch.
    for (final a in assets.where((a) => a.branchId == branchId)) {
      include(a.id);
    }
    for (final chapter in chapters) {
      for (final op in chapter.content.delta) {
        final insert = op['insert'];
        if (insert is Map && insert['image'] is String) {
          final image = insert['image'] as String;
          if (image.startsWith('asset:')) include(image.substring(6));
        }
      }
    }
    for (final entry in lore) {
      for (final id in entry.data['images'] as List? ?? []) {
        if (id is String) include(id);
      }
    }
    for (final a in assets) {
      if (_visible.contains(a.id)) {
        if (a.metadata['replacesAssetId'] case final String old) {
          _next.putIfAbsent(old, () => a.id);
        }
      }
    }
  }
  final String branchId;
  final Map<String, StoryAsset> assets;
  final List<LoreEntry> lore;
  final List<Chapter> chapters;
  final _next = <String, String>{};
  final _visible = <String>{};

  StoryAsset current(String id) {
    final seen = <String>{};
    while (_next.containsKey(id) && seen.add(id)) {
      id = _next[id]!;
    }
    return assets[id] ?? (throw const FormatException('关联图片不存在'));
  }

  static List<Map<String, dynamic>> visualSnapshots(StoryAsset asset) => [
    for (final value in asset.metadata['visualReferences'] as List? ?? [])
      if (value is Map) value.cast<String, dynamic>(),
  ];

  List<Map<String, dynamic>> visualReferences(StoryAsset asset) => [
    for (final saved in visualSnapshots(asset)) _resolveVisual(saved),
  ];

  Map<String, dynamic> _resolveVisual(Map<String, dynamic> saved) {
    final entry = lore.where((e) => e.id == saved['loreId']).firstOrNull;
    var id = saved['assetId'] as String?;
    var prompt = saved['prompt'];
    if (entry != null) {
      final images = entry.data['images'] as List? ?? [];
      // Keep an explicitly chosen alternate until that image is removed.
      final wasDefault =
          saved['defaultAssetId'] == null || saved['defaultAssetId'] == id;
      if (id != null && assets.containsKey(id)) id = current(id).id;
      if (wasDefault || !images.contains(id)) {
        id = images.firstOrNull as String?;
      }
      prompt = entry.data['referencePrompt'] ?? prompt;
    }
    if (id != null && assets.containsKey(id)) {
      final latest = current(id);
      id = latest.id;
      if (entry == null) prompt = latest.metadata['referencePrompt'] ?? prompt;
    }
    return {
      ...saved,
      'assetId': id,
      'prompt': prompt,
      if (entry != null)
        'defaultAssetId': (entry.data['images'] as List?)?.firstOrNull,
    };
  }

  List<String> referenceIds(StoryAsset asset) {
    final visual = visualReferences(asset);
    final saved = visualSnapshots(asset);
    final resolved = <String, String?>{
      for (var i = 0; i < saved.length; i++)
        if (saved[i]['assetId'] is String)
          saved[i]['assetId'] as String: visual[i]['assetId'] as String?,
    };
    return {
      for (final raw in asset.metadata['references'] as List? ?? [])
        if (raw is Map && raw['id'] is String)
          if (resolved.containsKey(raw['id']))
            ?resolved[raw['id']]
          else
            assets.containsKey(raw['id'])
                ? current(raw['id'] as String).id
                : raw['id'] as String,
      for (final ref in visual) ?ref['assetId'] as String?,
    }.toList();
  }

  /// Keep former inputs connected when a lore reference is removed or switched.
  List<String> linkedReferenceIds(StoryAsset asset) => {
    ...referenceIds(asset),
    for (final ref in visualSnapshots(asset))
      if (ref['assetId'] case final String id)
        assets.containsKey(id) ? current(id).id : id,
  }.toList();

  Map<String, dynamic> referenceState(StoryAsset asset) => {
    'images': [
      for (final id in referenceIds(asset))
        {'id': id, 'hash': assets[id]?.hash},
    ],
    'visual': visualReferences(asset),
    'missingLore': [
      for (final r in visualSnapshots(asset))
        if (r['loreId'] != null && !lore.any((e) => e.id == r['loreId']))
          r['loreId'],
    ],
  };

  /// Current ids of the inputs [asset] was drawn from an older state of: the
  /// links a diagram marks as changed.
  Set<String> changedInputs(StoryAsset asset) {
    String latest(String id) => assets.containsKey(id) ? current(id).id : id;
    final saved = visualSnapshots(asset), visual = visualReferences(asset);
    return {
      for (var i = 0; i < saved.length; i++)
        if (saved[i]['assetId'] != visual[i]['assetId'] ||
            saved[i]['prompt'] != visual[i]['prompt']) ...[
          ?visual[i]['assetId'] as String?,
          if (saved[i]['assetId'] case final String id) latest(id),
        ],
      for (final raw in asset.metadata['references'] as List? ?? [])
        if (raw case {'id': final String id})
          if (latest(id) != id || assets[id]?.hash != raw['hash']) latest(id),
    };
  }

  bool isStale(StoryAsset asset, [Set<String>? visited]) {
    final seen = visited ?? <String>{};
    if (!seen.add(asset.id)) return false;
    final saved = visualSnapshots(asset), visual = visualReferences(asset);
    for (var i = 0; i < saved.length; i++) {
      if (saved[i]['assetId'] != visual[i]['assetId'] ||
          saved[i]['prompt'] != visual[i]['prompt']) {
        return true;
      }
      if (saved[i]['loreId'] != null &&
          !lore.any((e) => e.id == saved[i]['loreId'])) {
        return true;
      }
    }
    for (final raw in asset.metadata['references'] as List? ?? []) {
      if (raw is! Map || raw['id'] is! String) continue;
      final id = raw['id'] as String;
      if (!assets.containsKey(id) ||
          current(id).id != id ||
          assets[id]!.hash != raw['hash']) {
        return true;
      }
    }
    return referenceIds(asset)
        .any((id) => assets.containsKey(id) && isStale(assets[id]!, seen));
  }

  List<Chapter> placements(String id) => chapters
      .where(
        (c) => c.content.delta.any(
          (op) =>
              op['insert'] is Map &&
              (op['insert'] as Map)['image'] == 'asset:$id',
        ),
      )
      .toList();

  List<StoryAsset> children(String id) {
    final resolved = current(id).id;
    return assets.values
        .where(
          (a) =>
              current(a.id).id == a.id &&
              _visible.contains(a.id) &&
              a.id != resolved &&
              linkedReferenceIds(a).contains(resolved),
        )
        .toList();
  }

  /// Topological order avoids regenerating a shared child before its parents.
  List<StoryAsset> descendants(String id) {
    final found = <String, StoryAsset>{};
    void collect(String parent) {
      for (final child in children(parent)) {
        if (child.id == current(id).id || found.containsKey(child.id)) continue;
        found[child.id] = child;
        collect(child.id);
      }
    }

    collect(id);
    final result = <StoryAsset>[], active = <String>{}, done = <String>{};
    void visit(StoryAsset asset) {
      if (done.contains(asset.id)) return;
      if (!active.add(asset.id)) {
        throw const FormatException('图片关联存在循环，无法批量重新生成');
      }
      for (final parent in linkedReferenceIds(asset)) {
        if (found.containsKey(parent)) visit(found[parent]!);
      }
      active.remove(asset.id);
      done.add(asset.id);
      result.add(asset);
    }

    for (final asset in found.values) {
      visit(asset);
    }
    return result;
  }
}
