/// What a branch needs to show manuscripts the way its bound card expects:
/// the display regex rules, macro values, card greetings and metadata an
/// HTML block may read. Built once per writing profile and cached.
final class DisplayContext {
  const DisplayContext({
    this.rules = const [],
    this.macroValues = const {},
    this.greetings = const [],
    this.greetingIndex = 0,
    this.cardId,
    this.card = const {},
    this.helperScripts = const [],
  });

  static const empty = DisplayContext();

  /// Context for a card's JSON (a V1 root or a V2/V3 document), with
  /// [rules] from global and preset regex placed before the card's own, as
  /// SillyTavern orders them.
  factory DisplayContext.fromCard(
    Map<String, dynamic> raw, {
    List<Map<String, dynamic>> rules = const [],
    String userName = '主角',
    String persona = '',
    int greetingIndex = 0,
    String? cardId,
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
      macroValues: {
        'user': userName.isEmpty ? '主角' : userName,
        'persona': persona,
        'char': text('name'),
        'description': text('description'),
        'personality': text('personality'),
        'scenario': text('scenario'),
      },
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

  /// `char`, `user`, `persona`, `description`, `personality`, `scenario`.
  final Map<String, String> macroValues;

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
  String get userName => macroValues['user'] ?? '主角';
  String get charName => macroValues['char'] ?? '';
}
