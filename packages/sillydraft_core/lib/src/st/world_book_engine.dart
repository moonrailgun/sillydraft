import 'dart:math';

import 'import_types.dart';
import 'macro_engine.dart';
import 'world_book.dart';

final class ScopedWorldBook {
  const ScopedWorldBook(
    this.book, {
    this.branchId,
    this.availableFromPosition = 0,
  });
  final WorldBook book;
  final String? branchId;
  final int availableFromPosition;
}

final class ActivatedWorldEntry {
  const ActivatedWorldEntry(this.entry, this.content);
  final WorldBookEntry entry;
  final String content;
}

final class WorldBookResult {
  const WorldBookResult(this.entries, this.diagnostics);
  final List<ActivatedWorldEntry> entries;
  final List<CompatibilityDiagnostic> diagnostics;
  String get before => entries
      .where((e) => e.entry.position == 0)
      .map((e) => e.content)
      .join('\n');
  String get after => entries
      .where((e) => e.entry.position == 1)
      .map((e) => e.content)
      .join('\n');
}

/// ST 1.19.0 (06bde939…) world-info.js `checkWorldInfo` L4736-4741: one
/// budget for every book's entries, `world_info_budget` percent (ST's default
/// 25) of the prompt size, `Math.round`ed, `|| 1`; `world_info_budget_cap` is
/// 0 (none) by default. A book's own `token_budget` is never read.
int worldInfoBudget(num maxPrompt) {
  final budget = (25 * maxPrompt / 100 + 0.5).floor();
  return budget == 0 ? 1 : budget;
}

// The world info settings of a fresh ST install, which SillyDraft does not
// let a work change: default/content/settings.json `world_info_settings`
// (world-info.js `setWorldInfoSettings` L917-947), the rest at their module
// defaults (L69-82): `world_info_min_activations` and
// `world_info_max_recursion_steps` 0, which leave the scan unbounded,
// `world_info_use_group_scoring` off. `world_info_include_names` (on) is
// PromptCompiler's, the budget [worldInfoBudget]'s.
const _scanDepth = 2;
const _recursive = true;
const _caseSensitive = false;
const _matchWholeWords = true;
const _useGroupScoring = false;

/// constants.js `GENERATION_TYPE_TRIGGERS`; any other type scans as normal
/// (script.js `Generate` L4633).
const _triggers = {
  'normal',
  'continue',
  'impersonate',
  'swipe',
  'regenerate',
  'quiet',
};

enum _Scan { none, initial, recursion }

