part of 'story_repository.dart';

extension DisplayOperations on StoryRepository {
  /// Display rules and card data for a branch, from its writing profile.
  /// Cached until the profile changes; resources are immutable versions.
  Future<DisplayContext> displayContext(String branchId) async {
    final profile = await _settingJson('writing/$branchId') ?? '{}';
    // Editing a persona changes {{user}}, and the connections the model and
    // token limits, without touching the profile.
    final key = [
      profile,
      for (final setting in ['personas', 'connections', 'modelRoles'])
        await _settingJson(setting) ?? '',
    ].join('\n');
    final cached = _displayCache[branchId];
    if (cached != null && cached.key == key) return cached.context;
    final context = await _buildDisplayContext(
      jsonDecode(profile) as Map<String, dynamic>,
    );
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
    final persona = await personaFor(profile);
    // The macros read what a writing request of the branch would. Settings
    // writing refuses leave it without that preset or connection.
    ImportedPreset? preset;
    try {
      preset = await writingPreset(profile);
    } on Exception {
      preset = null;
    }
    final connection = await _writingConnection();
    final cardId = profile['cardId'];
    final raw = cardId is String ? await _resourceData(cardId) : null;
    if (raw == null) {
      return DisplayContext(
        rules: rules,
        env: DisplayContext.writingEnv(
          user: persona.name,
          persona: persona.prompt,
          preset: preset,
          connection: connection,
        ),
      );
    }
    final index = profile['greetingIndex'];
    return DisplayContext.fromCard(
      raw,
      rules: rules,
      userName: persona.name,
      persona: persona.prompt,
      greetingIndex: index is int ? index : 0,
      cardId: cardId as String,
      preset: preset,
      connection: connection,
    );
  }

  /// The connection writing uses, read where no request is made; null
  /// also when the connection settings cannot be read.
  Future<ModelConnection?> _writingConnection() async {
    try {
      return await connectionFor('writing');
    } catch (_) {
      return null;
    }
  }

  /// The preset a branch writes with, from its writing [profile]: the
  /// chosen one (as customised for the branch), bundled with the context,
  /// instruct, system prompt and reasoning templates chosen beside it;
  /// null without any. A chat preset cannot take templates.
  Future<ImportedPreset?> writingPreset(Map<String, dynamic> profile) async {
    final override = (profile['presetOverrides'] as Map?)?[profile['presetId']];
    ImportedPreset? preset;
    if (override is Map<String, dynamic>) {
      preset = PresetImporter().decode(override);
    } else if (profile['presetId'] case final String id) {
      final resource = await getResource(id);
      if (resource.kind != ResourceKind.preset) {
        throw const FormatException('此资源不是预设');
      }
      preset = PresetImporter().decode(resource.data);
    }
    final parts = <String, dynamic>{
      for (final MapEntry(:key, :value) in const {
        'contextId': 'context',
        'instructId': 'instruct',
        'systemPromptId': 'sysprompt',
        'reasoningId': 'reasoning',
      }.entries)
        if (profile[key] case final String id)
          value: (await getResource(id)).data,
    };
    if (parts.isEmpty) return preset;
    if (preset?.kind == PresetKind.chat ||
        preset?.kind == PresetKind.promptPack) {
      throw const FormatException('聊天预设不能与文本补全格式组件混用。请清除格式组件或选用文本补全预设。');
    }
    return PresetImporter().decode({
      ...?preset?.kind == PresetKind.bundle ? preset?.raw : null,
      if (preset != null && preset.kind != PresetKind.bundle)
        'preset': preset.raw,
      ...parts,
    });
  }

  /// The chat macros of [branchId] where no request is made, read from its
  /// chapters as they are now ([DisplayContext.chatMacros]).
  Future<Map<String, String>> chatMacros(
    String branchId, [
    DisplayContext? context,
  ]) async {
    context ??= await displayContext(branchId);
    final rows = await _rows(
      'SELECT count(*) AS n FROM branch_chapters WHERE branch_id = ?',
      [branchId],
    );
    final count = rows.single['n'] as int;
    if (count == 0) return context.chatMacros(0, '');
    final last = _chapter(
      await _one(
        '${StoryRepository._chapterQuery} '
            'ORDER BY c.position DESC, c.chapter_id DESC LIMIT 1',
        [branchId],
        '章节',
      ),
    );
    return context.chatMacros(count, last.content.text);
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
        env: context.env,
        values: await chatMacros(branchId, context),
        clock: DateTime.now(),
        seed: 0,
        local: variables.local,
        global: variables.global,
      ),
      strict: false,
    );
  }
}
