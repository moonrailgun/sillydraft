import '../model/lore.dart';

/// Selects only from revisions already eligible for this branch and chapter.
final class LoreContextSelection {
  LoreContextSelection(
    List<LoreEntry> entries, {
    required this.query,
    required this.recentText,
  }) {
    final briefTerms = _terms(query), recentTerms = _terms(recentText);
    final byId = {for (final entry in entries) entry.id: entry};
    final ranked = <LoreContextCandidate>[];
    for (final entry in entries) {
      final references = _referenceIds(entry).where(byId.containsKey).toSet();
      final referencedNames = references.map((id) => byId[id]!.name).toList();
      final nameTerms = _terms(entry.name);
      final terms = _terms(
        [
          entry.name,
          entry.content,
          ...referencedNames,
          for (final key in [
            'appearance',
            'goal',
            'outfit',
            'state',
            'storyTime',
            'referencePrompt',
          ])
            if (entry.data[key] is String) entry.data[key],
        ].join('\n'),
      );
      int matches(Set<String> queryTerms, String text) =>
          terms.intersection(queryTerms).length +
          3 * nameTerms.intersection(queryTerms).length +
          referencedNames.where((name) => _mentions(text, name)).length;
      final named = _mentions(query, entry.name);
      final briefScore = matches(briefTerms, query);
      final recentScore =
          matches(recentTerms, recentText) +
          (_mentions(recentText, entry.name) ? 20 : 0);
      final pinned = entry.data['contextRequired'] == true;
      final openHook =
          entry.kind == LoreKind.foreshadow &&
          !{'resolved', 'abandoned'}.contains(entry.data['status']);
      ranked.add(
        LoreContextCandidate(
          entry,
          references: references,
          score: briefScore * 4 + recentScore + (named ? 100 : 0),
          required: pinned || named,
          reason: pinned
              ? 'pinned'
              : named
              ? 'named'
              : openHook
              ? 'unresolved'
              : briefScore > 0
              ? 'brief'
              : recentScore > 0
              ? 'recent'
              : 'fallback',
        ),
      );
    }
    final hasMatch = ranked.any((c) => c.score > 0);
    final initial = ranked
        .where(
          (c) =>
              c.required ||
              c.reason == 'unresolved' ||
              c.score > 0 ||
              !hasMatch,
        )
        .toList();
    final initialIds = initial.map((c) => c.entry.id).toSet();
    final referencedIds = {for (final c in initial) ...c.references};
    final requiredIds = {
      for (final c in initial)
        if (c.required) ...c.references,
    };
    // Storage only allows relationships/maps to reference non-container entries.
    for (final candidate in ranked) {
      final id = candidate.entry.id;
      if (initialIds.contains(id) || referencedIds.contains(id)) {
        final requiredReference =
            !candidate.required && requiredIds.contains(id);
        selected.add(
          requiredReference || !initialIds.contains(id)
              ? LoreContextCandidate(
                  candidate.entry,
                  references: candidate.references,
                  score: candidate.score,
                  required: requiredReference,
                  reason: 'reference',
                )
              : candidate,
        );
      } else {
        omitted.add({...candidate.toJson(), 'reason': 'unrelated'});
      }
    }
    selected.sort((a, b) {
      final requiredOrder = (b.required ? 1 : 0).compareTo(a.required ? 1 : 0);
      if (requiredOrder != 0) return requiredOrder;
      final scoreOrder = b.score.compareTo(a.score);
      if (scoreOrder != 0) return scoreOrder;
      final dateOrder = b.entry.createdAt.compareTo(a.entry.createdAt);
      return dateOrder != 0 ? dateOrder : a.entry.id.compareTo(b.entry.id);
    });
  }

  final String query, recentText;
  final selected = <LoreContextCandidate>[];
  final omitted = <Map<String, dynamic>>[];

  bool removeLowestPriority() {
    final referenced = {for (final c in selected) ...c.references};
    final index = selected.lastIndexWhere(
      (c) => !c.required && !referenced.contains(c.entry.id),
    );
    if (index < 0) return false;
    final removed = selected.removeAt(index);
    omitted.add({...removed.toJson(), 'reason': 'budget'});
    final stillReferenced = {for (final c in selected) ...c.references};
    selected.removeWhere((c) {
      if (!c.required &&
          c.reason == 'reference' &&
          !stillReferenced.contains(c.entry.id)) {
        omitted.add({...c.toJson(), 'reason': 'budget'});
        return true;
      }
      return false;
    });
    return true;
  }

  Map<String, dynamic> toJson() => {
    'method': 'lexical-hooks-v2',
    'query': query,
    'recentText': recentText,
    'selected': [for (final candidate in selected) candidate.toJson()],
    'omitted': omitted,
  };
}

final class LoreContextCandidate {
  const LoreContextCandidate(
    this.entry, {
    required this.references,
    required this.score,
    required this.required,
    required this.reason,
  });
  final LoreEntry entry;
  final Set<String> references;
  final int score;
  final bool required;
  final String reason;

  Map<String, dynamic> toJson() => {
    'id': entry.id,
    'revisionId': entry.revisionId,
    'name': entry.name,
    'score': score,
    'required': required,
    'reason': reason,
  };
}

Iterable<String> _referenceIds(LoreEntry entry) => switch (entry.kind) {
  LoreKind.relationship => [
    entry.data['fromId'],
    entry.data['toId'],
  ].whereType<String>(),
  LoreKind.map =>
    (entry.data['points'] as List? ?? [])
        .whereType<Map>()
        .map((point) => point['entityId'])
        .whereType<String>(),
  _ => const [],
};

bool _mentions(String text, String name) {
  name = name.trim().toLowerCase();
  if (name.isEmpty) return false;
  return RegExp('(?<![a-z0-9])${RegExp.escape(name)}(?![a-z0-9])')
      .hasMatch(text.toLowerCase());
}

Set<String> _terms(String text) {
  // shortcut: lexical matches miss synonyms; add semantic retrieval if recall proves insufficient.
  final result = <String>{};
  for (final match in RegExp(
    r'[\u3400-\u9fff]+|[a-z0-9]+',
  ).allMatches(text.toLowerCase())) {
    final word = match[0]!;
    if (RegExp(r'^[a-z0-9]').hasMatch(word)) {
      if (word.length > 1 &&
          !{
            'the',
            'and',
            'with',
            'for',
            'this',
            'that',
            'from',
            'into',
          }.contains(word)) {
        result.add(word);
      }
    } else {
      for (var i = 0; i + 1 < word.length; i++) {
        result.add(word.substring(i, i + 2));
      }
    }
  }
  return result;
}
