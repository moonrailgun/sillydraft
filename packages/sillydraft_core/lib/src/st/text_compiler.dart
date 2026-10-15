part of 'prompt_compiler.dart';

({String text, List<String> stops, Map<String, dynamic> parameters})
_compileText(
  PresetInput input,
  MacroEngine macros,
  List<PromptMessage> history,
  Map<String, String> markers,
  WorldBookResult world,
  List<CompatibilityDiagnostic> diagnostics,
) {
  final preset = input.preset;
  final parts = preset.parts;
  // The templates as ST selects them, which the macros read too.
  final MacroEnv(:context, :instruct, sysprompt: system) = macros.env;
  final parameters = _parameters(
    parts['preset']?.parameters ?? preset.parameters,
  );
  if ([PresetKind.unknown, PresetKind.reasoning].contains(preset.kind)) {
    diagnostics.add(
      const CompatibilityDiagnostic(
        'incomplete_text_bundle',
        '此文件需与正文预设组合使用',
        severity: DiagnosticSeverity.error,
      ),
    );
  }
  for (final part in parts.values) {
    diagnostics.addAll(part.diagnostics);
  }
  // ST 1.19.0 script.js `Generate` (L4686-4697): with the system prompt on
  // (a system prompt template here), the card's system prompt (its env
  // value) resolved with the template's text as `original`, or else the
  // template through `baseChatReplace` (no card fields); in instruct mode
  // resolved once more. Off, `system` is empty.
  final ownSystem = stringField(system, 'content');
  var main = '';
  if (system.isNotEmpty) {
    final override = macros.render('{{charPrompt}}');
    main = override.isNotEmpty
        ? macros.render(override, original: ownSystem)
        : _chatReplace(macros, ownSystem);
    if (instruct.isNotEmpty) main = macros.render(main, original: ownSystem);
  }
  final values = <String, Object?>{
    'system': main,
    'description': markers['charDescription'],
    'personality': markers['charPersonality'],
    'scenario': markers['scenario'],
    'persona': markers['personaDescription'],
    'wiBefore': markers['worldInfoBefore'],
    'wiAfter': markers['worldInfoAfter'],
    'anchorBefore': '',
    'anchorAfter': '',
    'char': macros.env.char,
    'user': macros.env.user,
    'trim': '{{trim}}',
    'newline': '{{newline}}',
  };
  final template = stringField(context, 'story_string');
  var story = '';
  try {
    story = macros
        .render(TemplateEngine().render(template, values))
        .replaceFirst(RegExp(r'^\n+'), '');
  } on UnsupportedTemplate catch (error) {
    diagnostics.add(
      CompatibilityDiagnostic(
        'unsupported_template',
        error.message,
        severity: DiagnosticSeverity.error,
      ),
    );
  }
  final wrap = instruct['wrap'] == true;
  final separator = wrap ? '\n' : '';
  final position = intField(context, 'story_string_position', 0);
  final storySuffix = stringField(instruct, 'story_string_suffix');
  if (story.isNotEmpty &&
      !story.endsWith('\n') &&
      position != 1 &&
      (instruct.isEmpty || (wrap && storySuffix.isEmpty))) {
    story += '\n';
  }
  var queue = [...history];
  final injections = <_Injection>[];
  for (final entry in world.entries.where((e) => e.entry.position == 4)) {
    injections.add(
      _Injection(
        PromptMessage(
          ['system', 'user', 'assistant'][entry.entry.role.clamp(0, 2)],
          entry.content,
        ),
        entry.entry.depth,
        entry.entry.order,
      ),
    );
  }
  final out = StringBuffer();
  if (position == 1 && story.isNotEmpty) {
    final role = [
      'system',
      'user',
      'assistant',
    ][intField(context, 'story_string_role', 0).clamp(0, 2)];
    injections.add(
      _Injection(
        PromptMessage(role, story),
        intField(context, 'story_string_depth', 1),
        100,
      ),
    );
  } else if (position == 0) {
    final prefix = macros.render(
      stringField(
        instruct,
        'story_string_prefix',
      ).replaceAll('{{name}}', 'System'),
    );
    if (story.isNotEmpty) {
      out.write(
        '${prefix.isEmpty ? '' : '$prefix$separator'}$story${macros.render(storySuffix)}',
      );
    }
  } else if (story.isNotEmpty) {
    diagnostics.add(
      CompatibilityDiagnostic(
        'story_string_position',
        '未支持的上下文模板位置：$position',
        severity: DiagnosticSeverity.error,
      ),
    );
  }
  queue = _inject(queue, injections);
  // script.js `Generate` L4616-4661, L5021: the card's examples follow the
  // story string, as `{{mesExamples}}` gives them; then the chat start
  // (`addChatsSeparator`).
  out.write(macros.mesExamples());
  final chatStart = stringField(context, 'chat_start');
  if (chatStart.isNotEmpty) out.write(macros.render('$chatStart\n'));
  final continues = input.generationType == 'continue';
  // L4748-4765: with the system prompt on, the card's post-history
  // instructions (their env value, the template's as their `original`) or
  // else the template's join the chat as an unnamed user message, before
  // the message a continue extends.
  if (system.isNotEmpty) {
    final ownPostHistory = stringField(system, 'post_history');
    final instructions = macros.render('{{charInstruction}}');
    final postHistory = instructions.isNotEmpty
        ? macros.render(instructions, original: ownPostHistory)
        : _chatReplace(macros, ownPostHistory);
    if (postHistory.isNotEmpty) {
      queue.insert(
        continues ? (queue.length - 1).clamp(0, queue.length) : queue.length,
        PromptMessage('user', postHistory, name: ''),
      );
    }
  }
  // L4767-4815: in instruct mode the first message takes the first
  // sequences, the last user message the last ones. (L4838-4841's empty
  // line for an empty chat is left out: a normal generation has the brief.)
  final lastUser = queue.lastIndexWhere((m) => m.role == 'user');
  final lines = [
    for (final (i, message) in queue.indexed)
      _formatTextMessage(
        message,
        instruct,
        macros,
        sequence: i == lastUser
            ? 'last'
            : i == 0
            ? 'first'
            : '',
      ),
  ];
  // L4818-4827, L4929-4936: the user alignment message opens a chat whose
  // first message is not the user's.
  final alignment = stringField(instruct, 'user_alignment_message');
  if (alignment.isNotEmpty && queue.firstOrNull?.role != 'user') {
    lines.insert(
      0,
      _formatTextMessage(
        PromptMessage('user', macros.render(alignment)),
        instruct,
        macros,
        sequence: 'first',
      ),
    );
  }
  // L4994-5011 and `modifyLastPromptLine` (L5028-5091): the last message
  // loses its line break (in instruct mode only with `wrap`), then the
  // instruct prompt line follows, or the character's name with
  // `always_force_name2`. SillyDraft's continue keeps the chat as it is.
  if (!continues && lines.isNotEmpty) {
    var last = lines.removeLast();
    if ((instruct.isEmpty || wrap) && last.endsWith('\n')) {
      last = last.substring(0, last.length - 1);
    }
    if (instruct.isNotEmpty) {
      last += _instructPrompt(instruct, macros);
    } else if (context['always_force_name2'] == true) {
      last += '${last.endsWith('\n') ? '' : '\n'}${macros.env.char}:';
    }
    lines.add(last);
  }
  out.writeAll(lines);
  final stops = <String>{};
  for (final key in [
    'stop_sequence',
    if (instruct['sequences_as_stop_strings'] == true) ...[
      'input_sequence',
      'output_sequence',
      'system_sequence',
      'first_output_sequence',
      'last_output_sequence',
      'last_system_sequence',
    ],
  ]) {
    for (var sequence in stringField(instruct, key).split('\n')) {
      if (sequence.trim().isEmpty) continue;
      final name = key == 'input_sequence'
          ? macros.env.user
          : key.contains('system')
          ? 'System'
          : macros.env.char;
      sequence =
          '$separator${sequence.replaceAll(RegExp(r'\{\{name\}\}', caseSensitive: false), name)}';
      stops.add(instruct['macro'] == true ? macros.render(sequence) : sequence);
    }
  }
  if (context['use_stop_strings'] == true) {
    for (final key in ['chat_start', 'example_separator']) {
      final value = stringField(context, key);
      if (value.isNotEmpty) stops.add('\n${macros.render(value)}');
    }
  }
  // script.js `getStoppingStrings` (L3033-3042): the user's name; the
  // character's only for a continue after a user message.
  if (context['names_as_stop_strings'] == true) {
    stops.add('\n${macros.env.user}:');
    if (input.generationType == 'continue' &&
        history.lastOrNull?.role == 'user') {
      stops.add('\n${macros.env.char}:');
    }
  }
  // `getCombinedPrompt`'s `combine` (L5182-5204) drops every `\r`.
  return (
    text: out.toString().replaceAll('\r', ''),
    stops: stops.toList(),
    parameters: parameters,
  );
}

