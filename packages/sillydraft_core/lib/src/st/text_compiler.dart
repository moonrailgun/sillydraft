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
  final context =
      parts['context']?.raw ??
      (preset.kind == PresetKind.context ? preset.raw : <String, dynamic>{});
  final instruct =
      parts['instruct']?.raw ??
      (preset.kind == PresetKind.instruct ? preset.raw : <String, dynamic>{});
  final system =
      parts['sysprompt']?.raw ??
      (preset.kind == PresetKind.systemPrompt
          ? preset.raw
          : <String, dynamic>{});
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
  var main = stringField(system, 'content');
  if (input.card?.systemPrompt.isNotEmpty == true) {
    main = input.card!.systemPrompt.replaceAll(
      RegExp(r'\{\{original\}\}', caseSensitive: false),
      main,
    );
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
    'char': input.card?.name ?? '旁白',
    'user': input.userName,
    'trim': '{{trim}}',
    'newline': '{{newline}}',
  };
  final template = stringField(
    context,
    'story_string',
    fallback:
        '{{#if system}}{{system}}\n{{/if}}{{#if wiBefore}}{{wiBefore}}\n{{/if}}'
        '{{#if description}}{{description}}\n{{/if}}{{#if personality}}{{personality}}\n{{/if}}'
        '{{#if scenario}}{{scenario}}\n{{/if}}{{#if wiAfter}}{{wiAfter}}\n{{/if}}'
        '{{#if persona}}{{persona}}\n{{/if}}{{trim}}',
  );
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
  if (instruct['skip_examples'] != true &&
      input.card?.examples.isNotEmpty == true) {
    final examples = _examples(input.card!.examples, macros, diagnostics);
    final exampleSeparator = macros.render(
      stringField(context, 'example_separator'),
    );
    if (exampleSeparator.isNotEmpty) out.write('$exampleSeparator\n');
    for (final example in examples) {
      final role = example.name == 'example_user'
          ? 'user'
          : example.name == 'example_assistant'
          ? 'assistant'
          : 'system';
      out.write(
        _formatTextMessage(
          PromptMessage(role, example.content),
          instruct,
          macros,
          first: false,
          last: false,
        ),
      );
    }
  }
  final start = macros.render(stringField(context, 'chat_start'));
  if (start.isNotEmpty) out.write('$start\n');
  var firstUser = true, firstAssistant = true;
  for (var i = 0; i < queue.length; i++) {
    final message = queue[i];
    final first = message.role == 'user'
        ? firstUser
        : message.role == 'assistant'
        ? firstAssistant
        : false;
    out.write(
      _formatTextMessage(
        message,
        instruct,
        macros,
        first: first,
        last: i == queue.length - 1,
      ),
    );
    if (message.role == 'user') firstUser = false;
    if (message.role == 'assistant') firstAssistant = false;
  }
  final postHistory = input.card?.postHistoryInstructions.isNotEmpty == true
      ? input.card!.postHistoryInstructions
      : stringField(system, 'post_history');
  if (postHistory.isNotEmpty) {
    out.write(
      _formatTextMessage(
        PromptMessage('system', macros.render(postHistory)),
        instruct,
        macros,
        first: false,
        last: true,
      ),
    );
  }
  if (input.generationType != 'continue') {
    var sequence = stringField(instruct, 'last_output_sequence');
    if (sequence.isEmpty) sequence = stringField(instruct, 'output_sequence');
    if (instruct['macro'] == true) {
      sequence = macros.render(
        sequence.replaceAll('{{name}}', macros.values['char']!),
      );
    }
    final includeNames = instruct['names_behavior'] == 'always';
    var tail = includeNames
        ? '$separator$sequence$separator${macros.values['char']}:'
        : '$separator$sequence';
    if (wrap) tail = tail.trimRight();
    out.write('$tail${includeNames ? '' : separator}');
  }
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
          ? input.userName
          : key.contains('system')
          ? 'System'
          : input.card?.name ?? '旁白';
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
  if (context['names_as_stop_strings'] == true) {
    stops.add('\n${input.userName}:');
    stops.add('\n${input.card?.name ?? '旁白'}:');
  }
  return (text: out.toString(), stops: stops.toList(), parameters: parameters);
}

String _formatTextMessage(
  PromptMessage message,
  Map<String, dynamic> instruct,
  MacroEngine macros, {
  required bool first,
  required bool last,
}) {
  if (instruct.isEmpty) {
    final name = message.role == 'user'
        ? macros.values['user']
        : message.role == 'assistant'
        ? macros.values['char']
        : 'System';
    return '$name: ${message.content}\n';
  }
  final type = message.role == 'system'
      ? (instruct['system_same_as_user'] == true ? 'input' : 'system')
      : message.role == 'user'
      ? 'input'
      : 'output';
  var prefix = stringField(instruct, '${type}_sequence');
  if (type != 'system') {
    final override = stringField(
      instruct,
      '${first
          ? 'first'
          : last
          ? 'last'
          : ''}_${type}_sequence',
    );
    if (override.isNotEmpty) prefix = override;
  }
  var suffix = stringField(instruct, '${type}_suffix');
  final wrap = instruct['wrap'] == true;
  final name = message.role == 'user'
      ? macros.values['user']!
      : message.role == 'assistant'
      ? macros.values['char']!
      : 'System';
  if (instruct['macro'] == true) {
    prefix = macros.render(prefix.replaceAll('{{name}}', name));
    suffix = macros.render(suffix.replaceAll('{{name}}', name));
  }
  if (suffix.isEmpty && wrap) suffix = '\n';
  final withName =
      message.role != 'system' && instruct['names_behavior'] == 'always';
  return [
    if (prefix.isNotEmpty) prefix,
    '${withName ? '$name: ' : ''}${message.content}$suffix',
  ].join(wrap ? '\n' : '');
}
