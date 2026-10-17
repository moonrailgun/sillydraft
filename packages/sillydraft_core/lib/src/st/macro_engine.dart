import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'import_types.dart';
import 'moment.dart';
import 'preset_importer.dart';
import 'variable_codec.dart';

part 'macro_env.dart';

/// What a macro handler receives. [args] are resolved unless the macro is
/// lazy; a scoped call has its content as the last one.
typedef _Call = ({
  String name,
  String flags,
  List<String> args,
  bool scoped,
  String raw,
  int position,
  int level,
  StringBuffer out,
});

/// A registered macro with the argument rules of ST 1.19.0
/// (06bde939fb1e9c4c8d8641d810f0a916b5bce127) MacroRegistry: [min]..[max]
/// unnamed arguments, any number more for a [list] macro. [integer] types
/// every argument INTEGER; [lazy] is `delayArgResolution`. A handler returns
/// null for arguments it cannot use, which keeps the macro text.
final class _Macro {
  _Macro(
    this.run, {
    this.min = 0,
    this.max = 0,
    this.list = false,
    this.integer = false,
    this.lazy = false,
  });
  final String? Function(_Call call) run;
  final int min, max;
  final bool list, integer, lazy;

  /// MacroRegistry `isArgsValid`.
  bool accepts(int count) => count >= min && (list || count <= max);

  /// MacroCstWalker `#canAcceptScopedContent` for an opener with [count]
  /// arguments: list macros never take content.
  bool scopes(int count) => !list && accepts(count + 1);
  String get expected => list
      ? '至少 $min'
      : min == max
      ? '$min'
      : '$min 到 $max';
}

/// A macro body split into flags, name and trimmed argument spans;
/// [closing] marks a closing tag such as `{{/if}}`.
typedef _Parsed = ({
  String flags,
  String name,
  List<(int, int)> spans,
  String junk,
  bool closing,
});

/// A macro in a source; [end] is -1 when it is not closed.
typedef _Token = ({int start, int end, _Parsed macro});

/// A task-local evaluator. Mutations are returned with the proposal, never
/// committed by previewing or compiling a request.
final class MacroEngine {
  MacroEngine({
    this.env = const MacroEnv(),
    Map<String, String> values = const {},
    Map<String, String> outlets = const {},
    required this.clock,
    required int seed,
    Duration? utcOffset,
    this.idleSince,
    Map<String, String> local = const {},
    Map<String, String> global = const {},
  }) : values = Map.of(values),
       outlets = Map.of(outlets),
       utcOffset = utcOffset ?? clock.timeZoneOffset,
       local = Map.of(local),
       global = Map.of(global),
       _random = Random(seed),
       _seed = seed;

  /// What the env macros (names, card fields, model) read.
  final MacroEnv env;

  /// Zero-argument macros a stage adds to [env], such as the chat state
  /// (ST `dynamicMacros`); they take precedence over registered macros.
  final Map<String, String> values;

  /// What the request's world info put in each outlet, by name (script.js
  /// `extension_prompts` set by `Generate`); empty until it is scanned.
  final Map<String, String> outlets;
  final Map<String, String> local, global;

  /// "Now" for the time macros, and how far local time is from UTC (ST uses
  /// the browser's time zone); by default [clock]'s own offset, so a local
  /// clock gives local time and a UTC one UTC.
  final DateTime clock;
  final Duration utcOffset;

  /// When the user message `idleDuration` measures from was sent; without
  /// one it is `just now`, as in ST.
  final DateTime? idleSince;
  final Random _random;
  final int _seed;
  final diagnostics = <CompatibilityDiagnostic>[];
  int _operations = 0;

  /// The `transform` of the current [render] call (ST env
  /// `functions.postProcess`).
  String Function(String)? _transform;

  /// What a handler returning null reports instead of the generic warning.
  CompatibilityDiagnostic? _failure;

  /// The `original` of the current [render] call, '' once it was used.
  String? _original;

  /// Card fields resolved in the current env, and whether the env has
  /// none (ST `replaceCharacterCard: false`, as script.js `baseChatReplace`
  /// evaluates a card field).
  Map<String, Object> _fields = {};
  bool _cardless = false;

