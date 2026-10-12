import 'dart:math';

import 'import_types.dart';
import 'macro_engine.dart';
import 'regex_pipeline.dart';
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

/// A deterministic scan over already-filtered story messages. Token budgeting
/// uses a conservative estimate until the selected provider has a tokenizer.
final class WorldBookEngine {
  WorldBookResult activate(
    List<ScopedWorldBook> books, {
    required String branchId,
    required int throughPosition,
    required List<String> messages,
    required MacroEngine macros,
    required int seed,
  }) {
    final active = <ActivatedWorldEntry>[];
    final diagnostics = <CompatibilityDiagnostic>[];
    final random = Random(seed);
    for (final scoped in books) {
      if ((scoped.branchId != null && scoped.branchId != branchId) ||
          scoped.availableFromPosition > throughPosition) {
        continue;
      }
      final book = scoped.book;
      final sorted = [...book.entries]
        ..sort((a, b) => b.order.compareTo(a.order));
      final seen = <String>{};
      final recursion = <String>[];
      var budget = 0;
      for (var round = 0; round < 16; round++) {
        var changed = false;
        for (final entry in sorted) {
          if (!entry.enabled ||
              seen.contains(entry.id) ||
              (round > 0 && entry.excludeRecursion)) {
            continue;
          }
          final depth = (entry.scanDepth ?? book.scanDepth).clamp(
            0,
            messages.length,
          );
          final haystack = [
            ...messages.skip(messages.length - depth),
            if (round > 0) ...recursion,
          ].join('\n');
          bool hit(String key) {
            final resolved = macros.render(key);
            if (resolved.isEmpty) return false;
            if (resolved.startsWith('/') && resolved.lastIndexOf('/') > 0) {
              try {
                return parseJavascriptRegex(resolved).regex.hasMatch(haystack);
              } on FormatException {
                diagnostics.add(
                  CompatibilityDiagnostic(
                    'world_book_regex',
                    '世界书正则无效：${entry.id}',
                    severity: DiagnosticSeverity.error,
                  ),
                );
                return false;
              }
            }
            final text = entry.caseSensitive
                ? haystack
                : haystack.toLowerCase();
            final needle = entry.caseSensitive
                ? resolved
                : resolved.toLowerCase();
            if (!entry.wholeWords) return text.contains(needle);
            return RegExp(
              '(^|[^\\p{L}\\p{N}_])${RegExp.escape(needle)}(?=\$|[^\\p{L}\\p{N}_])',
              unicode: true,
            ).hasMatch(text);
          }

          if (!entry.constant && !entry.keys.any(hit)) continue;
          if (!entry.constant &&
              entry.selective &&
              entry.secondaryKeys.isNotEmpty) {
            final matches = entry.secondaryKeys.map(hit).toList();
            final selected = switch (entry.selectiveLogic) {
              0 => matches.any((v) => v),
              1 => !matches.every((v) => v),
              2 => !matches.any((v) => v),
              3 => matches.every((v) => v),
              _ => false,
            };
            if (!selected) continue;
          }
          seen.add(entry.id);
          if (entry.useProbability &&
              random.nextInt(100) >= entry.probability) {
            continue;
          }
          final raw = entry.raw;
          final extensions = raw['extensions'] is Map<String, dynamic>
              ? raw['extensions'] as Map<String, dynamic>
              : <String, dynamic>{};
          final combined = {...raw, ...extensions};
          for (final key in [
            'sticky',
            'cooldown',
            'delay',
            'group',
            'outletName',
            'automationId',
            'delayUntilRecursion',
            'triggers',
            'characterFilter',
          ]) {
            final v = combined[key];
            if (v != null &&
                v != false &&
                v != 0 &&
                v != '' &&
                !(v is List && v.isEmpty) &&
                !(v is Map && v.isEmpty)) {
              diagnostics.add(
                CompatibilityDiagnostic(
                  'world_book_dependency',
                  '条目 ${entry.id} 的 $key 未支持',
                  severity: DiagnosticSeverity.error,
                ),
              );
            }
          }
          if (![0, 1, 4].contains(entry.position)) {
            diagnostics.add(
              CompatibilityDiagnostic(
                'world_book_position',
                '世界书位置 ${entry.position} 未支持',
                severity: DiagnosticSeverity.error,
              ),
            );
            continue;
          }
          final savedLocal = Map.of(macros.local),
              savedGlobal = Map.of(macros.global);
          final content = macros.render(entry.content);
          final cost = estimateTokens(content);
          if (!entry.ignoreBudget && budget + cost > book.tokenBudget) {
            macros.local
              ..clear()
              ..addAll(savedLocal);
            macros.global
              ..clear()
              ..addAll(savedGlobal);
            diagnostics.add(
              CompatibilityDiagnostic(
                'world_book_budget',
                '世界书条目 ${entry.id} 超出本次预算',
              ),
            );
            continue;
          }
          budget += cost;
          active.add(ActivatedWorldEntry(entry, content));
          changed = true;
          if (!entry.preventRecursion) recursion.add(content);
        }
        if (!book.recursiveScanning || !changed) break;
        if (round == 15) {
          diagnostics.add(
            const CompatibilityDiagnostic(
              'world_book_recursion_limit',
              '世界书递归达到 16 轮限制',
            ),
          );
        }
      }
    }
    // ST inserts descending-priority selected entries at the start of each
    // position buffer, leaving lower-order entries earlier in the final text.
    active.sort((a, b) => a.entry.order.compareTo(b.entry.order));
    return WorldBookResult(
      List.unmodifiable(active),
      List.unmodifiable(diagnostics),
    );
  }
}

int estimateTokens(String text) {
  var total = 0.0;
  for (final rune in text.runes) {
    total += rune > 0x2e7f ? 1.5 : 0.34;
  }
  return total.ceil();
}
