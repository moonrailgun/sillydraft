import 'dart:convert';

import 'card_importer.dart';
import 'import_types.dart';
import '../mvu/mvu_data.dart';
import 'macro_engine.dart';
import 'preset_importer.dart';
import 'regex_pipeline.dart';
import 'template_engine.dart';
import 'world_book_engine.dart';

part 'text_compiler.dart';

final class PromptMessage {
  const PromptMessage(this.role, this.content, {this.source = '', this.name});
  final String role, content, source;
  final String? name;
  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (name != null) 'name': name,
  };
}

final class ContextScene {
  const ContextScene({
    required this.branchId,
    required this.position,
    required this.sceneId,
    required this.revisionId,
    required this.content,
    this.accepted = true,
  });
  final String branchId, sceneId, revisionId, content;
  final int position;
  final bool accepted;
}

final class PresetInput {
  PresetInput({
    required this.preset,
    required this.branchId,
    required this.throughPosition,
    required this.brief,
    required this.clock,
    required this.randomSeed,
    this.card,
    this.userName = '主角',
    this.persona = '',
    this.generationType = 'normal',
    this.selectedOrderId,
    List<ContextScene> history = const [],
    List<ScopedWorldBook> worldBooks = const [],
    Map<String, String> localVariables = const {},
    Map<String, String> globalVariables = const {},
    List<Map<String, dynamic>> globalRegex = const [],
  }) : history = List.unmodifiable(history),
       worldBooks = List.unmodifiable(worldBooks),
       localVariables = Map.unmodifiable(localVariables),
       globalVariables = Map.unmodifiable(globalVariables),
       _globalRegex = jsonEncode(globalRegex);
  final ImportedPreset preset;
  final String branchId, brief, userName, persona, generationType;
  final int throughPosition, randomSeed;
  final int? selectedOrderId;
  final DateTime clock;
  final CharacterCard? card;
  final List<ContextScene> history;
  final List<ScopedWorldBook> worldBooks;
  final Map<String, String> localVariables, globalVariables;
  final String _globalRegex;
  List<Map<String, dynamic>> get globalRegex =>
      (jsonDecode(_globalRegex) as List).cast<Map<String, dynamic>>();
}

final class CompiledPrompt {
  CompiledPrompt({
    required List<PromptMessage> messages,
    this.completionText,
    required Map<String, dynamic> parameters,
    required List<String> stopStrings,
    required List<String> trace,
    required List<CompatibilityDiagnostic> diagnostics,
    required Map<String, String> localVariables,
    required Map<String, String> globalVariables,
  }) : messages = List.unmodifiable(messages),
       parameters = Map.unmodifiable(parameters),
       stopStrings = List.unmodifiable(stopStrings),
       trace = List.unmodifiable(trace),
       diagnostics = List.unmodifiable(diagnostics),
       localVariables = Map.unmodifiable(localVariables),
       globalVariables = Map.unmodifiable(globalVariables);
  final List<PromptMessage> messages;
  final String? completionText;
  final Map<String, dynamic> parameters;
  final List<String> stopStrings, trace;
  final List<CompatibilityDiagnostic> diagnostics;
  final Map<String, String> localVariables, globalVariables;
  bool get canRun =>
      !diagnostics.any((d) => d.severity == DiagnosticSeverity.error);
  int get estimatedTokens =>
      estimateTokens(
        completionText ?? messages.map((m) => m.content).join('\n'),
      ) +
      messages.length * 4;
  Map<String, dynamic> toJson() => {
    'messages': messages.map((m) => m.toJson()).toList(),
    'completionText': completionText,
    'parameters': parameters,
    'stop': stopStrings,
    'trace': trace,
    'diagnostics': diagnostics.map((d) => d.toJson()).toList(),
    'localVariables': localVariables,
    'globalVariables': globalVariables,
    'estimatedTokens': estimatedTokens,
  };
}

