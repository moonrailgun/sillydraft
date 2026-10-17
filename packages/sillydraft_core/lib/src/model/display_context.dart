import 'dart:math';

import '../providers/provider.dart';
import '../st/macro_engine.dart';
import '../st/preset_importer.dart';
import '../st/prompt_compiler.dart';

/// What a branch needs to show manuscripts the way its bound card expects:
/// the display regex rules, macro values, card greetings and metadata an
/// HTML block may read. Built once per writing profile and cached.
final class DisplayContext {
  const DisplayContext({
    this.rules = const [],
    this.env = const MacroEnv(user: '我'),
    this.greetings = const [],
    this.greetingIndex = 0,
    this.cardId,
    this.card = const {},
    this.helperScripts = const [],
  });

  static const empty = DisplayContext();

  /// Context for a card's JSON (a V1 root or a V2/V3 document), with
  /// [rules] from global and preset regex placed before the card's own, as
  /// SillyTavern orders them; the macros read [writingEnv] of [preset] and
  /// [connection].
  factory DisplayContext.fromCard(
    Map<String, dynamic> raw, {
    List<Map<String, dynamic>> rules = const [],
    String userName = '我',
    String persona = '',
    int greetingIndex = 0,
    String? cardId,
    ImportedPreset? preset,
    ModelConnection? connection,
  }) {
    final data = raw['spec'] == null
        ? raw
        : raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    String text(String key) => data[key] is String ? data[key] as String : '';
    final extensions = data['extensions'] is Map<String, dynamic>
        ? data['extensions'] as Map<String, dynamic>
        : <String, dynamic>{};
    final greetings = [
      text('first_mes'),
      if (data['alternate_greetings'] is List)
        for (final g in data['alternate_greetings'] as List)
          if (g is String) g,
    ];
    final card = <String, dynamic>{
      for (final key in const [
        'name',
        'description',
        'personality',
        'scenario',
        'first_mes',
        'mes_example',
        'creator_notes',
        'system_prompt',
        'post_history_instructions',
        'tags',
        'creator',
        'character_version',
        'alternate_greetings',
      ])
        if (data[key] != null) key: data[key],
      'avatar': 'none',
      'extensions': {
        for (final entry in extensions.entries)
          if (entry.key != 'tavern_helper' && entry.key != 'regex_scripts')
            entry.key: entry.value,
      },
    };
    final helper = extensions['tavern_helper'];
    return DisplayContext(
      rules: [...rules, ...regexRulesOf(extensions)],
      env: writingEnv(
        card: raw,
        user: userName.isEmpty ? '我' : userName,
        persona: persona,
        preset: preset,
        connection: connection,
      ),
      greetings: greetings,
      greetingIndex: greetings.isEmpty
          ? 0
          : greetingIndex.clamp(0, greetings.length - 1),
      cardId: cardId,
      card: {...card, 'data': Map<String, dynamic>.from(card)},
      helperScripts: helper is Map<String, dynamic> && helper['scripts'] is List
          ? [
              for (final script in helper['scripts'] as List)
                if (script is Map<String, dynamic>)
                  (
                    name: script['name'] is String
                        ? script['name'] as String
                        : '',
                    enabled: script['enabled'] == true,
                    info: script['info'] is String
                        ? script['info'] as String
                        : '',
                  ),
            ]
          : const [],
    );
  }

  /// What macros read where no request is made: ST reads its live settings
  /// there (the model and token limits of the selected API, script.js
  /// `getGeneratingModel`, `getMax*Tokens`; the selected templates), so
  /// this is the env of the request the branch would make, with its
  /// writing profile's [preset] (none: the default writing preset, which
  /// has no templates) to the [connection] writing uses. Without one the
  /// model and the connection's limits are unknown.
  static MacroEnv writingEnv({
    Map<String, dynamic>? card,
    required String user,
    String persona = '',
    ImportedPreset? preset,
    ModelConnection? connection,
  }) => PresetInput.envOf(
    card: card,
    user: user,
    persona: persona,
    preset: preset,
    model: connection?.model,
    contextWindow: connection?.contextWindow,
    maxOutputTokens: connection?.maxOutputTokens,
  );

  /// The chat macros where no request is made: ST 1.19.0 chat-macros.js
  /// reads the live `chat`, here the branch's [count] chapters (chapter N
  /// is message N, each a character message, as at the prompt), the last
  /// one's text [last] as stored. Nothing has been generated since the
  /// chat was opened (state-macros.js clears `lastGenerationType` on
  /// CHAT_CHANGED). A story begun from a card opens with its greeting,
  /// which script.js `getFirstMessage` (L7710-7742) gives the greetings as
  /// swipes only with alternate greetings, an empty first one dropped;
  /// [greeting] is the one shown (default [greetingIndex]).
  Map<String, String> chatMacros(int count, String last, {int? greeting}) {
    final values = PromptCompiler.chatValues([
      for (var i = 0; i < count; i++)
        PromptMessage('assistant', i == count - 1 ? last : ''),
    ], '');
    if (count == 1 && greetings.isNotEmpty) {
      final skipped = greetings.first.isEmpty ? 1 : 0;
      final swipes = greetings.length > 1;
      values['lastswipeid'] = swipes ? '${greetings.length - skipped}' : '';
      values['currentswipeid'] = swipes
          ? '${max((greeting ?? greetingIndex) - skipped, 0) + 1}'
          : '';
    }
    return values;
  }

  /// Macros of the greeting a story opens with ([greeting], default
  /// [greetingIndex]): script.js `getChatResult` (L7684-7708) starts a chat
  /// with just that greeting, as written, and `messageFormatting`
  /// (L1805-1812) resolves its macros against that chat.
  MacroEngine greetingMacros({required DateTime clock, int? greeting}) {
    final index = greeting ?? greetingIndex;
    return MacroEngine(
      env: env,
      values: chatMacros(1, greetings[index], greeting: index),
      clock: clock,
      seed: 0,
    );
  }

  /// The `regex_scripts` list of a card or preset `extensions` object.
  static List<Map<String, dynamic>> regexRulesOf(Object? extensions) {
    if (extensions is! Map<String, dynamic>) return const [];
    final rules = extensions['regex_scripts'];
    return rules is List
        ? [
            for (final rule in rules)
              if (rule is Map<String, dynamic>) rule,
          ]
        : const [];
  }

  /// Regex rules in SillyTavern order: global, preset, then card.
  final List<Map<String, dynamic>> rules;

  /// What the env macros read: [writingEnv] of the branch's writing
  /// profile and connection.
  final MacroEnv env;

  /// Raw card greetings: the first message, then the alternates.
  final List<String> greetings;

  /// Which greeting the opening chapter was started from.
  final int greetingIndex;
  final String? cardId;

  /// Card fields a page may read with `getCharData()`. Heavy extensions
  /// (embedded 酒馆助手 scripts, regex) are left out.
  final Map<String, dynamic> card;

  /// 酒馆助手 scripts embedded in the card. SillyDraft lists them but does
  /// not run a script library.
  final List<({String name, bool enabled, String info})> helperScripts;

  bool get hasCard => cardId != null;
  String get userName => env.user;

  /// The card's name; empty without a card.
  String get charName => card['name'] is String ? card['name'] as String : '';
}
