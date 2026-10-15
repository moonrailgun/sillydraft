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
  const PromptMessage(
    this.role,
    this.content, {
    this.source = '',
    this.name,
    this.sentAt,
  });
  final String role, content, source;
  final String? name;

  /// When a chat message was sent (ST `send_date`); not sent to the model.
  final DateTime? sentAt;
  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (name != null) 'name': name,
  };
}

final class ContextChapter {
  const ContextChapter({
    required this.branchId,
    required this.position,
    required this.chapterId,
    required this.revisionId,
    required this.content,
    this.accepted = true,
  });
  final String branchId, chapterId, revisionId, content;
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
    this.userName = '我',
    this.persona = '',
    String model = '',
    bool? isMobile,
    int? contextWindow,
    int? maxOutputTokens,
    this.generationType = 'normal',
    this.selectedOrderId,
    List<ContextChapter> history = const [],
    List<ScopedWorldBook> worldBooks = const [],
    Map<String, String> localVariables = const {},
    Map<String, String> globalVariables = const {},
    List<Map<String, dynamic>> globalRegex = const [],
    List<PromptMessage>? conversation,
  }) : env = MacroEnv.of(
         card: card?.raw,
         user: userName,
         persona: persona,
         preset: preset,
         model: model,
         isMobile: isMobile,
         // The request's limits, as WritingService checks them: the
         // connection's context window, and the response length the
         // preset asks for, else the connection's.
         maxContext: contextWindow,
         maxResponse: switch (_parameters(
           preset.parts['preset']?.parameters ?? preset.parameters,
         )['max_tokens']) {
           final num tokens => tokens,
           _ => maxOutputTokens,
         },
       ),
       history = List.unmodifiable(history),
       conversation = conversation == null
           ? null
           : List.unmodifiable(conversation),
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

  /// What the env macros read, the model the request goes to and its token
  /// limits included; a writing task stores it for its output and display
  /// stages.
  final MacroEnv env;
  final List<ContextChapter> history;

  /// A chat to use as `chatHistory` instead of story chapters and [brief], for
  /// the editing assistant. Its last user message is the current input.
  final List<PromptMessage>? conversation;
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
    Map<String, String> chatValues = const {},
    Map<String, String> outlets = const {},
  }) : messages = List.unmodifiable(messages),
       parameters = Map.unmodifiable(parameters),
       stopStrings = List.unmodifiable(stopStrings),
       trace = List.unmodifiable(trace),
       diagnostics = List.unmodifiable(diagnostics),
       localVariables = Map.unmodifiable(localVariables),
       globalVariables = Map.unmodifiable(globalVariables),
       chatValues = Map.unmodifiable(chatValues),
       outlets = Map.unmodifiable(outlets);
  final List<PromptMessage> messages;
  final String? completionText;
  final Map<String, dynamic> parameters;
  final List<String> stopStrings, trace;
  final List<CompatibilityDiagnostic> diagnostics;
  final Map<String, String> localVariables, globalVariables;

  /// The chat macros once the prompt is built, what the request's output
  /// stage reads (a writing task keeps them as `chatMacros`).
  final Map<String, String> chatValues;

  /// The world info outlets the prompt filled, what the request's output
  /// and display stages read (a writing task keeps them as `outlets`).
  final Map<String, String> outlets;
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
  /// ST 1.19.0 time-macros.js `getTimeSinceLastMessage`: going back from
  /// the latest message and skipping system ones, the first user message
  /// before it. Story chapters are all model messages, so a story has none.
  static DateTime? _idleSince(List<PromptMessage>? conversation) {
    var takeNext = false;
    for (final message in (conversation ?? const []).reversed) {
      if (message.role == 'system') continue;
      if (message.role == 'user' && takeNext) return message.sentAt;
      takeNext = true;
    }
    return null;
  }

  CompiledPrompt compile(PresetInput input) {
    final diagnostics = [...input.preset.diagnostics];
    final trace = <String>[
      'branch:${input.branchId}:through:${input.throughPosition}',
    ];
    // MVU's status-bar placeholder is display only: it never reaches the
    // model, neither through history nor through {{lastCharMessage}}.
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
                  ? ContextChapter(
                      branchId: s.branchId,
                      position: s.position,
                      chapterId: s.chapterId,
                      revisionId: s.revisionId,
                      content: stripMvuMarkup(s.content),
                      accepted: s.accepted,
                    )
                  : s,
            )
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    final card = input.card;
    final conversation = input.conversation;
    // ST's `chat` as stored: the chapters through the target, without MVU's
    // placeholder, then the brief once sent; or the editing conversation,
    // whose latest user message is the input as typed (its attached chapter
    // is prompt text, as ST keeps attachments out of `mes`).
    final chat = <PromptMessage>[
      if (conversation != null)
        for (final (i, m) in conversation.indexed)
          i == conversation.length - 1 && m.role == 'user'
              ? PromptMessage('user', input.brief)
              : m
      else
        for (final c in filtered) PromptMessage('assistant', c.content),
    ];
    final macros = MacroEngine(
      env: input.env,
      values: _chatValues(chat, input.generationType),
      clock: input.clock,
      idleSince: _idleSince(conversation),
      seed: input.randomSeed,
      local: input.localVariables,
      global: input.globalVariables,
    );
    final regex = RegexPipeline(
      global: input.globalRegex,
      preset: _rules(input.preset.raw['extensions']),
      card: _rules(card?.extensions),
    );
    // App-created editing instructions are the current user message. Editor
    // conversation, task logs, and unaccepted proposals are never an input here.
    String? sent;
    if (conversation == null &&
        (input.generationType != 'continue' || input.brief.isNotEmpty)) {
      // script.js `sendMessageAsUser`: the user input regex runs before the
      // message joins the chat, which keeps the result.
      sent = regex.apply(
        input.brief,
        placement: 1,
        stage: RegexStage.general,
        macros: macros,
        depth: 0,
      );
      chat.add(PromptMessage('user', sent));
      macros.values.addAll(_chatValues(chat, input.generationType));
    }
    final history = <PromptMessage>[];
    if (conversation != null) {
      trace.add('chat_history:conversation:${conversation.length}');
      for (final (i, message) in conversation.indexed) {
        // Same regex placements ST uses for chat: 1 user input, 2 AI output.
        final placement = message.role == 'user' ? 1 : 2;
        history.add(
          PromptMessage(
            message.role,
            regex.apply(
              message.content,
              placement: placement,
              stage: RegexStage.prompt,
              macros: macros,
              depth: conversation.length - 1 - i,
            ),
            source: message.source,
          ),
        );
      }
    }
    for (final (i, chapter)
        in (conversation == null ? filtered : const <ContextChapter>[])
            .indexed) {
      history.add(
        PromptMessage(
          'assistant',
          regex.apply(
            chapter.content,
            placement: 2,
            stage: RegexStage.prompt,
            macros: macros,
            depth: filtered.length - i,
          ),
          source: 'chapter:${chapter.chapterId}@${chapter.revisionId}',
        ),
      );
    }
    if (sent != null) {
      history.add(
        PromptMessage(
          'user',
          regex.apply(
            sent,
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
      // ST 1.19.0 script.js `Generate` takes these from
      // `getCharacterCardFields()`, the values of the env macros; the prompt
      // builders resolve their macros once more.
      'charDescription': macros.render('{{charDescription}}'),
      'charPersonality': macros.render('{{charPersonality}}'),
      'scenario': macros.render('{{charScenario}}'),
      'personaDescription': input.persona,
    };
    // script.js `Generate` L4664-4679: once world info is scanned and the
    // card fields above are read, `{{outlet::name}}` gives the outlet
    // entries of this request (world-info.js L5203-5258: highest order
    // first, each through the world info regex, empty ones left out); before
    // that, the previous request's, which SillyDraft does not keep, so none
    // (as on a chat's first request).
    final outlets = <String, List<String>>{};
    for (final activated in world.entries.reversed) {
      final name = activated.entry.outletName;
      if (activated.entry.position != 7 || name.isEmpty) continue;
      final content = regex.apply(
        activated.content,
        placement: 5,
        stage: RegexStage.prompt,
        macros: macros,
      );
      if (content.isNotEmpty) (outlets[name] ??= []).add(content);
    }
    macros.outlets.addAll({
      for (final MapEntry(:key, :value) in outlets.entries)
        key: value.join('\n'),
    });
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
        // openai.js `preparePromptsForChatCompletion`: a non-empty format.
        if (markers[entry.key]!.isNotEmpty &&
            raw[entry.value] is String &&
            (raw[entry.value] as String).isNotEmpty) {
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
        content = macros.render(content);
        // openai.js `preparePromptsForChatCompletion`: the card's main
        // prompt or post-history override (its env value, non-empty)
        // replaces the resolved prompt and is resolved again with that as
        // `original`.
        final override = switch (prompt.identifier) {
          'main' => '{{charPrompt}}',
          'jailbreak' => '{{charInstruction}}',
          _ => null,
        };
        if (override != null && !prompt.forbidOverrides) {
          final text = macros.render(override);
          if (text.isNotEmpty) {
            content = macros.render(text, original: content);
            trace.add('card_override:${prompt.identifier}');
          }
        }
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
      chatValues: {
        ..._chatValues(chat, input.generationType),
        'firstincludedmessageid': firstIncluded(
          chat.length,
          text == null ? [for (final m in messages) m.role] : null,
          input.generationType,
        ),
      },
      outlets: macros.outlets,
    );
  }

  /// ST 1.19.0 (06bde939…) chat-macros.js over [chat], and state-macros.js
  /// `lastGenerationType` ([type] started this request). No message is a
  /// swipe in progress; an assistant message has one swipe, as every ST
  /// reply (script.js `saveReply`), the others none. The reader shows a chat
  /// from its first message (`firstDisplayedMessageId`). What the previous
  /// request had in context (`chat_metadata.lastInContextMessageId`) is not
  /// kept, so `firstIncludedMessageId` is empty, as before a chat's first
  /// request.
  static Map<String, String> _chatValues(
    List<PromptMessage> chat,
    String type,
  ) {
    String last(bool Function(PromptMessage m) test) =>
        chat.lastWhere(test, orElse: () => const PromptMessage('', '')).content;
    final id = chat.isEmpty ? '' : '${chat.length - 1}';
    final swipes = chat.lastOrNull?.role == 'assistant' ? '1' : '';
    return {
      'lastmessageid': id,
      'lastmessage': chat.lastOrNull?.content ?? '',
      'lastusermessage': last((m) => m.role == 'user'),
      'lastcharmessage': last((m) => m.role != 'user' && m.role != 'system'),
      'allchatrange': chat.isEmpty ? '' : '0-$id',
      'lastswipeid': swipes,
      'currentswipeid': swipes,
      'firstincludedmessageid': '',
      'firstdisplayedmessageid': chat.isEmpty ? '' : '0',
      'lastgenerationtype': type,
    };
  }

  /// script.js `setInContextMessages`, run once a prompt is built: the id
  /// of the first of [chat] messages in it, from how many it holds — a
  /// chat completion's user and assistant messages ([roles]; openai.js
  /// `openai_messages_count`), else all of them, as SillyDraft never drops
  /// history.
  static String firstIncluded(int chat, List<String>? roles, String type) {
    var count = roles == null
        ? chat
        : roles.where(const {'user', 'assistant', 'tool'}.contains).length;
    if (const {'swipe', 'regenerate', 'continue'}.contains(type)) count++;
    return '${(chat - count).clamp(0, chat)}';
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
  // ST 1.19.0 text presets: preset-manager.js L744-747 saves the response
  // length as `genamt` and the context size as `max_length`, which script.js
  // `setGenerationParamsFromPreset` (L8121-8136) reads back. NovelAI's own
  // presets have no `genamt`: `max_length` is the response length and
  // `max_context` the context size (nai-settings.js `loadNovelPreset`
  // L178-185). Context sizes stay unsent: requests use the connection's
  // context window, as for `openai_max_context`.
  final novel =
      !parameters.containsKey('genamt') &&
      parameters.containsKey('max_context');
  final aliases = {
    'temp': 'temperature',
    'openai_max_tokens': 'max_tokens',
    'genamt': 'max_tokens',
    if (novel) 'max_length': 'max_tokens',
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
  final user = macros.env.user, character = macros.env.char;
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