/// A deterministic scan over already-filtered story messages. Token budgeting
/// uses a conservative estimate until the selected provider has a tokenizer.
final class WorldBookEngine {
  /// ST 1.19.0 (06bde939…) world-info.js `checkWorldInfo` L4709-5282 over
  /// [messages], oldest first, as script.js `Generate` L4624 gives them.
  /// [characterBook] is the card's lore and [books] the rest (ST's global
  /// lore; `world_info_character_strategy` character first). [budget] (see
  /// [worldInfoBudget]) applies to all of them together; null (no request
  /// size) leaves the scan unlimited. [character] is the card's name (ST's
  /// file name for it), null without a card; [scanData] gives ST's
  /// `globalScanData` texts by field name.
  WorldBookResult activate(
    List<ScopedWorldBook> books, {
    WorldBook? characterBook,
    String? character,
    required String branchId,
    required int throughPosition,
    required List<String> messages,
    required MacroEngine macros,
    required int seed,
    int? budget,
    String generationType = 'normal',
    String Function(String field)? scanData,
  }) {
    final diagnostics = <CompatibilityDiagnostic>[];
    final random = Random(seed);
    void drop(WorldBookEntry entry) => diagnostics.add(
      CompatibilityDiagnostic(
        'world_book_budget',
        '世界书条目 ${entry.id} 超出所有世界书共用的预算（$budget token，即提示词上限的 25%），未放入',
      ),
    );
    // getSortedEntries L4590-4644 (`character_first`): the character's
    // lore by order, then the other books' entries together by order; equal
    // orders keep their place.
    final sorted = [
      ..._stableSorted(
        characterBook?.entries ?? const <WorldBookEntry>[],
        _byOrder,
      ),
      ..._stableSorted(<WorldBookEntry>[
        for (final scoped in books)
          if ((scoped.branchId == null || scoped.branchId == branchId) &&
              scoped.availableFromPosition <= throughPosition)
            ...scoped.book.entries,
      ], _byOrder),
    ];
    final decorators = <WorldBookEntry, List<String>>{};
    final content = <WorldBookEntry, String>{};
    for (final entry in sorted) {
      final (found, text) = _decorators(entry.content);
      decorators[entry] = found;
      content[entry] = text;
    }

    // WorldInfoBuffer L250-327: the newest message first (at most
    // MAX_SCAN_DEPTH), trimmed; an entry reads its depth's messages, each
    // after a \x01, then the texts it also scans, then what recursion added.
    final recent = [for (final m in messages.reversed.take(1000)) m.trim()];
    final recursed = <String>[];
    final extra = <String, String>{};
    String haystack(WorldBookEntry entry) {
      final depth = min(entry.scanDepth ?? _scanDepth, 1000);
      if (depth <= 0) return '';
      return [
        '\x01${recent.take(depth).join('\n\x01')}',
        for (final field in entry.scans)
          if ((extra[field] ??= scanData?.call(field) ?? '').isNotEmpty)
            extra[field]!,
        ...recursed,
      ].join('\n\x01');
    }

    // WorldInfoBuffer.matchKeys L337-366.
    bool matches(String haystack, String needle, WorldBookEntry entry) {
      if (_keyRegex(needle) case final regex?) return regex(haystack);
      final sensitive = entry.caseSensitive ?? _caseSensitive;
      final text = sensitive ? haystack : haystack.toLowerCase();
      final key = sensitive ? needle : needle.toLowerCase();
      if (!(entry.wholeWords ?? _matchWholeWords) ||
          key.split(RegExp(r'\s+')).length > 1) {
        return text.contains(key);
      }
      // `\W` without the `u` flag: anything but ASCII letters, digits, `_`.
      return RegExp('(?:^|\\W)(${RegExp.escape(key)})(?:\$|\\W)')
          .hasMatch(text);
    }

    // WorldInfoBuffer.getScore L428-473: the keys as written.
    int score(WorldBookEntry entry) {
      final text = haystack(entry);
      int count(List<String> keys) =>
          keys.where((key) => matches(text, key, entry)).length;
      if (entry.keys.isEmpty) return 0;
      final primary = count(entry.keys);
      if (entry.secondaryKeys.isEmpty) return primary;
      final secondary = count(entry.secondaryKeys);
      return switch (entry.selectiveLogic) {
        0 => primary + secondary,
        3 when secondary == entry.secondaryKeys.length => primary + secondary,
        _ => primary,
      };
    }

    // L4815-4843: names are checked against the character's file name;
    // tags.js `getTagKeyForEntity` L709-712 gives a character no tags.
    bool filteredOut(WorldBookEntry entry) {
      final filter = entry.characterFilter;
      if (filter == null) return false;
      return (filter.names.isNotEmpty &&
              filter.names.contains(character) == filter.exclude) ||
          (filter.tags.isNotEmpty && character != null && !filter.exclude);
    }

    final trigger = _triggers.contains(generationType)
        ? generationType
        : 'normal';
    final activated = <WorldBookEntry>{};
    final failed = <WorldBookEntry>{};
    final dropped = <WorldBookEntry>{};
    var activatedText = '';
    var overflowed = false;
    // L4754-4762: the recursion levels entries wait for, the first open.
    final levels = {
      for (final entry in sorted)
        if (entry.delayUntilRecursion > 0) entry.delayUntilRecursion,
    }.toList()..sort();
    var level = levels.isEmpty ? 0 : levels.removeAt(0);
    var state = _Scan.initial;
    while (state != _Scan.none) {
      // L4785-4989, in scan order. No entry is sticky, on cooldown or
      // activated from outside: SillyDraft keeps no timed effects between
      // requests (ST's state in a new chat) and has no extensions.
      final found = <WorldBookEntry>[];
      for (final entry in sorted) {
        if (failed.contains(entry) ||
            activated.contains(entry) ||
            !entry.enabled ||
            (entry.triggers.isNotEmpty && !entry.triggers.contains(trigger)) ||
            filteredOut(entry)) {
          continue;
        }
        // WorldInfoTimedEffects `#checkDelayEffect` L666-677.
        final delay = entry.delay;
        if (delay != null && delay != 0 && messages.length < delay) continue;
        if (entry.delayUntilRecursion > 0 &&
            (state != _Scan.recursion || entry.delayUntilRecursion > level)) {
          continue;
        }
        if (state == _Scan.recursion && _recursive && entry.excludeRecursion) {
          continue;
        }
        if (decorators[entry]!.contains('@@activate')) {
          found.add(entry);
          continue;
        }
        if (decorators[entry]!.contains('@@dont_activate')) continue;
        if (entry.constant) {
          found.add(entry);
          continue;
        }
        if (entry.keys.isEmpty) continue;
        final text = haystack(entry);
        bool hit(String key) {
          final resolved = macros.render(key);
          return resolved.isNotEmpty && matches(text, resolved.trim(), entry);
        }

        if (!entry.keys.any(hit)) continue;
        if (!entry.selective ||
            entry.secondaryKeys.isEmpty ||
            _secondary(entry, hit)) {
          found.add(entry);
        }
      }
      final spent = estimateTokens(activatedText);
      _inclusionGroups(found, activated, score, random);
      var newContent = '';
      for (final entry in found) {
        // L5017-5026: after an overflow, only entries that ignore the budget.
        if (overflowed && !entry.ignoreBudget) {
          if (dropped.add(entry)) drop(entry);
          continue;
        }
        // L5028-5050.
        if (entry.useProbability &&
            entry.probability != 100 &&
            random.nextDouble() * 100 > entry.probability) {
          failed.add(entry);
          continue;
        }
        // L5056-5077: the entry's macros run and its text counts first; the
        // one that reaches the budget is left out.
        final text = content[entry] = macros.render(content[entry]!);
        newContent += '$text\n';
        if (budget != null &&
            !entry.ignoreBudget &&
            spent + estimateTokens(newContent) >= budget) {
          overflowed = true;
          if (dropped.add(entry)) drop(entry);
          continue;
        }
        activated.add(entry);
        // 7: an outlet, read by `{{outlet::name}}` (PromptCompiler).
        if (![0, 1, 4, 7].contains(entry.position)) {
          diagnostics.add(
            CompatibilityDiagnostic(
              'world_book_position',
              '世界书位置 ${entry.position} 未支持',
              severity: DiagnosticSeverity.error,
            ),
          );
        }
        for (final (name, value) in [
          ('sticky', entry.sticky),
          ('cooldown', entry.cooldown),
        ]) {
          if (value != null && value != 0) {
            diagnostics.add(
              CompatibilityDiagnostic(
                'world_book_timed_effect',
                '世界书条目 ${entry.id} 的 $name 未生效：SillyDraft 不在两次请求之间保留计时状态',
              ),
            );
          }
        }
        if (entry.automationId.isNotEmpty) {
          diagnostics.add(
            CompatibilityDiagnostic(
              'world_book_automation',
              '世界书条目 ${entry.id} 的 automationId 未生效：SillyDraft 没有快速回复可以触发',
            ),
          );
        }
      }
      // L5079-5147: entries that failed no roll (overflowed ones too) feed
      // recursion unless they prevent it; it stops at an overflow, but a
      // waiting recursion level still opens.
      final recursing = [
        for (final entry in found)
          if (!failed.contains(entry) && !entry.preventRecursion) entry,
      ];
      var next = _recursive && !overflowed && recursing.isNotEmpty
          ? _Scan.recursion
          : _Scan.none;
      if (next == _Scan.none && levels.isNotEmpty) {
        next = _Scan.recursion;
        level = levels.removeAt(0);
      }
      if (next != _Scan.none) {
        final text = recursing.map((e) => content[e]).join('\n');
        if (text.isNotEmpty) {
          recursed.add(text);
          activatedText = '$text\n$activatedText';
        }
      }
      state = next;
    }
    // world-info.js L5202-5217: the activated entries, highest order first
    // (a stable sort), each put at the start of its position's list; so
    // lowest order first, and of equal orders the last activated first.
    return WorldBookResult(
      List.unmodifiable([
        for (final entry in _stableSorted(activated, _byOrder).reversed)
          ActivatedWorldEntry(entry, content[entry]!),
      ]),
      List.unmodifiable(diagnostics),
    );
  }
}