  /// The macros SillyDraft evaluates, by lower-case name and alias, with the
  /// argument rules of their ST 1.19.0 registrations in
  /// public/scripts/macros/definitions/ and in the built-in code outside it
  /// (authors-note.js, reasoning.js, the memory, stable-diffusion and
  /// expressions extensions). A valid name missing here is
  /// reported as `unknown_macro`. Each key of [values] is a zero-argument
  /// macro as well, like ST's dynamic macros.
  late final Map<String, _Macro> _macros = {
    // core-macros.js
    'space': _Macro((c) => _repeat(' ', c.args), max: 1, integer: true),
    'newline': _Macro((c) => _repeat('\n', c.args), max: 1, integer: true),
    'noop': _Macro((_) => ''),
    'trim': _Macro((c) => c.scoped ? c.args.single : '{{trim}}', max: 1),
    'if': _Macro(_if, min: 2, max: 2, lazy: true),
    'else': _Macro((_) => _elseMarker),
    // `#send_textarea`, which script.js `Generate` empties before it builds
    // a prompt (L4398-4403); SillyDraft's frontends never leave text there.
    'input': _Macro((_) => ''),
    // script.js `getMaxPromptTokens` (L5981-5987: context minus response),
    // `getMaxContextTokens` and `getMaxResponseTokens` for the request.
    for (final (names, value) in [
      (
        ['maxprompt', 'maxprompttokens'],
        env.maxContext == null || env.maxResponse == null
            ? null
            : env.maxContext! - env.maxResponse!,
      ),
      (['maxcontext', 'maxcontexttokens'], env.maxContext),
      (['maxresponse', 'maxresponsetokens'], env.maxResponse),
    ])
      for (final name in names) name: _Macro((c) => _tokens(c, value)),
    'reverse': _Macro(
      (c) => String.fromCharCodes(c.args.single.runes.toList().reversed),
      min: 1,
      max: 1,
    ),
    for (final name in ['//', 'comment'])
      name: _Macro((_) => '', min: 1, max: 1),
    'roll': _Macro((c) => _roll(c.args.single), min: 1, max: 1),
    'random': _Macro(_choose, list: true),
    'pick': _Macro(_choose, list: true),
    'banned': _Macro(_banned, min: 1, max: 1),
    // The joined world info entries of that outlet (script.js `Generate`
    // L4674-4678), empty for an unknown or empty name.
    'outlet': _Macro((c) => outlets[c.args.single] ?? '', min: 1, max: 1),
    // env-macros.js, reading [env]. A chat has one character, so
    // MacroEnvBuilder `getGroupValue` gives its name for `group` and
    // `groupNotMuted` and the user's for `notChar`.
    'user': _Macro((_) => env.user),
    'char': _Macro((_) => env.char),
    for (final name in ['group', 'charifnotgroup', 'groupnotmuted'])
      name: _Macro((_) => env.char),
    'notchar': _Macro((_) => env.user),
    for (final (names, field) in [
      (['charprompt'], 'charPrompt'),
      (['charinstruction'], 'charInstruction'),
      (['chardescription', 'description'], 'description'),
      (['charpersonality', 'personality'], 'personality'),
      (['charscenario', 'scenario'], 'scenario'),
      (['persona'], 'persona'),
      (['mesexamplesraw'], 'mesExamplesRaw'),
      (['chardepthprompt'], 'charDepthPrompt'),
      (['charcreatornotes', 'creatornotes'], 'creatorNotes'),
    ])
      for (final name in names) name: _Macro((c) => _field(field, c.level)),
    'mesexamples': _Macro((c) => _mesExamples(c.level)),
    for (final name in ['charfirstmessage', 'greeting'])
      name: _Macro(_greeting, max: 1, integer: true),
    for (final name in ['charversion', 'version', 'char_version'])
      name: _Macro((_) => _cardless ? '' : env.card['version'] ?? ''),
    'model': _Macro((_) => env.model),
    'original': _Macro(_originalValue),
    'ismobile': _Macro((_) => '${env.isMobile}'),
    // instruct-macros.js `registerSimple`: a template field as written (a
    // macro's result is not resolved again); an empty first/last sequence
    // falls back to the plain one.
    for (final (names, key, fallback) in [
      (['instructstorystringprefix'], 'story_string_prefix', null),
      (['instructstorystringsuffix'], 'story_string_suffix', null),
      (['instructuserprefix', 'instructinput'], 'input_sequence', null),
      (['instructusersuffix'], 'input_suffix', null),
      (['instructassistantprefix', 'instructoutput'], 'output_sequence', null),
      (['instructassistantsuffix', 'instructseparator'], 'output_suffix', null),
      (['instructsystemprefix'], 'system_sequence', null),
      (['instructsystemsuffix'], 'system_suffix', null),
      (
        ['instructfirstassistantprefix', 'instructfirstoutputprefix'],
        'first_output_sequence',
        'output_sequence',
      ),
      (
        ['instructlastassistantprefix', 'instructlastoutputprefix'],
        'last_output_sequence',
        'output_sequence',
      ),
      (['instructstop'], 'stop_sequence', null),
      (['instructuserfiller'], 'user_alignment_message', null),
      (['instructsysteminstructionprefix'], 'last_system_sequence', null),
      (
        ['instructfirstuserprefix', 'instructfirstinput'],
        'first_input_sequence',
        'input_sequence',
      ),
      (
        ['instructlastuserprefix', 'instructlastinput'],
        'last_input_sequence',
        'input_sequence',
      ),
    ])
      for (final name in names)
        name: _Macro((c) => _template(c, env.instruct, key, fallback)),
    for (final name in [
      'defaultsystemprompt',
      'instructsystem',
      'instructsystemprompt',
    ])
      name: _Macro((c) => _template(c, env.sysprompt, 'content')),
    // `systemPrompt` (L59-71): with the system prompt on, the card's (env
    // `charPrompt`, resolved; empty in a card field's env) wins over the
    // template's (`prefer_character_prompt`, which SillyDraft always has).
    'systemprompt': _Macro((c) {
      final content = _template(c, env.sysprompt, 'content');
      final card = env.textCompletion && env.sysprompt.isNotEmpty
          ? _field('charPrompt', c.level)
          : '';
      return card.isEmpty ? content : card;
    }),
    for (final (names, key) in [
      (['exampleseparator', 'chatseparator'], 'example_separator'),
      (['chatstart'], 'chat_start'),
    ])
      for (final name in names)
        name: _Macro((c) => _template(c, env.context, key)),
    // time-macros.js: moment's `en` formats of [clock] at [utcOffset].
    'time': _Macro(_time, max: 1),
    'date': _Macro((_) => _now('LL')),
    'weekday': _Macro((_) => _now('dddd')),
    'isotime': _Macro((_) => _now('HH:mm')),
    'isodate': _Macro((_) => _now('YYYY-MM-DD')),
    'datetimeformat': _Macro((c) => _now(c.args.single), min: 1, max: 1),
    for (final name in ['idleduration', 'idle_duration'])
      name: _Macro(
        (_) => idleSince == null
            ? 'just now'
            : momentHumanize(clock.difference(idleSince!).inMilliseconds),
      ),
    'timediff': _Macro(_timeDiff, min: 2, max: 2),
    // chat-macros.js reads ST's `chat`: a stage with one gives the values
    // in [values]; elsewhere the text stays and is reported.
    for (final name in [
      'lastmessage',
      'lastmessageid',
      'lastusermessage',
      'lastcharmessage',
      'firstincludedmessageid',
      'firstdisplayedmessageid',
      'lastswipeid',
      'currentswipeid',
      'allchatrange',
    ])
      name: _Macro((c) {
        _failure = CompatibilityDiagnostic(
          'chat_state_unavailable',
          '此处没有对话，${c.name} 保留原文：{{${c.raw}}}',
          severity: DiagnosticSeverity.error,
        );
        return null;
      }),
    // state-macros.js: empty until a generation starts (a request gives its
    // type in [values]). SillyDraft loads no ST extension, so
    // `findExtension` finds none.
    'lastgenerationtype': _Macro((_) => ''),
    'hasextension': _Macro(
      (c) {
        diagnostics.add(
          CompatibilityDiagnostic(
            'extension_check',
            'SillyDraft 不加载 ST 扩展，{{${c.raw}}} 按未安装输出 false',
            severity: DiagnosticSeverity.info,
          ),
        );
        return 'false';
      },
      min: 1,
      max: 1,
    ),
    // Registered outside the definitions, each handler's value as written.
    // authors-note.js `registerAuthorsNoteMacros` (L587-619): the chat's,
    // the character's and the default Author's Note. SillyDraft has none,
    // which is ST's with none set (extensions.js L149-153, `loadSettings`
    // L293).
    for (final name in ['authorsnote', 'charauthorsnote', 'defaultauthorsnote'])
      name: _Macro((_) => ''),
    // reasoning.js `registerReasoningMacros` (L1190-1206).
    for (final (name, key) in [
      ('reasoningprefix', 'prefix'),
      ('reasoningsuffix', 'suffix'),
      ('reasoningseparator', 'separator'),
    ])
      name: _Macro((_) => _text(env.reasoning, key)),
    // memory/index.js `summaryMacroHandler` (L1110-1118): the Summarize
    // box, else the latest `extra.memory` in the chat; SillyDraft keeps no
    // such summaries.
    'summary': _Macro((_) => ''),
    // stable-diffusion/index.js `getMacroValue` (L5954-5987), which reads
    // the character, not the env, so a card field has them too.
    for (final name in ['charPrefix', 'charNegativePrefix'])
      name.toLowerCase(): _Macro((_) => env.card[name] ?? ''),
    // expressions/index.js (L2653-2697) with no sprites, which SillyDraft
    // has not: no expression was ever set, no fallback is chosen
    // (`getCurrentFallbackExpression`), and the labels are the defaults
    // (`getExpressionsList` without a classifier API, L1456-1522).
    // `lastExpression` resolves its argument, the character name, itself.
    'lastexpression': _Macro(
      (c) {
        if (c.args.isNotEmpty) _evaluate(c.args.single, c.level);
        return '';
      },
      max: 1,
      lazy: true,
    ),
    'defaultexpression': _Macro((_) => '#none'),
    'availableexpressions': _Macro(
      (_) =>
          'admiration, amusement, anger, annoyance, approval, caring, '
          'confusion, curiosity, desire, disappointment, disapproval, '
          'disgust, embarrassment, excitement, fear, gratitude, grief, joy, '
          'love, nervousness, optimism, pride, realization, relief, remorse, '
          'sadness, surprise, neutral',
    ),
    // variable-macros.js
    ..._variables('', local),
    ..._variables('global', global),
    // 酒馆助手 src/function/macro_like.ts matches `::(.*?)}}`, so the path
    // is all text after the first `::`.
    for (final type in [
      'message',
      'chat',
      'character',
      'preset',
      'global',
    ]) ...{
      'get_${type}_variable': _Macro(
        (c) => _variableMacroValue(
          'get',
          type,
          c.args.join('::'),
          quoted: false,
          prefix: '',
        ),
        min: 1,
        max: 1,
        list: true,
      ),
      for (final quoted in [false, true])
        'format_${type}_variable${quoted ? '_quoted' : ''}': _Macro(
          (c) => _variableMacroValue(
            'format',
            type,
            c.args.join('::'),
            quoted: quoted,
            prefix: _linePrefix(c.out),
          ),
          min: 1,
          max: 1,
          list: true,
        ),
    },
  };
  late final _value = _Macro((c) => values[c.name]);

  /// variable-macros.js for local variables, or global ones with [g].
  Map<String, _Macro> _variables(String g, Map<String, String> scope) {
    _Macro one(String Function(String name) run) =>
        _Macro((c) => run(c.args.single), min: 1, max: 1);
    // variables.js `setLocalVariable` throws on an empty name, which keeps
    // the macro text.
    _Macro write(int count, String? Function(List<String> args) run) => _Macro(
      (c) => c.args[0].isEmpty ? null : run(c.args),
      min: count,
      max: count,
    );
    return {
      'set${g}var': write(2, (a) {
        scope[a[0]] = a[1];
        return '';
      }),
      'add${g}var': write(2, (a) {
        _add(scope, a[0], a[1]);
        return '';
      }),
      'inc${g}var': write(1, (a) => _add(scope, a[0], 1) ?? ''),
      'dec${g}var': write(1, (a) => _add(scope, a[0], -1) ?? ''),
      for (final alias in ['set${g}varkey', 'set${g}varindex'])
        alias: write(3, (a) {
          _setKey(scope, a[0], a[1], a[2]);
          return '';
        }),
      'get${g}var': one((name) => _get(scope, name)),
      for (final alias in ['get${g}varkey', 'get${g}varindex'])
        alias: _Macro(
          (c) => _getKey(scope, c.args[0], c.args[1]),
          min: 2,
          max: 2,
        ),
      for (final alias in ['has${g}var', '${g}varexists'])
        alias: one((name) => '${scope.containsKey(name)}'),
      for (final alias in ['delete${g}var', 'flush${g}var'])
        alias: one((name) {
          scope.remove(name);
          return '';
        }),
    };
  }