/// ST 1.19.0 script.js `baseChatReplace`: [text]'s macros without card
/// fields, `\r` removed.
String _chatReplace(MacroEngine macros, String text) =>
    macros.render(text, replaceCharacterCard: false).replaceAll('\r', '');

/// script.js `formatMessageHistoryItem` (L5833-5853) with instruct-mode.js
/// `formatInstructModeChat` (L387-457) in a one-character chat. A system
/// message is ST's narrator: no name, and in instruct mode the system
/// sequences with the character's name as `{{name}}`, as ST passes it. A
/// message named '' has no name either. [sequence] is `first` or `last`
/// for `force_output_sequence`.
String _formatTextMessage(
  PromptMessage message,
  Map<String, dynamic> instruct,
  MacroEngine macros, {
  String sequence = '',
}) {
  final narrator = message.role == 'system', user = message.role == 'user';
  final name = narrator
      ? ''
      : message.name ?? (user ? macros.env.user : macros.env.char);
  if (instruct.isEmpty) {
    return '${name.isEmpty ? '' : '$name: '}${message.content}\n';
  }
  final type = narrator
      ? (instruct['system_same_as_user'] == true ? 'input' : 'system')
      : user
      ? 'input'
      : 'output';
  var prefix = stringField(instruct, '${type}_sequence');
  if (!narrator && sequence.isNotEmpty) {
    final override = stringField(instruct, '${sequence}_${type}_sequence');
    if (override.isNotEmpty) prefix = override;
  }
  var suffix = stringField(instruct, '${type}_suffix');
  if (instruct['macro'] == true) {
    final speaker = narrator ? macros.env.char : name;
    prefix = _sequence(macros, prefix, speaker);
    suffix = _sequence(macros, suffix, speaker);
  }
  final wrap = instruct['wrap'] == true;
  if (suffix.isEmpty && wrap) suffix = '\n';
  final named = name.isNotEmpty && instruct['names_behavior'] == 'always';
  return [
    prefix,
    '${named ? '$name: ' : ''}${message.content}$suffix',
  ].where((s) => s.isNotEmpty).join(wrap ? '\n' : '');
}