/// world-info.js `sortFn`.
int _byOrder(WorldBookEntry a, WorldBookEntry b) => b.order.compareTo(a.order);

/// L4936-4984: the secondary keys under the entry's logic (AND ANY, NOT
/// ALL, NOT ANY, AND ALL), checked until the answer is known.
bool _secondary(WorldBookEntry entry, bool Function(String key) hit) {
  var any = false, all = true;
  for (final key in entry.secondaryKeys) {
    final matched = hit(key);
    any |= matched;
    all &= matched;
    if (entry.selectiveLogic == 0 && matched) return true;
    if (entry.selectiveLogic == 1 && !matched) return true;
  }
  return (entry.selectiveLogic == 2 && !any) ||
      (entry.selectiveLogic == 3 && all);
}

/// world-info.js `filterByInclusionGroups` L5388-5475 with
/// `filterGroupsByScoring` L5292-5335 (`filterGroupsByTimedEffects` has
/// nothing to do without timed effects): of a group among [found], one
/// entry stays, none once the group is in the prompt.
void _inclusionGroups(
  List<WorldBookEntry> found,
  Set<WorldBookEntry> activated,
  int Function(WorldBookEntry entry) score,
  Random random,
) {
  final groups = <String, List<WorldBookEntry>>{};
  for (final entry in found) {
    for (final name in entry.group.split(RegExp(r',\s*'))) {
      if (name.isNotEmpty) (groups[name] ??= []).add(entry);
    }
  }
  // `splice(indexOf(entry), 1)`: removing an entry already gone takes the
  // last one instead.
  void remove(WorldBookEntry entry) {
    if (found.isEmpty) return;
    final i = found.indexOf(entry);
    found.removeAt(i < 0 ? found.length - 1 : i);
  }

  for (final group in groups.values) {
    if (!_useGroupScoring && !group.any((e) => e.useGroupScoring == true)) {
      continue;
    }
    final scores = [for (final entry in group) score(entry)];
    final best = scores.reduce(max);
    for (var i = 0; i < group.length; i++) {
      if (!(group[i].useGroupScoring ?? _useGroupScoring)) continue;
      if (scores[i] < best) {
        remove(group[i]);
        group.removeAt(i);
        scores.removeAt(i);
        i--;
      }
    }
  }
  for (final MapEntry(key: name, value: group) in groups.entries) {
    if (activated.any((e) => e.group == name)) {
      group.forEach(remove);
      continue;
    }
    if (group.length <= 1) continue;
    var winner = _stableSorted(
      group.where((e) => e.groupOverride),
      _byOrder,
    ).firstOrNull;
    if (winner == null) {
      final roll =
          random.nextDouble() *
          group.fold<num>(0, (sum, e) => sum + e.groupWeight);
      num weight = 0;
      for (final entry in group) {
        weight += entry.groupWeight;
        if (roll <= weight) {
          winner = entry;
          break;
        }
      }
      if (winner == null) continue;
    }
    for (final entry in group) {
      if (entry != winner) remove(entry);
    }
  }
}

