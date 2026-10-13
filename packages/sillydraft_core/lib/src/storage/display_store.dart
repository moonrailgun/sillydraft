part of 'story_repository.dart';

extension DisplayOperations on StoryRepository {
  /// Display rules and card data for a branch, from its writing profile.
  /// Cached until the profile changes; resources are immutable versions.
  Future<DisplayContext> displayContext(String branchId) async {
    final profile = await getSetting('writing/$branchId') ?? {};
    final key = jsonEncode(profile);
    final cached = _displayCache[branchId];
    if (cached != null && cached.key == key) return cached.context;
    final context = await _buildDisplayContext(profile);
    _displayCache[branchId] = (key: key, context: context);
    return context;
  }

  Future<DisplayContext> _buildDisplayContext(
    Map<String, dynamic> profile,
  ) async {
    final rules = <Map<String, dynamic>>[];
    for (final id in (profile['regexIds'] as List? ?? const [])) {
      final raw = await _resourceData(id);
      if (raw == null) continue;
      final scripts = raw['scripts'];
      rules.addAll(
        scripts is List
            ? [
                for (final s in scripts)
                  if (s is Map<String, dynamic>) s,
              ]
            : [raw],
      );
    }
    if (profile['presetId'] case final String presetId) {
      final preset =
          (profile['presetOverrides'] as Map?)?[presetId]
              as Map<String, dynamic>? ??
          await _resourceData(presetId);
      rules.addAll(DisplayContext.regexRulesOf(preset?['extensions']));
    }
    final userName = profile['userName'] is String
        ? profile['userName'] as String
        : '主角';
    final persona = profile['persona'] is String
        ? profile['persona'] as String
        : '';
    final cardId = profile['cardId'];
    final raw = cardId is String ? await _resourceData(cardId) : null;
    if (raw == null) {
      return DisplayContext(
        rules: rules,
        macroValues: {
          'user': userName.isEmpty ? '主角' : userName,
          'persona': persona,
        },
      );
    }
    final index = profile['greetingIndex'];
    return DisplayContext.fromCard(
      raw,
      rules: rules,
      userName: userName,
      persona: persona,
      greetingIndex: index is int ? index : 0,
      cardId: cardId as String,
    );
  }

  Future<Map<String, dynamic>?> _resourceData(Object? id) async {
    if (id is! String) return null;
    try {
      return (await getResource(id)).data;
    } on StoryNotFound {
      return null;
    }
  }

  /// Presentation for a revision without a generation task: the branch's
  /// current display rules, as SillyTavern applies regex to every message.
  /// Rules that fail leave the text as written rather than hiding it.
  Future<ManuscriptPresentation> _presentWithBranchRules(
    DocumentRevision revision, {
    String? branchId,
  }) async {
    branchId ??= revision.originBranchId;
    final context = await displayContext(branchId);
    if (context.rules.isEmpty) {
      return ManuscriptPresentation.identity(revision.content);
    }
    BranchVariables variables;
    try {
      variables = await getBranchVariables(
        branchId,
        throughChapterId: revision.chapterId,
      );
    } on StoryNotFound {
      variables = await getBranchVariables(branchId);
    }
    return ManuscriptPresentation.fromRules(
      revision.content,
      rules: context.rules,
      macros: MacroEngine(
        values: context.macroValues,
        clock: DateTime.now().toUtc(),
        seed: 0,
        local: variables.local,
        global: variables.global,
      ),
      strict: false,
    );
  }
}
