part of 'macro_engine.dart';

/// What ST 1.19.0 (06bde939fb1e9c4c8d8641d810f0a916b5bce127) MacroEnvBuilder
/// `buildFromRawEnv` gives the env macros (macros/definitions/env-macros.js)
/// in a one-character chat: the persona and character names, the raw card
/// fields script.js `getCharacterCardFieldsLazy` reads (keyed by their
/// `env.character` names), the model (`getGeneratingModel`), whether the
/// app runs on a phone or tablet (RossAscends-mods.js `isMobile`), the
/// API, the context, instruct and system prompt templates (power-user.js
/// `power_user.context`, `.instruct`, `.sysprompt`), the reasoning
/// template (`power_user.reasoning`), and the request's token limits
/// (script.js `getMaxContextTokens`, `getMaxResponseTokens`).
/// [MacroEnv.of] builds it; a writing task stores it as `macroEnv`, so its
/// output (regex, MVU) and display stages read what the prompt was
/// compiled with, as every ST stage reads the same live env.
final class MacroEnv {
  const MacroEnv({
    this.user = '',
    this.char = '',
    this.persona = '',
    this.card = const {},
    this.alternateGreetings = const [],
    this.model = '',
    this.isMobile = false,
    this.textCompletion = false,
    this.context = const {},
    this.instruct = const {},
    this.sysprompt = const {},
    this.reasoning = _freshReasoning,
    this.maxContext,
    this.maxResponse,
  });

  /// The env of a chat with [card] (a V1 root or a V2/V3 document; without
  /// one `{{char}}` is 旁白, as SillyDraft compiles), the persona named
  /// [user] with the description [persona], the [model] the request goes
  /// to and the [preset] it is compiled with (its context, instruct and
  /// system prompt templates for a text completion; ST `main_api` is
  /// `openai` for a chat preset; its reasoning template). [isMobile]
  /// defaults to running on Android or iOS. [maxContext] and [maxResponse]
  /// are the request's token limits. A null [model] is one nothing gives:
  /// no connection to write with.
  factory MacroEnv.of({
    Map<String, dynamic>? card,
    required String user,
    String persona = '',
    ImportedPreset? preset,
    String? model = '',
    bool? isMobile,
    num? maxContext,
    num? maxResponse,
  }) {
    final data = card?['spec'] != null && card?['data'] is Map<String, dynamic>
        ? card!['data'] as Map<String, dynamic>
        : card ?? const <String, dynamic>{};
    String text(Object? value) => value is String ? value : '';
    final extensions = data['extensions'] is Map
        ? data['extensions'] as Map
        : const <Object?, Object?>{};
    final depth = extensions['depth_prompt'];
    // stable-diffusion/index.js `getMacroValue` (L5954-5975): the user's
    // own prefixes for the character (`extension_settings.sd`, which
    // SillyDraft has not), else the card's shared ones if non-empty.
    final sd = extensions['sd_character_prompt'] is Map
        ? extensions['sd_character_prompt'] as Map
        : const <Object?, Object?>{};
    final version = data['character_version'];
    final kind = preset?.kind;
    final textCompletion =
        preset != null &&
        kind != PresetKind.chat &&
        kind != PresetKind.promptPack;
    // [_compileText] reads these too, so the prompt and every macro see the
    // templates as ST selects them.
    Map<String, dynamic>? template(String name, PresetKind own) =>
        !textCompletion
        ? null
        : preset.parts[name]?.raw ?? (kind == own ? preset.raw : null);
    final instruct = template('instruct', PresetKind.instruct) ?? const {};
    return MacroEnv(
      user: user,
      char: card == null ? '旁白' : text(data['name']),
      persona: persona,
      card: {
        'description': text(data['description']),
        'personality': text(data['personality']),
        'scenario': text(data['scenario']),
        'charPrompt': text(data['system_prompt']),
        'charInstruction': text(data['post_history_instructions']),
        'mesExamplesRaw': text(data['mes_example']),
        'charDepthPrompt': text(depth is Map ? depth['prompt'] : null),
        'creatorNotes': text(data['creator_notes']),
        'firstMessage': text(data['first_mes']),
        // `character_version ?? ''`, untrimmed; JS writes a number out.
        'version': version is num && version != 0
            ? MacroEngine._jsString(version)
            : text(version),
        'charPrefix': text(sd['positive']),
        'charNegativePrefix': text(sd['negative']),
      },
      alternateGreetings: [
        if (data['alternate_greetings'] is List)
          for (final greeting in data['alternate_greetings'] as List)
            text(greeting),
      ],
      model: model,
      isMobile: isMobile ?? (Platform.isAndroid || Platform.isIOS),
      textCompletion: textCompletion,
      context: textCompletion
          ? _context(template('context', PresetKind.context))
          : const {},
      instruct: instruct.isEmpty ? const {} : _instruct(instruct),
      sysprompt: template('sysprompt', PresetKind.systemPrompt) ?? const {},
      // Selecting a template copies its prefix, suffix and separator
      // (reasoning.js L854-871); without one ST keeps a fresh install's.
      reasoning: template('reasoning', PresetKind.reasoning) ?? _freshReasoning,
      maxContext: maxContext,
      maxResponse: maxResponse,
    );
  }