/// world-info.js `parseRegexFromString` L2901-2926: a `/pattern/flags` key,
/// else null (the key is text).
bool Function(String text)? _keyRegex(String key) {
  final match = RegExp(r'^/([\w\W]+?)/([gimsuy]*)$').firstMatch(key);
  if (match == null || RegExp(r'(^|[^\\])/').hasMatch(match[1]!)) return null;
  final flags = match[2]!;
  if (flags.split('').toSet().length < flags.length) return null;
  try {
    final regex = RegExp(
      match[1]!.replaceFirst(r'\/', '/'),
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u'),
    );
    // `y`: from the start only.
    return flags.contains('y')
        ? (text) => regex.matchAsPrefix(text) != null
        : regex.hasMatch;
  } on FormatException {
    return null;
  }
}

/// world-info.js `parseDecorators` L4652-4698: the known `@@` lines that
/// start the content, and the content after them.
(List<String>, String) _decorators(String content) {
  if (!content.startsWith('@@')) return (const [], content);
  final lines = content.split('\n');
  final found = <String>[];
  var fallback = false;
  for (final (i, line) in lines.indexed) {
    if (!line.startsWith('@@')) return (found, lines.skip(i).join('\n'));
    if (line.startsWith('@@@') && !fallback) continue;
    final name = line.startsWith('@@@') ? line.substring(1) : line;
    if (name.startsWith('@@activate') || name.startsWith('@@dont_activate')) {
      found.add(name);
      fallback = false;
    } else {
      fallback = true;
    }
  }
  return (found, content);
}

/// [items] sorted by [compare], equal ones in their order (as JS sorts;
/// Dart's [List.sort] is not stable).
List<T> _stableSorted<T>(Iterable<T> items, int Function(T, T) compare) {
  final indexed = [...items.indexed]
    ..sort((a, b) {
      final c = compare(a.$2, b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
  return [for (final (_, item) in indexed) item];
}

int estimateTokens(String text) {
  var total = 0.0;
  for (final rune in text.runes) {
    total += rune > 0x2e7f ? 1.5 : 0.34;
  }
  return total.ceil();
}