final class PromptCompiler {
  CompiledPrompt compile(PresetInput input) {
    final diagnostics = [...input.preset.diagnostics];
    final trace = <String>[
      'branch:${input.branchId}:through:${input.throughPosition}',
    ];
    // MVU's status-bar placeholder is display only: it never reaches the
    // model, neither through history nor through {{lastMessage}}.
    final filtered =
        input.history
            .where(
              (s) =>
                  s.accepted &&
                  s.branchId == input.branchId &&
                  s.position <= input.throughPosition,
            )
            .map(
              (s) => hasMvuMarkup(s.content)
                  ? ContextScene(
                      branchId: s.branchId,
                      position: s.position,
                      sceneId: s.sceneId,
                      revisionId: s.revisionId,
                      content: stripMvuMarkup(s.content),
                      accepted: s.accepted,
                    )
                  : s,
            )
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final card = input.card;
    final macros = MacroEngine(
      values: {
        'char': card?.name ?? '旁白',
        'user': input.userName,
        'charname': card?.name ?? '旁白',
        'description': card?.description ?? '',
        'personality': card?.personality ?? '',
        'scenario': card?.scenario ?? '',
        'persona': input.persona,
        'mesexamples': card?.examples ?? '',
        'input': input.brief,
        'lastmessage': filtered.lastOrNull?.content ?? '',
        'lastusermessage': input.brief,
        'lastcharmessage': filtered.lastOrNull?.content ?? '',
        'charprompt': card?.systemPrompt ?? '',
        'charjailbreak': card?.postHistoryInstructions ?? '',
        'original': '',
      },
      clock: input.clock,
      seed: input.randomSeed,
      local: input.localVariables,
      global: input.globalVariables,
    );
    final regex = RegexPipeline(
      global: input.globalRegex,
      preset: _rules(input.preset.raw['extensions']),
      card: _rules(card?.extensions),
    );
    final history = <PromptMessage>[];
    for (final (i, scene) in filtered.indexed) {
      history.add(
        PromptMessage(
          'assistant',
          regex.apply(
            scene.content,
            placement: 2,
            stage: RegexStage.prompt,
            macros: macros,
            depth: filtered.length - i,
          ),
          source: 'scene:${scene.sceneId}@${scene.revisionId}',
        ),
      );
    }
    // App-created editing instructions are the current user message. Editor
    // conversation, task logs, and unaccepted proposals are never an input here.
    if (input.generationType != 'continue' || input.brief.isNotEmpty) {
      final original = regex.apply(
        input.brief,
        placement: 1,
        stage: RegexStage.general,
        macros: macros,
        depth: 0,
      );
      history.add(
        PromptMessage(
          'user',
          regex.apply(
            original,
            placement: 1,
            stage: RegexStage.prompt,
            macros: macros,
            depth: 0,
          ),
          source: 'writing-brief',
        ),
      );
    }
    final world = WorldBookEngine().activate(
      [
        if (card?.worldBook != null) ScopedWorldBook(card!.worldBook!),
        ...input.worldBooks,
      ],
      branchId: input.branchId,
      throughPosition: input.throughPosition,
      messages: history.map((m) => m.content).toList(),
      macros: macros,
      seed: input.randomSeed,
    );
    diagnostics.addAll(world.diagnostics);
    final markers = <String, String>{
      'worldInfoBefore': regex.apply(
        world.before,
        placement: 5,
        stage: RegexStage.prompt,
        macros: macros,
      ),
      'worldInfoAfter': regex.apply(
        world.after,
        placement: 5,
        stage: RegexStage.prompt,
        macros: macros,
      ),
      'charDescription': card?.description ?? '',
      'charPersonality': card?.personality ?? '',
      'scenario': card?.scenario ?? '',
      'personaDescription': input.persona,
    };
    var messages = <PromptMessage>[];
    String? text;
    final stops = <String>[];
    Map<String, dynamic> parameters;
    if ([PresetKind.chat, PresetKind.promptPack].contains(input.preset.kind)) {
      final raw = input.preset.raw;
      for (final entry in {
        'charPersonality': 'personality_format',
        'scenario': 'scenario_format',
      }.entries) {
        if (markers[entry.key]!.isNotEmpty && raw[entry.value] is String) {
          markers[entry.key] = raw[entry.value] as String;
        }
      }
      if (raw['wi_format'] is String) {
        for (final id in ['worldInfoBefore', 'worldInfoAfter']) {
          if (markers[id]!.isNotEmpty) {
            markers[id] = (raw['wi_format'] as String).replaceAll(
              '{0}',
              markers[id]!,
            );
          }
        }
      }
      final order = input.preset.selectOrder(
        characterId: input.selectedOrderId,
      );
      trace.add(
        'prompt_order:${input.selectedOrderId ?? (input.preset.kind == PresetKind.promptPack ? 'flat' : 100001)}',
      );
      final injections = <_Injection>[];
      final compiled = <String, List<PromptMessage>>{};
      final byId = {for (final p in input.preset.prompts) p.identifier: p};
      for (final item in order) {
        if (!item.enabled) {
          trace.add('disabled:${item.identifier}');
          continue;
        }
        final prompt = byId[item.identifier];
        if (prompt == null) continue;
        if (prompt.triggers.isNotEmpty &&
            !prompt.triggers.contains(input.generationType)) {
          continue;
        }
        if (prompt.identifier == 'chatHistory') continue;
        if (prompt.identifier == 'dialogueExamples') {
          compiled[prompt.identifier] = _examples(
            card?.examples ?? '',
            macros,
            diagnostics,
          );
          continue;
        }
        var content = prompt.marker
            ? markers[prompt.identifier] ?? ''
            : prompt.content;
        if (prompt.marker && !markers.containsKey(prompt.identifier)) {
          diagnostics.add(
            CompatibilityDiagnostic(
              'unknown_marker',
              '未支持标记：${prompt.identifier}',
              severity: DiagnosticSeverity.error,
            ),
          );
        }
        final override = prompt.identifier == 'main'
            ? card?.systemPrompt
            : prompt.identifier == 'jailbreak'
            ? card?.postHistoryInstructions
            : null;
        if (!prompt.forbidOverrides &&
            override != null &&
            override.isNotEmpty) {
          content = override.replaceAll(
            RegExp(r'\{\{original\}\}', caseSensitive: false),
            content,
          );
          trace.add('card_override:${prompt.identifier}');
        }
        content = macros.render(content);
        if (content.isEmpty) continue;
        final message = PromptMessage(
          prompt.role,
          content,
          source: 'prompt:${prompt.identifier}',
        );
        if (prompt.injectionPosition == 1) {
          injections.add(_Injection(message, prompt.depth, prompt.order));
        } else if (prompt.injectionPosition == 0) {
          compiled[prompt.identifier] = [message];
        } else {
          diagnostics.add(
            CompatibilityDiagnostic(
              'injection_position',
              '不支持的注入位置：${prompt.injectionPosition}',
              severity: DiagnosticSeverity.error,
            ),
          );
        }
      }
      for (final entry in world.entries.where((e) => e.entry.position == 4)) {
        final role = [
          'system',
          'user',
          'assistant',
        ][entry.entry.role.clamp(0, 2)];
        injections.add(
          _Injection(
            PromptMessage(
              role,
              entry.content,
              source: 'world:${entry.entry.id}',
            ),
            entry.entry.depth,
            entry.entry.order,
          ),
        );
      }
      final injectedHistory = _inject(history, injections);
      final newChat = stringField(raw, 'new_chat_prompt');
      if (newChat.isNotEmpty) {
        injectedHistory.insert(
          0,
          PromptMessage(
            'system',
            macros.render(newChat),
            source: 'new_chat_prompt',
          ),
        );
      }
      for (final item in order.where((i) => i.enabled)) {
        final prompt = byId[item.identifier];
        if (prompt == null ||
            (prompt.triggers.isNotEmpty &&
                !prompt.triggers.contains(input.generationType))) {
          continue;
        }
        if (item.identifier == 'chatHistory') {
          messages.addAll(injectedHistory);
        } else {
          messages.addAll(compiled[item.identifier] ?? []);
        }
      }
      if (injections.isNotEmpty &&
          !order.any((p) => p.enabled && p.identifier == 'chatHistory')) {
        diagnostics.add(
          const CompatibilityDiagnostic(
            'injection_without_history',
            '深度注入需要启用故事历史',
            severity: DiagnosticSeverity.error,
          ),
        );
      }
      parameters = _parameters(input.preset.parameters);
      if (raw['squash_system_messages'] == true) {
        final merged = <PromptMessage>[];
        for (final message in messages) {
          if (message.role == 'system' &&
              message.name == null &&
              merged.lastOrNull?.role == 'system' &&
              merged.last.name == null) {
            final previous = merged.removeLast();
            merged.add(
              PromptMessage(
                'system',
                '${previous.content}\n${message.content}',
                source: '${previous.source},${message.source}',
              ),
            );
          } else {
            merged.add(message);
          }
        }
        messages = merged;
      }
    } else {
      final result = _compileText(
        input,
        macros,
        history,
        markers,
        world,
        diagnostics,
      );
      text = result.text;
      stops.addAll(result.stops);
      parameters = result.parameters;
      trace.add('text_completion:${input.preset.kind.name}');
    }
    diagnostics.addAll([...macros.diagnostics, ...regex.diagnostics]);
    diagnostics.add(
      const CompatibilityDiagnostic(
        'estimated_tokens',
        '上下文预算使用估算值，未绑定模型 tokenizer',
        severity: DiagnosticSeverity.info,
      ),
    );
    return CompiledPrompt(
      messages: messages,
      completionText: text,
      parameters: parameters,
      stopStrings: stops,
      trace: trace,
      diagnostics: diagnostics,
      localVariables: macros.local,
      globalVariables: macros.global,
    );
  }
}