  /// [template] as ST 1.19.0 instruct-mode.js `migrateInstructModeSettings`
  /// (L55-105) leaves it, which ST runs on the saved template at load
  /// (L116) and on each one it selects (L834; preset-manager.js
  /// `updateList` selects every imported one): `separator_sequence`
  /// becomes `output_suffix`, `names` and `names_force_groups` become
  /// `names_behavior`, missing fields get defaults, obsolete ones go.
  /// Selecting it (L826-857) copies only the fields it has; the others keep
  /// the previous template's, here a fresh install's ([_freshInstruct]).
  static Map<String, dynamic> _instruct(Map<String, dynamic> template) {
    bool truthy(Object? v) => v != null && v != false && v != '' && v != 0;
    final migrated = {...template};
    if (migrated.containsKey('separator_sequence')) {
      final separator = migrated.remove('separator_sequence');
      migrated['output_suffix'] = truthy(separator) ? separator : '';
    }
    if (migrated.containsKey('names')) {
      migrated['names_behavior'] = truthy(migrated['names'])
          ? 'always'
          : truthy(migrated['names_force_groups'])
          ? 'force'
          : 'none';
    }
    for (final MapEntry(:key, :value) in const {
      'input_suffix': '',
      'system_sequence': '',
      'system_suffix': '',
      'user_alignment_message': '',
      'last_system_sequence': '',
      'first_input_sequence': '',
      'last_input_sequence': '',
      'skip_examples': false,
      'system_same_as_user': false,
      'names_behavior': 'force',
      'sequences_as_stop_strings': true,
      'story_string_prefix': '',
      'story_string_suffix': '',
    }.entries) {
      migrated.putIfAbsent(key, () => value);
    }
    for (final key in const [
      'names',
      'names_force_groups',
      'system_sequence_prefix',
      'system_sequence_suffix',
    ]) {
      migrated.remove(key);
    }
    return {..._freshInstruct, ...migrated};
  }

  /// The instruct template of a fresh install (default/content/settings.json,
  /// Alpaca, loaded but not enabled), minus the fields the migration
  /// always gives a template.
  static const _freshInstruct = {
    'input_sequence': '### Instruction:',
    'output_sequence': '### Response:',
    'first_output_sequence': '',
    'last_output_sequence': '',
    'stop_sequence': '',
    'activation_regex': '',
    'output_suffix': '\n\n',
    'wrap': true,
    'macro': true,
  };

