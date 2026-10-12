import 'import_types.dart';

final class WorldBook extends JsonSource {
  WorldBook._(
    super.raw,
    this.name,
    this.entries,
    this.scanDepth,
    this.tokenBudget,
    this.recursiveScanning,
  );
  final String name;
  final List<WorldBookEntry> entries;
  final int scanDepth;
  final int tokenBudget;
  final bool recursiveScanning;

  factory WorldBook.fromJson(Map<String, dynamic> raw) {
    final source = raw['entries'];
    final List<Object?> entries;
    if (source is List) {
      entries = source;
    } else if (source is Map<String, dynamic>) {
      entries = source.values.toList();
    } else {
      throw const FormatException('世界书缺少 entries');
    }
    if (entries.length > 10000) throw const FormatException('世界书条目过多');
    return WorldBook._(
      raw,
      stringField(raw, 'name'),
      List.unmodifiable(
        entries.indexed.map(
          (e) => WorldBookEntry.fromJson(
            jsonObject(e.$2, 'entries[${e.$1}]'),
            fallbackId: '${e.$1}',
          ),
        ),
      ),
      intField(raw, 'scan_depth', 2),
      intField(raw, 'token_budget', 2048),
      raw['recursive_scanning'] == true,
    );
  }
}

final class WorldBookEntry extends JsonSource {
  WorldBookEntry._(
    super.raw, {
    required this.id,
    required this.keys,
    required this.secondaryKeys,
    required this.content,
    required this.comment,
    required this.enabled,
    required this.constant,
    required this.selective,
    required this.selectiveLogic,
    required this.order,
    required this.position,
    required this.depth,
    required this.role,
    required this.caseSensitive,
    required this.wholeWords,
    required this.probability,
    required this.useProbability,
    required this.excludeRecursion,
    required this.preventRecursion,
    required this.scanDepth,
    required this.ignoreBudget,
  });
  final String id, content, comment;
  final List<String> keys, secondaryKeys;
  final bool enabled,
      constant,
      selective,
      caseSensitive,
      wholeWords,
      useProbability,
      excludeRecursion,
      preventRecursion,
      ignoreBudget;
  final int selectiveLogic, order, position, depth, role, probability;
  final int? scanDepth;

  factory WorldBookEntry.fromJson(
    Map<String, dynamic> raw, {
    required String fallbackId,
  }) {
    final ext = raw['extensions'] == null
        ? <String, dynamic>{}
        : jsonObject(raw['extensions'], 'extensions');
    final merged = <String, dynamic>{...raw, ...ext};
    final position = raw['position'];
    return WorldBookEntry._(
      raw,
      id: '${raw['id'] ?? raw['uid'] ?? fallbackId}',
      keys: stringList(raw['keys'] ?? raw['key'], 'keys'),
      secondaryKeys: stringList(
        raw['secondary_keys'] ?? raw['keysecondary'],
        'secondary_keys',
      ),
      content: stringField(raw, 'content'),
      comment: stringField(raw, 'comment', fallback: stringField(raw, 'name')),
      enabled: raw['enabled'] != false && raw['disable'] != true,
      constant: raw['constant'] == true,
      selective: raw['selective'] == true,
      selectiveLogic: intField(merged, 'selectiveLogic', 0),
      order: intField(
        raw,
        raw.containsKey('insertion_order') ? 'insertion_order' : 'order',
        100,
      ),
      position: position is int
          ? position
          : position == 'after_char'
          ? 1
          : intField(ext, 'position', 0),
      depth: intField(merged, 'depth', 4),
      role: intField(merged, 'role', 0),
      caseSensitive:
          (merged['case_sensitive'] ?? merged['caseSensitive']) == true,
      wholeWords: merged['matchWholeWords'] == true,
      probability: intField(merged, 'probability', 100).clamp(0, 100),
      useProbability: merged['useProbability'] == true,
      excludeRecursion: merged['excludeRecursion'] == true,
      preventRecursion: merged['preventRecursion'] == true,
      scanDepth: merged['scanDepth'] == null
          ? null
          : intField(merged, 'scanDepth', 2),
      ignoreBudget: merged['ignoreBudget'] == true,
    );
  }
}