List<Map<String, dynamic>> _rules(Object? extensions) {
  if (extensions is! Map<String, dynamic>) return [];
  final rules = extensions['regex_scripts'];
  if (rules is! List) return [];
  return rules.map((r) => jsonObject(r, 'regex_scripts')).toList();
}

final class _Injection {
  const _Injection(this.message, this.depth, this.order);
  final PromptMessage message;
  final int depth, order;
}

List<PromptMessage> _inject(
  List<PromptMessage> history,
  List<_Injection> injections,
) {
  final reversed = history.reversed.toList();
  var inserted = 0;
  final depths =
      injections.map((i) => i.depth).where((d) => d >= 0).toSet().toList()
        ..sort();
  for (final depth in depths) {
    final items = injections.where((i) => i.depth == depth).toList();
    final orders = items.map((i) => i.order).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final groups = <PromptMessage>[];
    for (final order in orders) {
      for (final role in ['system', 'user', 'assistant']) {
        final group = items
            .where((i) => i.order == order && i.message.role == role)
            .map((i) => i.message.content)
            .join('\n')
            .trim();
        if (group.isNotEmpty) {
          groups.add(
            PromptMessage(
              role,
              group,
              source: 'injection:depth=$depth:order=$order',
            ),
          );
        }
      }
    }
    reversed.insertAll((depth + inserted).clamp(0, reversed.length), groups);
    inserted += groups.length;
  }
  return reversed.reversed.toList();
}

