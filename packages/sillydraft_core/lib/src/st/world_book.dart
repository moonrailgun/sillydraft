import 'import_types.dart';

final class WorldBook extends JsonSource {
  WorldBook._(super.raw, this.name, this.entries);
  final String name;
  final List<WorldBookEntry> entries;

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
      // `token_budget`, `scan_depth` and `recursive_scanning` stay in [raw]:
      // ST scans every book with its global settings (WorldBookEngine).
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
    required this.outletName,
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
    required this.delayUntilRecursion,
    required this.scanDepth,
    required this.ignoreBudget,
    required this.group,
    required this.groupOverride,
    required this.groupWeight,
    required this.useGroupScoring,
    required this.scans,
    required this.triggers,
    required this.characterFilter,
    required this.sticky,
    required this.cooldown,
    required this.delay,
    required this.automationId,
  });
  final String id, content, comment;

  /// The outlet a position-7 entry fills (ST `outletName`; a card's book
  /// has `extensions.outlet_name`, world-info.js `convertCharacterBook`).
  final String outletName;
  final List<String> keys, secondaryKeys;
  final bool enabled,
      constant,
      selective,
      useProbability,
      excludeRecursion,
      preventRecursion,
      ignoreBudget,
      groupOverride;

  /// Null: the global setting.
  final bool? caseSensitive, wholeWords, useGroupScoring;
  final int selectiveLogic, order, position, depth, role, probability;
  final int? scanDepth;

  /// The recursion level the entry waits for (`true` is 1); 0: none.
  final num delayUntilRecursion, groupWeight;

  /// Inclusion groups, comma separated.
  final String group, automationId;

  /// The `globalScanData` fields the entry also scans, in the order
  /// `WorldInfoBuffer.get` appends them (`personaDescription`, …).
  final List<String> scans;

  /// Generation types the entry is limited to; empty: all.
  final List<String> triggers;

  /// An ST world file's `characterFilter`; a card's book has none.
  final ({bool exclude, List<String> names, List<String> tags})?
  characterFilter;
  final num? sticky, cooldown, delay;

  // ST world-info.js `WorldInfoBuffer.get` L279-327.
  static const _scans = {
    'personaDescription': (
      'matchPersonaDescription',
      'match_persona_description',
    ),
    'characterDescription': (
      'matchCharacterDescription',
      'match_character_description',
    ),
    'characterPersonality': (
      'matchCharacterPersonality',
      'match_character_personality',
    ),
    'characterDepthPrompt': (
      'matchCharacterDepthPrompt',
      'match_character_depth_prompt',
    ),
    'scenario': ('matchScenario', 'match_scenario'),
    'creatorNotes': ('matchCreatorNotes', 'match_creator_notes'),
  };

  factory WorldBookEntry.fromJson(
    Map<String, dynamic> raw, {
    required String fallbackId,
  }) {
    final ext = raw['extensions'] == null
        ? <String, dynamic>{}
        : jsonObject(raw['extensions'], 'extensions');
    // A card's book entry (V2 `keys` / `insertion_order`) is read as ST
    // 1.19.0 (06bde939…) world-info.js `convertCharacterBook` L5617-5674
    // converts it on import: these fields from `extensions`. An ST world
    // file's entry is scanned as stored (`checkWorldInfo` reads its own
    // fields; `extensions` there is a copy that ST does not read).
    final card = raw.containsKey('keys') || raw.containsKey('insertion_order');
    final fields = card ? ext : raw;
    Object? field(String native, String cardName) =>
        card ? ext[cardName] : raw[native];
    bool flag(String native, String cardName) =>
        _truthy(field(native, cardName));
    bool? optional(String native, String cardName) =>
        switch (field(native, cardName)) {
          final bool value => value,
          _ => null,
        };
    num? number(String native, String cardName) =>
        switch (field(native, cardName)) {
          final num value => value,
          _ => null,
        };
    String text(String native, String cardName) =>
        switch (field(native, cardName)) {
          final String value => value,
          _ => '',
        };
    final position = raw['position'];
    final filter = card ? null : raw['characterFilter'];
    List<String> strings(Object? value) =>
        value is List ? [...value.whereType<String>()] : const [];
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
      outletName: text('outletName', 'outlet_name'),
      // `disable: !entry.enabled`; a world file's `disable == true`.
      enabled: card
          ? _truthy(raw['enabled'])
          : raw['enabled'] != false && raw['disable'] != true,
      constant: raw['constant'] == true,
      selective: raw['selective'] == true,
      selectiveLogic: intField(fields, 'selectiveLogic', 0),
      order: intField(
        raw,
        raw.containsKey('insertion_order') ? 'insertion_order' : 'order',
        100,
      ),
      // A card's book: `extensions.position`, else `before_char` before the
      // character and anything else after.
      position: card
          ? intField(ext, 'position', position == 'before_char' ? 0 : 1)
          : position is int
          ? position
          : position == 'after_char'
          ? 1
          : 0,
      depth: intField(fields, 'depth', 4),
      role: intField(fields, 'role', 0),
      caseSensitive: optional('caseSensitive', 'case_sensitive'),
      wholeWords: optional('matchWholeWords', 'match_whole_words'),
      probability: intField(fields, 'probability', 100).clamp(0, 100),
      // A card's entry rolls unless `useProbability` is off.
      useProbability: card
          ? ext['useProbability'] == null || _truthy(ext['useProbability'])
          : _truthy(raw['useProbability']),
      excludeRecursion: flag('excludeRecursion', 'exclude_recursion'),
      preventRecursion: flag('preventRecursion', 'prevent_recursion'),
      delayUntilRecursion: switch (field(
        'delayUntilRecursion',
        'delay_until_recursion',
      )) {
        true => 1,
        final num level when level > 0 => level,
        _ => 0,
      },
      scanDepth: number('scanDepth', 'scan_depth')?.toInt(),
      ignoreBudget: flag('ignoreBudget', 'ignore_budget'),
      group: text('group', 'group'),
      groupOverride: flag('groupOverride', 'group_override'),
      groupWeight: number('groupWeight', 'group_weight') ?? 100,
      useGroupScoring: optional('useGroupScoring', 'use_group_scoring'),
      scans: [
        for (final MapEntry(key: name, value: (native, cardName))
            in _scans.entries)
          if (flag(native, cardName)) name,
      ],
      triggers: strings(field('triggers', 'triggers')),
      characterFilter: filter is Map
          ? (
              exclude: _truthy(filter['isExclude']),
              names: strings(filter['names']),
              tags: strings(filter['tags']),
            )
          : null,
      sticky: number('sticky', 'sticky'),
      cooldown: number('cooldown', 'cooldown'),
      delay: number('delay', 'delay'),
      automationId: text('automationId', 'automation_id'),
    );
  }
}

/// JavaScript truthiness of a JSON value.
bool _truthy(Object? value) =>
    value != null && value != false && value != 0 && value != '';