  /// Evaluates [source] like ST 1.19.0 MacroEngine `evaluate`. [transform]
  /// is ST's `postProcessFn` (only regex find mode ESCAPED passes one): it
  /// runs on every evaluated macro result, nested ones included (arguments,
  /// scoped content, an `if` condition and branch), and never on text kept
  /// raw (unknown or failed macros, unpaired tags) or a variable shorthand.
  /// [original] is ST's `original`: the first `{{original}}` gives it, later
  /// ones nothing. Each call is a new ST env: card fields resolve anew, or
  /// are empty without [replaceCharacterCard].
  String render(
    String source, {
    String Function(String)? transform,
    String? original,
    bool replaceCharacterCard = true,
  }) {
    if (source.length > 2 * 1024 * 1024) throw const FormatException('宏输入过长');
    _transform = transform;
    _original = original;
    _fields = {};
    _cardless = !replaceCharacterCard;
    return _post(_render(_pre(source), 0));
  }

  /// ST 1.19.0 MacroEngine core pre-processors, run by `evaluate` on its
  /// whole input before parsing: `{{time_UTC±N}}` becomes
  /// `{{time::UTC±N}}` and the markers `<USER>`, `<BOT>`, `<CHAR>`,
  /// `<GROUP>` and `<CHARIFNOTGROUP>` become their macros.
  static String _pre(String text) => text
      .replaceAllMapped(_legacyTime, (m) => '{{time::${m[1]}}}')
      .replaceAllMapped(
        _legacyMarker,
        (m) => switch (m[1]!.toLowerCase()) {
          'user' => '{{user}}',
          'bot' || 'char' => '{{char}}',
          'group' => '{{group}}',
          _ => '{{charIfNotGroup}}',
        },
      );

  /// ST 1.19.0 MacroEngine core post-processors, run by `evaluate` on its
  /// whole output: `\{` and `\}` lose the backslash (an escaped `\{\{` is
  /// never a macro), then a legacy `{{trim}}` goes with the line breaks
  /// around it, then the marker a stray `{{else}}` left.
  static String _post(String text) => text
      .replaceAllMapped(_escapedBrace, (m) => m[1]!)
      .replaceAll(_legacyTrim, '')
      .replaceAll(_elseMarker, '');

  /// core-macros.js `ELSE_MARKER`, what `{{else}}` outside an `{{if}}`
  /// resolves to. It is text until the post-processor drops it, so scoped
  /// content trims around it and a variable can store it.
  static const _elseMarker = '\u0000\u001FELSE\u001F\u0000';

  static final _legacyTime = RegExp(
    r'\{\{time_(UTC[+-]\d+)\}\}',
    caseSensitive: false,
  );
  static final _legacyMarker = RegExp(
    '<(USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>',
    caseSensitive: false,
  );
  static final _escapedBrace = RegExp(r'\\([{}])');
  static final _legacyTrim = RegExp(
    r'(?:\r?\n)*\{\{trim\}\}(?:\r?\n)*',
    caseSensitive: false,
  );

  /// Resolves the macros of [source]; without [pairs], each one on its own,
  /// closing tags included, as in a variable shorthand's value.
  String _render(String source, int level, {bool pairs = true}) {
    if (level > 32) throw const FormatException('宏嵌套过深');
    final all = [..._macrosIn(source, 0)];
    final tokens = [
      for (final token in all)
        if (token.end >= 0) token,
    ];
    final kept = <int>{};
    final out = StringBuffer();
    var cursor = 0;
    for (final (index, token) in tokens.indexed) {
      // Macros inside a scoped macro's content were part of its argument.
      if (token.start < cursor) continue;
      out.write(source.substring(cursor, token.start));
      if (++_operations > 10000) throw const FormatException('宏计算次数超出限制');
      final (value, end) = _resolve(
        source,
        tokens,
        index,
        kept,
        level,
        out,
        pairs,
      );
      cursor = end;
      out.write(value);
      if (out.length > 2 * 1024 * 1024) throw const FormatException('宏输出过长');
    }
    // ST 1.19.0 MacroEngine `evaluate` (L131-133) only logs the parser's
    // syntax warning; the unclosed macro stays text (see [_macrosIn]).
    if (all.where((token) => token.end < 0).firstOrNull case final unclosed?) {
      final rest = source.substring(unclosed.start).runes;
      final excerpt = rest.length > 40
          ? '${String.fromCharCodes(rest.take(40))}…'
          : String.fromCharCodes(rest);
      diagnostics.add(
        CompatibilityDiagnostic(
          'unclosed_macro',
          '宏缺少结束的 }}；保留原文：$excerpt',
          severity: DiagnosticSeverity.warning,
        ),
      );
    }
    out.write(source.substring(cursor));
    return out.toString();
  }