/// instruct-mode.js `formatInstructModePrompt` (L593-651): the line that
/// starts the character's reply in a one-character chat.
String _instructPrompt(Map<String, dynamic> instruct, MacroEngine macros) {
  final name = macros.env.char;
  final names = name.isNotEmpty && instruct['names_behavior'] == 'always';
  final output = stringField(instruct, 'output_sequence');
  final last = stringField(instruct, 'last_output_sequence');
  var sequence = last.isEmpty ? output : last;
  // ST's hack for Mistral: the space an output sequence ends with.
  final space = RegExp(r'\s$');
  final filler =
      names &&
          last.isNotEmpty &&
          space.hasMatch(output) &&
          !space.hasMatch(last)
      ? output.substring(output.length - 1)
      : '';
  if (instruct['macro'] == true) sequence = _sequence(macros, sequence, name);
  final separator = instruct['wrap'] == true ? '\n' : '';
  final text = names
      ? '$separator$sequence$separator$filler$name:'
      : '$separator$sequence';
  return '${separator.isEmpty ? text : text.replaceFirst(RegExp(r'\s+$'), '')}'
      '${names ? '' : separator}';
}

/// An instruct sequence with `macro` on: the speaker ([name], else
/// `System`) for `{{name}}`, then its macros. ST resolves the macros first;
/// here an unregistered `{{name}}` would be reported.
String _sequence(MacroEngine macros, String text, String name) => macros.render(
  text.replaceAll(
    RegExp(r'\{\{name\}\}', caseSensitive: false),
    name.isEmpty ? 'System' : name,
  ),
);