  /// The context template ST 1.19.0 uses with [template] selected
  /// (power-user.js `#context_presets` change, L2037-2085): its fields; a
  /// missing or null one takes the control's default (L354-370) or, for
  /// the story string and the two markers, which have none, keeps the
  /// previous template's. SillyDraft has no previous template and takes a
  /// fresh install's, which is also the one in use without [template]:
  /// default/content/settings.json's (seeded by content-manager.js
  /// L190-196, L326-329) after `loadContextSettings` (L1944-2025).
  /// `autoFixStoryString`'s anchor blocks are left out: SillyDraft's
  /// anchors are always empty.
  static Map<String, dynamic> _context(Map<String, dynamic>? template) => {
    'story_string':
        '{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}'
        '{{#if description}}{{description}}\n{{/if}}'
        "{{#if personality}}{{char}}'s personality: {{personality}}\n{{/if}}"
        '{{#if scenario}}Scenario: {{scenario}}\n{{/if}}'
        '{{#if wiAfter}}{{wiAfter}}\n{{/if}}{{#if persona}}{{persona}}\n{{/if}}',
    'chat_start': '***',
    'example_separator': '***',
    // On in a fresh install; the control's default is off.
    'use_stop_strings': template == null,
    'names_as_stop_strings': true,
    'story_string_position': 0,
    'story_string_depth': 1,
    'story_string_role': 0,
    // The global `power_user.always_force_name2` the template sets: on in a
    // fresh install and by default.
    'always_force_name2': true,
    if (template != null)
      for (final MapEntry(:key, :value) in template.entries) key: ?value,
  };

  /// power-user.js `power_user.reasoning` (L274-284), which a fresh install
  /// keeps (default/content/settings.json has none; reasoning.js
  /// `loadReasoningTemplates` L1665 names it Think XML, the same values).
  static const _freshReasoning = {
    'prefix': '<think>',
    'suffix': '</think>',
    'separator': '\n',
  };

  factory MacroEnv.fromJson(Map<String, dynamic> json) => MacroEnv(
    user: json['user'] as String? ?? '',
    char: json['char'] as String? ?? '',
    persona: json['persona'] as String? ?? '',
    card: (json['card'] as Map? ?? const {}).cast<String, String>(),
    alternateGreetings: (json['alternateGreetings'] as List? ?? const [])
        .cast<String>(),
    model: json['model'] as String? ?? '',
    isMobile: json['isMobile'] == true,
    textCompletion: json['textCompletion'] == true,
    context: (json['context'] as Map? ?? const {}).cast<String, dynamic>(),
    instruct: (json['instruct'] as Map? ?? const {}).cast<String, dynamic>(),
    sysprompt: (json['sysprompt'] as Map? ?? const {}).cast<String, dynamic>(),
    reasoning: (json['reasoning'] as Map? ?? _freshReasoning)
        .cast<String, dynamic>(),
    maxContext: json['maxContext'] as num?,
    maxResponse: json['maxResponse'] as num?,
  );

  /// ST `env.names.user` and `env.names.char`.
  final String user, char;

  /// The persona description (`power_user.persona_description`).
  final String persona;

  /// Raw card text by `env.character` name: `description`, `personality`,
  /// `scenario`, `charPrompt`, `charInstruction`, `mesExamplesRaw`,
  /// `charDepthPrompt`, `creatorNotes`, `firstMessage`, `version`; and the
  /// image generation prefixes `charPrefix`, `charNegativePrefix`.
  final Map<String, String> card;
  final List<String> alternateGreetings;

  /// The model the request goes to; null where none is known (no
  /// connection to write with).
  final String? model;
  final bool isMobile;

  /// ST `main_api` is not `openai`: the prompt is a text completion.
  final bool textCompletion;

  /// The context, instruct and system prompt templates of a text
  /// completion as ST selects them (an instruct template migrated, each
  /// completed from a fresh install's, which is the context template
  /// without one); without an instruct or system prompt template ST's
  /// instruct mode or system prompt is off. `_compileText` builds the
  /// prompt from them.
  final Map<String, dynamic> context, instruct, sysprompt;

  /// The reasoning template's `prefix`, `suffix` and `separator`: the
  /// preset's, else a fresh install's, for every API.
  final Map<String, dynamic> reasoning;

  /// The request's context size and the response length it asks for, in
  /// tokens; null at a stage without a request.
  final num? maxContext, maxResponse;

  Map<String, dynamic> toJson() => {
    'user': user,
    'char': char,
    'persona': persona,
    'card': card,
    'alternateGreetings': alternateGreetings,
    'model': model,
    'isMobile': isMobile,
    'textCompletion': textCompletion,
    'context': context,
    'instruct': instruct,
    'sysprompt': sysprompt,
    'reasoning': reasoning,
    'maxContext': maxContext,
    'maxResponse': maxResponse,
  };
}