  /// Resolves `tokens[index]` as ST 1.19.0 MacroEngine `#resolveMacro` and
  /// MacroRegistry `executeMacro` do. Returns its text and where the source
  /// continues, which is past the closing tag of a scoped macro. [kept]
  /// holds the closing tags already paired with an opener kept as text.
  /// Flags other than `/` and `#` do nothing at runtime in ST 1.19.0
  /// (MacroFlags.js marks `!`, `?`, `~` and `>` TBD, `#resolveMacro` never
  /// reads them). Without [pairs] no closing tag is looked for and one is
  /// resolved like any macro.
  (String, int) _resolve(
    String source,
    List<_Token> tokens,
    int index,
    Set<int> kept,
    int level,
    StringBuffer out,
    bool pairs,
  ) {
    final token = tokens[index];
    final macro = token.macro;
    final body = source.substring(token.start + 2, token.end - 2);
    var end = token.end;
    if (macro.junk.isNotEmpty) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'macro_syntax',
          '宏名 ${macro.name} 后的“${macro.junk}”无法识别，按 ST 忽略：{{$body}}',
        ),
      );
    }
    if (macro.name.startsWith('.') || macro.name.startsWith(r'$')) {
      return (_variable(macro, body, level), end);
    }
    // MacroCstWalker `#processScopedMacros`: a closing tag left unpaired
    // stays as text, and so does a pair whose opener cannot take content,
    // without evaluating it.
    if (pairs && macro.closing) return ('{{$body}}', end);
    final name = macro.name.toLowerCase();
    final def = values.containsKey(name) ? _value : _macros[name];
    final closer = pairs ? _closer(tokens, index, def, kept) : null;
    if (closer != null && !(def?.scopes(macro.spans.length) ?? true)) {
      kept.add(closer);
      return ('{{$body}}', end);
    }
    final args = [
      for (final (from, to) in macro.spans)
        def != null && def.lazy
            ? body.substring(from, to)
            : _render(body.substring(from, to), level + 1),
    ];
    // ST keeps `{{rawInner}}`: the body with nested macros resolved, which
    // for a scoped macro runs on past `}}` through non-empty content.
    var raw = _spliced(body, macro.spans, args);
    if (closer != null) {
      final content = source.substring(token.end, tokens[closer].start);
      end = tokens[closer].end;
      // MacroCstWalker `#evaluateMacroNode`: content is resolved and
      // trimmed (MacroEngine `trimScopedContent`) unless lazy or `#`.
      args.add(
        def != null && def.lazy
            ? content
            : _trimScoped(_render(content, level + 1), macro.flags),
      );
      if (content.isNotEmpty) raw = '$raw}}${args.last}';
    }
    if (def == null) {
      return (_unknown(raw, '未支持的宏 ${macro.name}；保留原文：{{$raw}}'), end);
    }
    // MacroRegistry `isArgsValid` and `validateArgTypes`; every macro is
    // strictArgs, so a failure keeps the text with a warning.
    final problem = !def.accepts(args.length)
        ? '需要 ${def.expected} 个参数，实际 ${args.length} 个'
        : def.integer && !args.every(_integer.hasMatch)
        ? '的参数需要整数'
        : null;
    final value = problem != null
        ? null
        : def.run((
            name: name,
            flags: macro.flags,
            args: args,
            scoped: closer != null,
            raw: body,
            position: token.start,
            level: level,
            out: out,
          ));
    // MacroEngine `#resolveMacro`: `env.functions.postProcess(result)` for
    // a registered macro that ran, nowhere else.
    if (value != null) return (_transform?.call(value) ?? value, end);
    diagnostics.add(
      _failure ??
          CompatibilityDiagnostic(
            'invalid_macro_arguments',
            '${macro.name} ${problem ?? '的参数无效'}；保留原文：{{$raw}}',
            severity: DiagnosticSeverity.warning,
          ),
    );
    _failure = null;
    return ('{{$raw}}', end);
  }

  /// ST 1.19.0 MacroCstWalker `#evaluateVariableExpr` and
  /// `#executeVariableOperation` for `{{.name}}` (local) and `{{$name}}`
  /// (global): a read, `++`/`--` (the new value), `=`/`+=`/`-=` (empty),
  /// `||`/`??` (the value for a falsy/missing variable), `||=`/`??=` (also
  /// stored), `==`/`!=` on the read text, `>`/`>=`/`<`/`<=` on JS numbers.
  /// The value is resolved once and only when needed, by
  /// `#evaluateVariableValue`: its macros one by one, without scoped pairs,
  /// then trimmed. The result is never transformed (`#resolveMacro` is not
  /// called for it).
  String _variable(_Parsed macro, String body, int level) {
    final scope = macro.name.startsWith('.') ? local : global;
    final name = macro.name.substring(1);
    if (name.isEmpty) {
      // `{{.}}`: chevrotain inserts the missing name.
      diagnostics.add(
        CompatibilityDiagnostic('macro_syntax', '变量简写缺少变量名：{{$body}}'),
      );
    }
    final operator = macro.spans.isEmpty
        ? ''
        : body.substring(macro.spans.first.$1, macro.spans.first.$2);
    String? resolved;
    String value() => resolved ??= macro.spans.length < 2
        ? ''
        : _jsTrim(
            _render(
              body.substring(macro.spans.last.$1),
              level + 1,
              pairs: false,
            ),
          );
    String warn(String result) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'invalid_macro_arguments',
          '变量简写 $operator 需要数字：{{$body}}',
          severity: DiagnosticSeverity.warning,
        ),
      );
      return result;
    }

    switch (operator) {
      case '':
        return _get(scope, name);
      case '++' || '--':
        return _add(scope, name, operator == '++' ? 1 : -1) ?? '';
      case '=':
        scope[name] = value();
        return '';
      case '+=':
        _add(scope, name, value());
        return '';
      case '-=':
        final number = _jsNumber(value());
        if (number == null) return warn('');
        _add(scope, name, -number);
        return '';
      case '||' || '||=':
        final current = _get(scope, name);
        if (!_isFalse(current)) return current;
        return operator == '||' ? value() : scope[name] = value();
      case '??' || '??=':
        if (scope.containsKey(name)) return _get(scope, name);
        return operator == '??' ? value() : scope[name] = value();
      case '==':
        return '${_get(scope, name) == value()}';
      case '!=':
        return '${_get(scope, name) != value()}';
    }
    final current = _jsNumber(scope[name] ?? '');
    final other = _jsNumber(value());
    if (current == null || other == null) return warn('false');
    return '${switch (operator) {
      '>' => current > other,
      '>=' => current >= other,
      '<' => current < other,
      _ => current <= other,
    }}';
  }

  /// ST 1.19.0 variables.js `getLocalVariable` as a macro result: text JS
  /// `Number()` reads as a number comes back as that number (`007` is `7`),
  /// other text as stored, a missing variable as empty.
  static String _get(Map<String, String> scope, String name) =>
      _numeric(scope[name] ?? '');

  /// The end of variables.js `getLocalVariable`: [text] that is not blank
  /// and that JS `Number()` reads becomes that number.
  static String _numeric(String text) {
    final number = _jsTrim(text).isEmpty ? null : _jsNumber(text);
    return number == null ? text : _jsString(number);
  }

  /// ST 1.19.0 variables.js `getLocalVariable(name, {index: key})`: the
  /// variable is JSON-parsed (text that is not JSON comes back whole, as
  /// [_get] reads it) and read at `value[key]`, or `value[Number(key)]`
  /// for a key JS reads as a number. Strings and arrays have `length` and
  /// indexes (UTF-16 units for strings), numbers and booleans nothing. The
  /// entry then goes through `Number()` like [_get]: objects and arrays
  /// come back as JSON, `null` as `null`, `true`/`false` as `1`/`0`, a
  /// missing entry as empty, and a `null` variable as `0` (`null[key]`
  /// throws and the variable stays null). Inherited JS members such as
  /// `constructor` are not mirrored.
  static String _getKey(Map<String, String> scope, String name, String key) {
    final raw = scope[name];
    if (raw == null) return '';
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return _numeric(raw);
    }
    final number = _jsNumber(key);
    final property = number == null ? key : _jsString(number);
    final index = _arrayIndex(number);
    final found = switch (value) {
      null => 0,
      final Map map when map.containsKey(property) => map[property],
      List(:final length) ||
      String(:final length) when key == 'length' => length,
      final List list when index != null && index < list.length => list[index],
      final String text when index != null && index < text.length =>
        text[index],
      _ => '',
    };
    return switch (found) {
      null => 'null',
      String() => _numeric(found),
      num() => _jsString(found),
      bool() => found ? '1' : '0',
      _ => _json(found),
    };
  }

  /// ST 1.19.0 variables.js `setLocalVariable(name, value, {index: key})`:
  /// the variable (missing: `null`) is JSON-parsed, `null` becomes `[]` for
  /// a key JS reads as a number and `{}` otherwise, [value] is stored at the
  /// key as [_getKey] reads it, and the result is written back as JSON. An
  /// array takes only indexes and `length` (other keys are properties
  /// JSON.stringify leaves out, yet the array is rewritten); a variable that
  /// is not JSON or holds a primitive stays as it was (strict-mode
  /// assignment throws, which variables.js swallows).
  static void _setKey(
    Map<String, String> scope,
    String name,
    String key,
    String value,
  ) {
    Object? parsed;
    try {
      parsed = jsonDecode(scope[name] ?? 'null');
    } on FormatException {
      return;
    }
    final number = _jsNumber(key);
    parsed ??= number == null ? <String, Object?>{} : <Object?>[];
    switch (parsed) {
      case Map<String, Object?>():
        parsed[number == null ? key : _jsString(number)] = value;
      case List<Object?>() when key == 'length':
        // `array.length = value` throws a RangeError for an invalid length.
        final length = _jsNumber(value);
        if (length == null ||
            length < 0 ||
            length > 4294967295 ||
            length != length.truncateToDouble()) {
          return;
        }
        _resize(parsed, length.toInt());
      case List<Object?>():
        final index = _arrayIndex(number);
        if (index == null) break;
        if (index >= parsed.length) _resize(parsed, index + 1);
        parsed[index] = value;
      default:
        return;
    }
    scope[name] = _json(parsed);
  }

  /// A JS array index: an integer from 0 below 2^32 - 1.
  static int? _arrayIndex(double? number) =>
      number != null &&
          number >= 0 &&
          number < 4294967295 &&
          number == number.truncateToDouble()
      ? number.toInt()
      : null;

  /// Sets the length of [list]; JSON.stringify writes holes as `null`.
  /// Deviation: ST writes out whatever fits a V8 string (~100 million
  /// holes); past 2 MiB elements this aborts like other oversized macro
  /// output.
  static void _resize(List<Object?> list, int length) {
    if (length > 2 * 1024 * 1024) throw const FormatException('宏输出过长');
    list.length = length;
  }

  /// ST 1.19.0 variables.js `addLocalVariable`: a JSON array gets [value]
  /// pushed; two JS numbers are summed; otherwise [value] is appended to
  /// the variable read as by [_get] (an empty or zero one counts as
  /// nothing). Returns what is stored, or null for a NaN sum, which stores
  /// nothing.
  static String? _add(Map<String, String> scope, String name, Object value) {
    final raw = scope[name] ?? '';
    // `getLocalVariable(name) || 0`.
    final Object current = _jsTrim(raw).isEmpty
        ? (raw.isEmpty ? 0 : raw)
        : _jsNumber(raw) ?? raw;
    if (current is String) {
      try {
        final list = jsonDecode(current);
        if (list is List) return scope[name] = _json([...list, value]);
      } on FormatException {
        // Not an array.
      }
    }
    final number = value is num ? value : _jsNumber(value as String);
    final base = current is num ? current : _jsNumber(current as String);
    if (number == null || base == null) {
      final text = current is num
          ? (current == 0 ? '' : _jsString(current))
          : current;
      return scope[name] = '$text${value is num ? _jsString(value) : value}';
    }
    final sum = base + number;
    return sum.isNaN ? null : scope[name] = _jsString(sum);
  }

  /// JS `Number(text)`, or null for NaN.
  static double? _jsNumber(String text) {
    final trimmed = _jsTrim(text);
    if (trimmed.isEmpty) return 0;
    final radix = _radix.firstMatch(trimmed);
    if (radix != null) {
      final base = const {'x': 16, 'o': 8, 'b': 2}[radix[1]!.toLowerCase()]!;
      return BigInt.tryParse(radix[2]!, radix: base)?.toDouble();
    }
    return _decimal.hasMatch(trimmed) ? double.parse(trimmed) : null;
  }

  static final _radix = RegExp(r'^0([xob])([0-9a-f]+)$', caseSensitive: false);
  static final _decimal = RegExp(
    r'^[+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)$',
  );

  /// JS `String(number)`.
  static String _jsString(num number) {
    if (number == 0) return '0';
    final text = number.toDouble().toString();
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  /// JS `JSON.stringify` of what `jsonDecode` read.
  static String _json(Object? value) => switch (value) {
    final num n => n.isFinite ? _jsString(n) : 'null',
    final List<Object?> list => '[${list.map(_json).join(',')}]',
    final Map<String, Object?> map =>
      '{${_keys(map).map((k) => '${jsonEncode(k)}:${_json(map[k])}').join(',')}}',
    _ => jsonEncode(value),
  };

  /// JS object key order: array indices ascending, then the rest as added.
  static List<String> _keys(Map<String, Object?> map) {
    bool index(String key) =>
        _index.hasMatch(key) && int.parse(key) < 4294967295;
    return [
      ...map.keys.where(index).toList()
        ..sort((a, b) => int.parse(a).compareTo(int.parse(b))),
      ...map.keys.where((key) => !index(key)),
    ];
  }

  static final _index = RegExp(r'^(?:0|[1-9]\d{0,9})$');

  /// JS `trim()`, whose whitespace is RegExp `\s`.
  static String _jsTrim(String text) => text.replaceAll(_edgeSpace, '');
  static final _edgeSpace = RegExp(r'^\s+|\s+$');

  /// Falsy for MacroCstWalker `isFalsy` and the core `if`: empty, or
  /// utils.js `isFalseBoolean` (`off`, `false`, `0` in any case and
  /// padding).
  static bool _isFalse(String text) =>
      text.isEmpty ||
      const ['off', 'false', '0'].contains(_jsTrim(text).toLowerCase());

  static final _integer = RegExp(r'^\s*-?\d+\s*$');

  /// The request's token limit [value]; a stage without a request keeps
  /// the text and reports it.
  String? _tokens(_Call c, num? value) {
    if (value != null) return _jsString(value);
    _failure = CompatibilityDiagnostic(
      'request_unavailable',
      '此处没有模型请求，${c.name} 保留原文：{{${c.raw}}}',
      severity: DiagnosticSeverity.error,
    );
    return null;
  }

  /// core-macros.js `banned`: empty. With the Text Completion API ST also
  /// adds the word, unquoted, to the banned tokens of the next request it
  /// sends (textgen-settings.js `getCustomTokenBans` tokenizes it), which
  /// needs the model's tokenizer; SillyDraft reports it instead.
  String _banned(_Call c) {
    if (env.textCompletion) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'banned_word_unsupported',
          'ST 文本补全会禁用“${c.args.single.replaceAll(_quotes, '')}”的 token，'
              'SillyDraft 没有模型的 tokenizer，未禁用；{{${c.raw}}} 输出为空',
        ),
      );
    }
    return '';
  }

  static final _quotes = RegExp(r'^"|"$');

  /// [key] of a text completion's [template] (instruct-macros.js reads
  /// power_user's), or [fallback] for an empty one. A missing instruct or
  /// system prompt template is ST's with it off, and a missing field
  /// empty, so both give ''. A stage without text completion templates (a
  /// chat preset, no request) gives '' and reports it: ST reads its global
  /// Advanced Formatting settings even with Chat Completion.
  String _template(
    _Call c,
    Map<String, dynamic> template,
    String key, [
    String? fallback,
  ]) {
    if (!env.textCompletion) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'advanced_formatting_unavailable',
          '此处没有文本补全的指令、系统提示与上下文模板，{{${c.raw}}} 输出为空'
              '（ST 读其高级格式设置，聊天补全时也是）',
          severity: DiagnosticSeverity.info,
        ),
      );
      return '';
    }
    final value = _text(template, key);
    return value.isEmpty && fallback != null
        ? _text(template, fallback)
        : value;
  }

  /// `space` and `newline`: ST's `repeat` throws on a negative count, which
  /// keeps the macro text.
  String? _repeat(String unit, List<String> args) {
    final count = args.isEmpty ? 1 : int.tryParse(args.single.trim());
    if (count == null || count > 2 * 1024 * 1024) {
      throw const FormatException('宏输出过长');
    }
    return count < 0 ? null : unit * count;
  }

  /// ST 1.19.0 core-macros.js `if`: resolves only the branch the condition
  /// picks, split at the top-level `{{else}}`, and trims it unless `#`.
  String _if(_Call call) {
    final (yes, no) = _splitElse(call.args[1]);
    final branch = _condition(call.args[0], call.level) ? yes : no;
    return branch == null
        ? ''
        : _trimScoped(_evaluate(branch, call.level), call.flags);
  }

  /// A handler's `resolve` (MacroRegistry `executeMacro`): a full
  /// MacroEngine `evaluate`, so pre- and post-processors run again.
  String _evaluate(String text, int level) =>
      _post(_render(_pre(text), level + 1));

  /// script.js `substituteParams` of [text] in a fresh env sharing the
  /// variables, clock and seed: no `original` or `transform`, card fields
  /// resolved anew, or none without [card].
  String _substitute(String text, int level, {bool card = true}) {
    if (text.isEmpty) return '';
    final (transform, original, fields, cardless) = (
      _transform,
      _original,
      _fields,
      _cardless,
    );
    _transform = null;
    _original = null;
    _fields = {};
    _cardless = !card;
    try {
      return _evaluate(text, level);
    } finally {
      _transform = transform;
      _original = original;
      _fields = fields;
      _cardless = cardless;
    }
  }

  /// The card [field] (or the persona) as MacroEnvBuilder's lazy
  /// `env.character` getters give it: script.js `getCharacterCardFieldsLazy`
  /// trims it and runs `baseChatReplace` once per env. Empty in an env
  /// without card fields.
  String _field(String field, int level) => _cardless
      ? ''
      : (_fields[field] ??= _chatReplace(
              field == 'persona' ? env.persona : env.card[field] ?? '',
              level,
            ))
            as String;

  /// script.js `baseChatReplace` of trimmed card text: its macros resolved
  /// without card fields (`{{description}}` in a description is empty, an
  /// `{{original}}` stays for a prompt override to fill), then `\r`
  /// removed. ST's `collapse_newlines` is off by default; SillyDraft has no
  /// such setting.
  String _chatReplace(String text, int level) =>
      _substitute(_jsTrim(text), level, card: false).replaceAll('\r', '');

  /// env-macros.js `charFirstMessage`: index 0 is the card's first
  /// message, 1 and up its alternate greetings (all of them resolved on
  /// first use, as ST's getter does), anything else empty.
  String _greeting(_Call c) {
    // null: past what an int holds, which no greeting list reaches.
    final index = c.args.isEmpty ? 0 : int.tryParse(c.args.single.trim());
    if (index == 0) return _field('firstMessage', c.level);
    if (_cardless) return '';
    final greetings =
        (_fields['alternateGreetings'] ??= [
              for (final greeting in env.alternateGreetings)
                _chatReplace(greeting, c.level),
            ])
            as List<String>;
    return index != null && index >= 1 && index <= greetings.length
        ? greetings[index - 1]
        : '';
  }

  /// env-macros.js `original`: one-shot, and only when the render has one
  /// (a card's main prompt or post-history override). Without one ST's
  /// call throws and keeps the text; a card field keeps it silently, since
  /// the override fills it in later.
  String? _originalValue(_Call c) {
    final value = _original;
    if (value != null) {
      _original = '';
      return value;
    }
    if (_cardless) return '{{${c.raw}}}';
    _failure = CompatibilityDiagnostic(
      'invalid_macro_arguments',
      'original 只在角色卡覆盖主提示词或历史后指令时有值；保留原文：{{${c.raw}}}',
      severity: DiagnosticSeverity.warning,
    );
    return null;
  }

  /// env-macros.js `mesExamples`: the examples split by script.js
  /// `parseMesExamples`, each block under `<START>` for a chat completion
  /// or instruct mode and under the context template's example separator
  /// otherwise; instruct mode (a text completion with an instruct template,
  /// as [_compileText] formats) formats them with
  /// instruct-mode.js `formatInstructModeExamples`.
  String _mesExamples(int level) {
    final raw = _field('mesExamplesRaw', level);
    if (raw.isEmpty || raw == '<START>') return '';
    final instruct = env.textCompletion && env.instruct.isNotEmpty;
    final separator = _exampleSeparator(level);
    final heading = !env.textCompletion || instruct ? '<START>\n' : separator;
    final blocks = [
      for (final block
          in (raw.startsWith('<START>') ? raw : '<START>\n${_jsTrim(raw)}')
              .split(_start)
              .skip(1))
        '$heading${_jsTrim(block)}\n',
    ];
    return (instruct ? _instructExamples(blocks, level) : blocks).join();
  }

  /// The card's dialogue examples as script.js `Generate` puts them in a
  /// text completion prompt (L4616-4661, L5021): `{{mesExamples}}`'s value
  /// in a fresh env, which no render post-processes afterwards.
  String mesExamples() {
    _transform = _original = null;
    _fields = {};
    _cardless = false;
    return _mesExamples(0);
  }

  static final _start = RegExp('<START>', caseSensitive: false);

  /// The context template's `example_separator`, resolved, and a line
  /// break; empty without one.
  String _exampleSeparator(int level) {
    final separator = _text(env.context, 'example_separator');
    return separator.isEmpty ? '' : '${_substitute(separator, level)}\n';
  }

  static String _text(Map<String, dynamic> map, String key) =>
      map[key] is String ? map[key] as String : '';

  /// instruct-mode.js `formatInstructModeExamples` in a one-character
  /// chat: each block of [blocks] is the separator, then every example in
  /// the user's or the character's sequences. With `macro`, ST resolves a
  /// sequence and then puts the speaker in for `{{name}}`; the name goes in
  /// first here, as an unregistered `{{name}}` would be reported.
  List<String> _instructExamples(List<String> blocks, int level) {
    final instruct = env.instruct;
    final heading = _exampleSeparator(level);
    List<String> plain() => [
      for (final block in blocks)
        block.replaceFirst(RegExp('<START>\n', caseSensitive: false), heading),
    ];
    if (instruct['skip_examples'] == true) return plain();
    final names = instruct['names_behavior'];
    final macro = instruct['macro'] == true, wrap = instruct['wrap'] == true;
    String sequence(String key, String name) {
      final text = _text(instruct, key);
      return macro
          ? _substitute(
              text.replaceAll(
                RegExp(r'\{\{name\}\}', caseSensitive: false),
                name,
              ),
              level,
            )
          : text;
    }

    final inputPrefix = sequence('input_sequence', env.user);
    final outputPrefix = sequence('output_sequence', env.char);
    var inputSuffix = sequence('input_suffix', env.user);
    var outputSuffix = sequence('output_suffix', env.char);
    if (macro && wrap) {
      if (inputSuffix.isEmpty) inputSuffix = '\n';
      if (outputSuffix.isEmpty) outputSuffix = '\n';
    }
    final out = <String>[];
    for (final block in blocks) {
      final examples = _examples(
        block.replaceFirst(_start, '{Example Dialogue:}').replaceAll('\r', ''),
      );
      if (examples.isEmpty) continue;
      if (heading.isNotEmpty) out.add(heading);
      for (final (user, content) in examples) {
        final named = names == 'always' || (names == 'force' && user);
        out.add(
          [
            user ? inputPrefix : outputPrefix,
            '${named ? '${user ? env.user : env.char}: ' : ''}$content'
                '${user ? inputSuffix : outputSuffix}',
          ].where((s) => s.isNotEmpty).join(wrap ? '\n' : ''),
        );
      }
    }
    return out.isEmpty ? plain() : out;
  }

  /// openai.js `parseExampleIntoIndividual` in a one-character chat: after
  /// the heading line, a line starting `user:` or `char:` starts a message
  /// of that speaker; the first such name is cut from each message.
  List<(bool user, String content)> _examples(String block) {
    final result = <(bool, String)>[];
    var lines = <String>[];
    var inUser = false, inChar = false;
    void add(bool user) {
      final name = user ? env.user : env.char;
      result.add((user, _jsTrim(lines.join('\n').replaceFirst('$name:', ''))));
      lines = [];
    }

    for (final line in block.split('\n').skip(1)) {
      if (line.startsWith('${env.user}:')) {
        inUser = true;
        if (inChar) add(false);
        inChar = false;
      } else if (line.startsWith('${env.char}:')) {
        inChar = true;
        if (inUser) add(true);
        inUser = false;
      }
      lines.add(line);
    }
    if (inUser) {
      add(true);
    } else if (inChar) {
      add(false);
    }
    return result;
  }

  /// ST 1.19.0 MacroEngine `trimScopedContent`, skipped with the `#` flag:
  /// trims, and takes the indentation of the first non-blank line off every
  /// line (a line indented less loses all of its own).
  static String _trimScoped(String content, String flags) {
    if (flags.contains('#')) return content;
    final lines = content.split('\n');
    final first = lines.firstWhere(
      (l) => l.trim().isNotEmpty,
      orElse: () => '',
    );
    final indent = _indent.matchAsPrefix(first)![0]!.length;
    if (indent == 0) return content.trim();
    return [
      for (final line in lines)
        _indent.matchAsPrefix(line)![0]!.length >= indent
            ? line.substring(indent)
            : line.trimLeft(),
    ].join('\n').trim();
  }

  static final _indent = RegExp(r'[ \t]*');

  /// ST 1.19.0 core-macros.js `splitOnTopLevelElse`: the first `{{else}}`
  /// outside nested scoped `{{if}}`s; names match exactly.
  (String, String?) _splitElse(String content) {
    var depth = 0;
    for (final token in _macrosIn(content, 0)) {
      // Only top-level macros count; an unclosed one runs to the end.
      if (token.end < 0) break;
      final macro = token.macro;
      final closing = macro.flags.contains('/');
      if (macro.name == 'if' && !closing && macro.spans.length == 1) {
        depth++;
      } else if (macro.name == 'if' && closing) {
        depth--;
      } else if (macro.name == 'else' && depth == 0) {
        return (
          content.substring(0, token.start),
          content.substring(token.end),
        );
      }
    }
    return (content, null);
  }

  /// The ST 1.19.0 core-macros.js `if` condition: a leading `!` inverts it;
  /// the rest is resolved, then a `.name`/`$name` result reads that variable
  /// and the name of a registered macro without required arguments
  /// (MacroRegistry `getPrimaryMacro`, `minArgs === 0`) resolves as that
  /// macro. Empty is false, and so are `off`, `false` and `0` in any case
  /// and padding (utils.js `isFalseBoolean`).
  bool _condition(String raw, int level) {
    final bang = _bang.matchAsPrefix(raw);
    var condition = _evaluate(raw.substring(bang?.end ?? 0), level);
    final variable = _conditionVariable.matchAsPrefix(condition);
    final key = condition.trim().toLowerCase();
    if (variable != null) {
      final get = variable[1] == '.' ? 'getvar' : 'getglobalvar';
      condition = _evaluate('{{$get::${variable[2]}}}', level);
    } else if (values.containsKey(key) || _macros[key]?.min == 0) {
      condition = _evaluate('{{$condition}}', level);
    }
    return _isFalse(condition) == (bang != null);
  }

  static final _bang = RegExp(r'\s*!\s*');

  static final _conditionVariable = RegExp(r'^([.$])([a-zA-Z](?:[\w-]*\w)?)$');

  /// Text already written on the current output line, which 酒馆助手's
  /// `format_*_variable` macros use to indent multi-line YAML.
  static String _linePrefix(StringBuffer out) {
    final text = out.toString();
    return text.substring(text.lastIndexOf('\n') + 1);
  }

  /// `random` and `pick`; one argument is split by ST 1.19.0
  /// core-macros.js `readSingleArgsRandomList`.
  String _choose(_Call call) {
    final args = call.args;
    final options = args.length != 1
        ? args
        : args.first.contains('::')
        ? args.first.split('::').map((s) => s.trim()).toList()
        : args.first
              .replaceAll(r'\,', '\u0000')
              .split(',')
              .map((s) => s.trim().replaceAll('\u0000', ','))
              .toList();
    if (options.isEmpty) return '';
    if (call.name == 'random') return options[_random.nextInt(options.length)];
    diagnostics.add(
      const CompatibilityDiagnostic(
        'pick_adapted',
        'pick 使用任务种子保持稳定；种子规则与 ST 聊天标识不同',
        severity: DiagnosticSeverity.info,
      ),
    );
    final digest = sha256
        .convert(utf8.encode('$_seed:${call.position}:${call.raw}'))
        .bytes;
    return options[((digest[0] << 16) | (digest[1] << 8) | digest[2]) %
        options.length];
  }

  /// 酒馆助手's `{{get_X_variable::path}}` and `{{format_X_variable::path}}`
  /// macro-likes, which MVU cards use to put their state into prompts.
  /// `message` and `chat` read this task's local variables, `global` the
  /// global ones; character and preset variables are not kept here. Keys
  /// starting with `$` are omitted, strings pass through, anything else is
  /// JSON (`get`) or YAML indented to the line (`format`).
  String _variableMacroValue(
    String kind,
    String type,
    String path, {
    required bool quoted,
    required String prefix,
  }) {
    final store = switch (type) {
      'global' => decodeVariables(global),
      'message' || 'chat' => decodeVariables(local),
      _ => <String, dynamic>{},
    };
    final value = _withoutDollarKeys(_lookup(store, _htmlUnescape(path)));
    if (kind == 'get') {
      return value is String ? value : jsonEncode(value);
    }
    final text = value is String
        ? value
        : _yaml(value, 0, quoted: quoted).trimRight();
    return text.replaceAll('\n', '\n${' ' * prefix.length}');
  }

  static Object? _lookup(Object? root, String path) {
    if (path.trim().isEmpty) return root;
    Object? current = root;
    for (final part
        in path.split(RegExp(r'\.|\[|\]\.?')).where((p) => p.isNotEmpty)) {
      final key = part.replaceAll(RegExp(r'''^["']|["']\$'''), '');
      if (current is Map) {
        current = current[key];
      } else if (current is List) {
        final index = int.tryParse(key);
        current = index != null && index >= 0 && index < current.length
            ? current[index]
            : null;
      } else {
        return null;
      }
    }
    return current;
  }

  static Object? _withoutDollarKeys(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!entry.key.toString().startsWith(r'$'))
            entry.key.toString(): _withoutDollarKeys(entry.value),
      };
    }
    if (value is List) return value.map(_withoutDollarKeys).toList();
    return value;
  }

  static String _htmlUnescape(String text) => text
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  static final _plainUnsafe = RegExp(
    r'''^[\s\-?:,\[\]{}#&*!|>'"%@`]|: |\s#|[:\s]$|^(true|false|null|~|yes|no|on|off)$|^[-+]?(\d[\d_]*\.?\d*([eE][-+]?\d+)?|\.\d+|0x[0-9a-fA-F]+)$''',
    caseSensitive: false,
  );

  /// A compact YAML dump in the style of the `yaml` npm package with
  /// literal block quotes, enough for prompts to read.
  static String _yaml(Object? value, int indent, {required bool quoted}) {
    final pad = ' ' * indent;
    String scalar(Object? v) {
      if (v == null) return 'null';
      if (v is bool || v is num) return v.toString();
      if (v is Map) return '{}';
      if (v is List) return '[]';
      final text = v.toString();
      if (text.contains('\n')) {
        final lines = text.trimRight().split('\n');
        return '|-\n${lines.map((l) => '$pad  $l').join('\n')}';
      }
      if (quoted || text.isEmpty || _plainUnsafe.hasMatch(text)) {
        return jsonEncode(text);
      }
      return text;
    }

    // The quoted variant quotes strings but keeps keys plain.
    String key(String k) =>
        k.isEmpty || _plainUnsafe.hasMatch(k) ? jsonEncode(k) : k;
    if (value is Map) {
      if (value.isEmpty) return '{}';
      final lines = <String>[];
      for (final entry in value.entries) {
        final v = entry.value;
        if ((v is Map && v.isNotEmpty) || (v is List && v.isNotEmpty)) {
          lines.add('$pad${key(entry.key.toString())}:');
          lines.add(_yaml(v, indent + 2, quoted: quoted));
        } else {
          lines.add('$pad${key(entry.key.toString())}: ${scalar(v)}');
        }
      }
      return lines.join('\n');
    }
    if (value is List) {
      if (value.isEmpty) return '[]';
      final lines = <String>[];
      for (final item in value) {
        if ((item is Map && item.isNotEmpty) ||
            (item is List && item.isNotEmpty)) {
          final nested = _yaml(item, indent + 2, quoted: quoted);
          lines.add('$pad- ${nested.trimLeft()}');
        } else {
          lines.add('$pad- ${scalar(item)}');
        }
      }
      return lines.join('\n');
    }
    return '$pad${scalar(value)}';
  }

  /// ST keeps an unregistered macro as `{{rawInner}}` and reports nothing;
  /// SillyDraft keeps the same text and adds a warning that blocks no run.
  String _unknown(String raw, String message) {
    diagnostics.add(
      CompatibilityDiagnostic(
        'unknown_macro',
        message,
        severity: DiagnosticSeverity.warning,
      ),
    );
    return '{{$raw}}';
  }

  /// ST 1.19.0 (06bde939fb1e9c4c8d8641d810f0a916b5bce127) core-macros.js
  /// `roll`: bare digits mean `1dX`, otherwise droll 0.2.1's `NdS±M`; an
  /// invalid formula warns and renders empty. Dice use the task seed.
  /// Deviation: ST rolls any count; more than a million dice is treated as
  /// invalid so a preset cannot freeze the app.
  String _roll(String formula) {
    final dice = RegExp(
      r'^([1-9]\d*)?d([1-9]\d*)([+-]\d+)?$',
      caseSensitive: false,
    ).firstMatch(RegExp(r'^\d+$').hasMatch(formula) ? '1d$formula' : formula);
    final count = int.tryParse(dice?.group(1) ?? '1');
    final sides = int.tryParse(dice?.group(2) ?? '');
    if (count == null || sides == null || count > 1000000) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'invalid_macro_arguments',
          count != null && count > 1000000
              ? 'roll 骰子数超过 1000000：$formula；输出为空'
              : 'roll 公式无效：$formula；按 ST 输出为空',
          severity: DiagnosticSeverity.warning,
        ),
      );
      return '';
    }
    var total = int.tryParse(dice!.group(3) ?? '0') ?? 0;
    for (var i = 0; i < count; i++) {
      total += 1 + (_random.nextDouble() * sides).floor();
    }
    return '$total';
  }

  /// moment `format` of [clock] in local time; null where moment throws.
  String? _now(String format) =>
      momentFormat(clock.millisecondsSinceEpoch, utcOffset.inMinutes, format);

  /// ST 1.19.0 time-macros.js `time`: `LT` in local time, or at the offset
  /// of an exact `UTC±N` argument, which moment `utcOffset` reads as hours
  /// below 16 and as minutes from there.
  String? _time(_Call call) {
    final match = call.args.isEmpty
        ? null
        : RegExp(r'^UTC([+-]\d+)$').firstMatch(call.args.single);
    if (match == null) return _now('LT');
    final offset = double.parse(match[1]!);
    return momentFormat(
      clock.millisecondsSinceEpoch,
      offset.abs() < 16 ? offset * 60 : offset,
      'LT',
    );
  }

  /// ST 1.19.0 time-macros.js `timeDiff`: `moment(a).diff(moment(b))`
  /// humanized with a suffix, text without a zone read as local time. Text
  /// moment passes to the browser's `new Date()` stays as written: what it
  /// becomes differs between browsers.
  String? _timeDiff(_Call call) {
    final offset = utcOffset.inMinutes;
    final [a, b] = [for (final arg in call.args) momentParse(arg, offset)];
    if ((a?.isNaN ?? false) || (b?.isNaN ?? false)) return momentInvalid;
    if (a != null && b != null) return momentHumanize(a - b, withSuffix: true);
    _failure = CompatibilityDiagnostic(
      'unsupported_time_format',
      'timeDiff 的时间“${a == null ? call.args[0] : call.args[1]}”不是 ISO 8601 '
          '或 RFC 2822 格式，ST 交给浏览器的 Date 解析，结果因浏览器而异；保留原文',
      severity: DiagnosticSeverity.warning,
    );
    return null;
  }

  /// ST 1.19.0 MacroLexer `macro_def` mode: whitespace and the flags
  /// `! ? ~ # / >`, then `//`, a `.`/`$` variable shorthand or an
  /// identifier. A `{{` without such a head is plain text.
  static final _head = RegExp(
    r'((?:\s|[!?~#>]|/(?!/))*)(//|[.$]|[a-zA-Z][\w-]*)',
  );
  static final _shorthand = RegExp(r'\s*([a-zA-Z](?:[\w-]*\w)?)?\s*');
  static final _operator = RegExp(
    r'\+\+|--|\?\?=?|\|\|=?|-=|==|!=|>=?|<=?|\+=|=',
  );

  /// At most one token after a variable shorthand: an operator, `//`, a
  /// `.`/`$` or flag, or an identifier with the characters the lexer drops
  /// after it (MacroLexer `var_after_identifier` falling back to
  /// `macro_def`).
  static final _stray = RegExp(
    '\\s*(?:${_operator.pattern}|//|[.\$!?~#/]|[a-zA-Z][^\\s:|}]*)?\\s*\$',
  );
  static final _space = RegExp(r'\s');
  static final _junk = RegExp(r'[^\s:|}]*');

  /// The next macro in [source] at or after [from], or null.
  static _Token? _next(String source, int from) {
    var start = source.indexOf('{{', from);
    while (start >= 0) {
      // Of `{{{`, the last two braces open a macro (Plaintext.OpenBrace).
      if (source.startsWith('{', start + 2)) {
        start++;
        continue;
      }
      if (_head.matchAsPrefix(source, start + 2) != null) {
        final end = _end(source, start);
        final macro = _parse(
          source.substring(start + 2, end < 0 ? source.length : end - 2),
        );
        if (macro != null) return (start: start, end: end, macro: macro);
      }
      start = source.indexOf('{{', start + 2);
    }
    return null;
  }

  /// The macros of [source] from [from] on, without nested ones. An
  /// unclosed one (end -1) runs to the end of [source]; the macros listed
  /// after it are the ones inside it, which ST 1.19.0 MacroCstWalker
  /// `#flattenIncompleteMacro` evaluates in its place while the unclosed
  /// macro itself stays text.
  static Iterable<_Token> _macrosIn(String source, int from) sync* {
    for (
      var token = _next(source, from);
      token != null;
      token = _next(source, token.end < 0 ? token.start + 2 : token.end)
    ) {
      yield token;
    }
  }

  /// The index after the `}}` closing the macro at [start], or -1. As in
  /// MacroLexer's argument mode, only a `{{` with a macro head nests, and
  /// not within what the lexer skips after a name (`{{a{{b}}` closes at
  /// the first `}}`).
  static int _end(String source, int start) {
    var depth = 1;
    var i = _afterHead(source, start);
    while (i + 1 < source.length) {
      if (source.startsWith('{{', i) &&
          _head.matchAsPrefix(source, i + 2) != null) {
        depth++;
        i = _afterHead(source, i);
      } else if (source.startsWith('}}', i)) {
        if (--depth == 0) return i + 2;
        i += 2;
      } else {
        i += source.startsWith('{{', i) ? 2 : 1;
      }
    }
    return -1;
  }

  /// Where the lexer goes on after the head of the macro at [start]: past
  /// the characters it skips after an identifier (see [_parse]).
  static int _afterHead(String source, int start) {
    final head = _head.matchAsPrefix(source, start + 2)!;
    return const ['//', '.', r'$'].contains(head[2])
        ? head.end
        : _junk.matchAsPrefix(source, head.end)!.end;
  }

  /// Splits a macro body the way MacroLexer and MacroParser do, or returns
  /// null where ST leaves the braces as plain text.
  static _Parsed? _parse(String body) {
    final head = _head.matchAsPrefix(body);
    if (head == null) return null;
    final flags = head[1]!.replaceAll(_space, '');
    final name = head[2]!;
    if (name == '.' || name == r'$') {
      // MacroLexer `var_identifier`/`var_after_identifier` modes and
      // MacroParser `variableExpr`: a name and at most one operator, whose
      // span is the first one; a value operator takes the rest as the
      // second. Chevrotain's single-token deletion drops one stray token
      // before `}}` (ST warns); more of them, or text after a missing name,
      // leave the braces as plain text.
      final variable = _shorthand.matchAsPrefix(body, head.end)!;
      var rest = variable.end;
      final operator = variable[1] == null
          ? null
          : _operator.matchAsPrefix(body, rest);
      final spans = [
        if (operator != null) (operator.start, operator.end),
        if (operator != null && operator[0] != '++' && operator[0] != '--')
          (operator.end, body.length),
      ];
      if (operator != null) rest = spans.last.$2;
      final junk = body.substring(rest).trim();
      if (variable[1] == null
          ? junk.isNotEmpty
          : _stray.matchAsPrefix(body, rest) == null) {
        return null;
      }
      return (
        flags: flags,
        name: '$name${variable[1] ?? ''}',
        spans: spans,
        junk: junk,
        closing: false,
      );
    }
    // After an identifier the lexer skips what is not whitespace, `:`, `|`
    // or `}`, with a warning; `//` starts its arguments at once.
    final junk = name == '//' ? '' : _junk.matchAsPrefix(body, head.end)![0]!;
    final spans = _spans(body, head.end + junk.length);
    return (
      flags: flags,
      name: name,
      spans: spans,
      junk: junk,
      closing:
          flags.contains('/') ||
          (name == '//' && spans.isNotEmpty && _slashFirst(body, spans.first)),
    );
  }

  /// MacroCstWalker `extractMacroInfo`: the lexer reads `//` before a lone
  /// `/`, so `{{///}}` is a `//` whose first argument token starts with `/`,
  /// and closes a `{{//}}` block. Whitespace and nested macros are not
  /// argument tokens.
  static bool _slashFirst(String body, (int, int) span) {
    var (i, to) = span;
    final text = body.substring(0, to);
    while (true) {
      while (i < to && _space.hasMatch(text[i])) {
        i++;
      }
      final nested = _next(text, i);
      if (nested == null || nested.start != i || nested.end < 0) break;
      i = nested.end;
    }
    return text.startsWith('/', i);
  }

  /// ST 1.19.0 MacroParser `arguments`: a `::` after the name starts
  /// `::`-separated arguments; otherwise whitespace or one `:` starts a
  /// single argument that keeps any `::` (a lone `:` gives an empty one).
  /// Spans are trimmed, as MacroCstWalker spans first to last token.
  static List<(int, int)> _spans(String body, int from) {
    var i = from;
    while (i < body.length && _space.hasMatch(body[i])) {
      i++;
    }
    if (i == body.length) return [];
    if (!body.startsWith('::', i)) {
      return [_trimmed(body, body.startsWith(':', i) ? i + 1 : i, body.length)];
    }
    final spans = <(int, int)>[];
    var depth = 0;
    var start = i + 2;
    for (var j = start; j + 1 < body.length; j++) {
      if (body.startsWith('{{', j)) {
        if (_head.matchAsPrefix(body, j + 2) != null) depth++;
        j++;
      } else if (body.startsWith('}}', j)) {
        depth--;
        j++;
      } else if (depth == 0 && body.startsWith('::', j)) {
        spans.add(_trimmed(body, start, j));
        start = j + 2;
        j++;
      }
    }
    spans.add(_trimmed(body, start, body.length));
    return spans;
  }

  static (int, int) _trimmed(String text, int from, int to) {
    while (from < to && _space.hasMatch(text[from])) {
      from++;
    }
    while (to > from && _space.hasMatch(text[to - 1])) {
      to--;
    }
    return (from, to);
  }

  /// [body] with each argument span replaced by its value.
  static String _spliced(
    String body,
    List<(int, int)> spans,
    List<String> values,
  ) {
    final out = StringBuffer();
    var cursor = 0;
    for (final (i, (from, to)) in spans.indexed) {
      out
        ..write(body.substring(cursor, from))
        ..write(values[i]);
      cursor = to;
    }
    return (out..write(body.substring(cursor))).toString();
  }

  /// The index of the closing tag for the opener `tokens[index]`, paired
  /// as ST 1.19.0 MacroCstWalker `#findMatchingClosingMacro` does: names
  /// match in any case, only openers that could take content nest, and
  /// closing tags in [kept] are already used.
  int? _closer(List<_Token> tokens, int index, _Macro? def, Set<int> kept) {
    final name = tokens[index].macro.name.toLowerCase();
    var depth = 0;
    for (var i = index + 1; i < tokens.length; i++) {
      final macro = tokens[i].macro;
      if (macro.name.toLowerCase() != name || kept.contains(i)) continue;
      if (macro.closing) {
        if (depth-- == 0) return i;
      } else if (def?.scopes(macro.spans.length) ?? true) {
        depth++;
      }
    }
    return null;
  }
}