Map<String, dynamic> _parameters(Map<String, dynamic> parameters) {
  const aliases = {
    'temp': 'temperature',
    'openai_max_tokens': 'max_tokens',
    'max_length': 'max_tokens',
    'rep_pen': 'repetition_penalty',
    'freq_pen': 'frequency_penalty',
    'presence_pen': 'presence_penalty',
  };
  return {for (final e in parameters.entries) aliases[e.key] ?? e.key: e.value};
}

List<PromptMessage> _examples(
  String text,
  MacroEngine macros,
  List<CompatibilityDiagnostic> diagnostics,
) {
  if (text.trim().isEmpty) return [];
  final rendered = macros.render(text);
  final user = macros.values['user']!, character = macros.values['char']!;
  final pattern = RegExp(
    '^(?:${RegExp.escape(user)}|${RegExp.escape(character)}):',
    multiLine: true,
  );
  final matches = pattern.allMatches(rendered).toList();
  if (matches.isEmpty) {
    diagnostics.add(
      const CompatibilityDiagnostic(
        'example_format',
        '对话示例没有可识别的人物标签，作为文风参考文本使用',
      ),
    );
    return [PromptMessage('system', rendered, source: 'dialogueExamples')];
  }
  return [
    for (var i = 0; i < matches.length; i++)
      PromptMessage(
        'system',
        rendered
            .substring(
              matches[i].end,
              i + 1 < matches.length ? matches[i + 1].start : rendered.length,
            )
            .replaceAll('<START>', '')
            .trim(),
        source: 'dialogueExamples',
        name: matches[i].group(0) == '$user:'
            ? 'example_user'
            : 'example_assistant',
      ),
  ];
}
