import 'dart:convert';

import '../model/display_context.dart';
import '../mvu/mvu_data.dart';
import '../mvu/mvu_init.dart';
import '../mvu/mvu_service.dart';
import '../model/manuscript.dart';
import '../model/manuscript_presentation.dart';
import '../model/story.dart';
import '../st/macro_engine.dart';
import '../storage/story_repository.dart';
import '../st/variable_codec.dart';
import 'tavern_bridge.dart';

export '../st/variable_codec.dart';

/// The scenes of a branch as a chat: scene N is message N, the opening
/// scene's swipes are the card's greetings, and variables are the branch's
/// versioned variables at each scene.
final class BranchChatBackend implements TavernChatBackend {
  BranchChatBackend({
    required this.repository,
    required this.branchId,
    required this.context,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  static DateTime _utcNow() => DateTime.now().toUtc();

  final StoryRepository repository;
  final String branchId;
  final DisplayContext context;
  final DateTime Function() _clock;

  /// Text past this budget is left out of the snapshot for older scenes.
  static const maxSnapshotTextBytes = 1536 * 1024;

  MacroEngine _macros({
    Map<String, String> local = const {},
    Map<String, String> global = const {},
  }) => MacroEngine(
    values: context.macroValues,
    clock: _clock(),
    seed: 0,
    local: local,
    global: global,
  );

  List<String> renderedGreetings() => [
    for (final greeting in context.greetings) _macros().render(greeting),
  ];

  /// Scene text as a message: without the newline every document ends with.
  static String messageText(Scene scene) {
    final text = scene.content.text;
    return text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
  }

  @override
  Future<Map<String, dynamic>> snapshot(int messageId) async {
    final story = await repository.getStory(branchId);
    final scenes = story.scenes;
    final greetings = scenes.isEmpty ? const <String>[] : renderedGreetings();
    final latest = await repository.getBranchVariables(branchId);
    // Per-scene variables only for the scenes a page addresses by default:
    // the opening, its own and the latest. Each lookup projects the branch's
    // revisions, so this stays constant instead of growing with the story.
    final selected = <int>{0, messageId, scenes.length - 1};
    final perScene = <String, Map<String, dynamic>>{};
    for (final i in selected) {
      if (i < 0 || i >= scenes.length) continue;
      final variables = await repository.getBranchVariables(
        branchId,
        throughSceneId: scenes[i].id,
      );
      perScene['$i'] = decodeVariables(variables.local);
    }
    var budget = maxSnapshotTextBytes;
    final messages = <Map<String, dynamic>>[];
    for (var i = scenes.length - 1; i >= 0; i--) {
      final text = messageText(scenes[i]);
      final keep = selected.contains(i) || budget > 0;
      budget -= text.length;
      messages.add({
        'message_id': i,
        'name': context.charName.isEmpty ? story.novel.title : context.charName,
        'role': 'assistant',
        'is_hidden': false,
        'message': keep ? text : '',
        'truncated': !keep,
        'swipe_id': i == 0 && greetings.isNotEmpty
            ? context.greetingIndex.clamp(0, greetings.length - 1)
            : 0,
        'swipes': i == 0 && greetings.isNotEmpty
            ? [
                for (final (k, g) in greetings.indexed)
                  k == context.greetingIndex.clamp(0, greetings.length - 1)
                      ? text
                      : g,
              ]
            : [if (keep) text],
        'data': perScene['$i'] ?? const <String, dynamic>{},
        'extra': const <String, dynamic>{},
      });
    }
    return {
      'chat_id': branchId,
      'name1': context.userName,
      'name2': context.charName,
      'card': context.card,
      'messages': messages.reversed.toList(),
      'variables': {
        'chat': decodeVariables(latest.local),
        'global': decodeVariables(latest.global),
        'messages': perScene,
        'other': await _otherVariables(),
      },
      'version': 'sillydraft',
    };
  }

  Future<Map<String, dynamic>> _otherVariables() async =>
      (await repository.getSetting('htmlVariables/$branchId') ?? {})
          .cast<String, dynamic>();

  int _normalize(int id, int count) {
    final index = id < 0 ? count + id : id;
    if (index < 0 || index >= count) throw StoryNotFound('第 $id 楼场景');
    return index;
  }

  @override
  Future<void> setMessages(List<Map<String, dynamic>> changes) async {
    for (final change in changes) {
      final story = await repository.getStory(branchId);
      final id = change['message_id'];
      if (id is! num) throw const FormatException('缺少 message_id');
      final index = _normalize(id.toInt(), story.scenes.length);
      final scene = story.scenes[index];
      final swipe = change['swipe_id'];
      String? text = change['message'] is String
          ? change['message'] as String
          : null;
      if (text == null && swipe is num && index == 0) {
        final greetings = renderedGreetings();
        final swipes = change['swipes'] is List
            ? [
                for (final s in change['swipes'] as List)
                  if (s is String) s,
              ]
            : greetings;
        final k = swipe.toInt();
        if (k < 0 || k >= swipes.length) throw const FormatException('备用开场不存在');
        text = swipes[k];
      }
      if (text != null && text != messageText(scene)) {
        await repository.saveScene(
          branchId: branchId,
          sceneId: scene.id,
          expectedRevisionId: scene.revisionId,
          content: ManuscriptContent.plainText(text),
          reason: 'html-block',
        );
      }
      if (swipe is num && index == 0 && context.hasCard) {
        final profile = await repository.getSetting('writing/$branchId') ?? {};
        if (profile['greetingIndex'] != swipe.toInt()) {
          await repository.setSetting('writing/$branchId', {
            ...profile,
            'greetingIndex': swipe.toInt(),
          });
        }
      }
      if (change['data'] is Map) {
        await _write(
          scene.id,
          local: encodeVariables(
            (change['data'] as Map).cast<String, dynamic>(),
          ),
        );
      }
    }
  }

  @override
  Future<void> createMessages(
    List<Map<String, dynamic>> messages, {
    int? insertBefore,
  }) async {
    if (insertBefore != null) {
      throw const FormatException('SillyDraft 只能在正文末尾添加场景');
    }
    final story = await repository.getStory(branchId);
    final chapterId =
        story.chapters.lastOrNull?.id ??
        (await repository.createChapter(branchId: branchId, title: '第一章')).id;
    for (final message in messages) {
      final text = message['message'];
      if (text is! String) throw const FormatException('消息缺少 message 字段');
      await repository.createScene(
        branchId: branchId,
        chapterId: chapterId,
        title: message['role'] == 'user' ? '来自界面的输入' : '新场景',
        content: ManuscriptContent.plainText(text),
      );
    }
  }

  /// Where a variable store lives: `message` variables at the addressed
  /// scene; `chat` and `global` at the latest scene, which is what every
  /// read of them projects, so a page in an earlier scene sees its own
  /// writes and never overwrites that scene's recorded state.
  Future<Scene> _sceneFor(Map<String, dynamic> option, int messageId) async {
    final story = await repository.getStory(branchId);
    if (story.scenes.isEmpty) throw const StoryNotFound('场景');
    final raw = option['message_id'];
    final index = option['type'] == 'message' && raw is num
        ? _normalize(raw.toInt(), story.scenes.length)
        : story.scenes.length - 1;
    return story.scenes[index];
  }

  @override
  Future<Map<String, dynamic>> variables(
    Map<String, dynamic> option, {
    required int messageId,
  }) async {
    switch (option['type']) {
      case 'global':
        return decodeVariables(
          (await repository.getBranchVariables(branchId)).global,
        );
      case 'message':
        final scene = await _sceneFor(option, messageId);
        return decodeVariables(
          (await repository.getBranchVariables(
            branchId,
            throughSceneId: scene.id,
          )).local,
        );
      case 'chat' || null:
        return decodeVariables(
          (await repository.getBranchVariables(branchId)).local,
        );
      default:
        final other = await _otherVariables();
        final value = other[_otherKey(option)];
        return value is Map
            ? value.cast<String, dynamic>()
            : <String, dynamic>{};
    }
  }

  String _otherKey(Map<String, dynamic> option) => [
    option['type'],
    if (option['script_id'] != null) option['script_id'],
    if (option['extension_id'] != null) option['extension_id'],
  ].join(':');

  @override
  Future<void> replaceVariables(
    Map<String, dynamic> variables,
    Map<String, dynamic> option, {
    required int messageId,
  }) async {
    switch (option['type']) {
      case 'global':
        final scene = await _sceneFor(option, messageId);
        await _write(scene.id, global: encodeVariables(variables));
      case 'message' || 'chat' || null:
        final scene = await _sceneFor(option, messageId);
        await _write(scene.id, local: encodeVariables(variables));
      default:
        final other = await _otherVariables();
        await repository.setSetting('htmlVariables/$branchId', {
          ...other,
          _otherKey(option): variables,
        });
    }
  }

  Future<void> _write(
    String sceneId, {
    Map<String, String>? local,
    Map<String, String>? global,
  }) async {
    var next = local;
    if (next != null && !MvuData.presentIn(next)) {
      // Long stories only snapshot a few scenes' variables; a page writing
      // a table assembled from an empty snapshot must not erase the MVU
      // record. Pages replace it through `replaceMvuData`, which carries
      // `stat_data`.
      final current = await repository.getBranchVariables(
        branchId,
        throughSceneId: sceneId,
      );
      if (MvuData.presentIn(current.local)) {
        next = {
          for (final key in MvuData.keys) key: ?current.local[key],
          ...next,
        };
      }
    }
    await repository.patchBranchVariables(
      branchId: branchId,
      sceneId: sceneId,
      local: next,
      global: global,
    );
  }

  @override
  Future<String> substituteMacros(String text) async {
    final variables = await repository.getBranchVariables(branchId);
    return _macros(
      local: variables.local,
      global: variables.global,
    ).render(text);
  }

  @override
  Future<String> formatDisplayed(String text) async {
    final variables = await repository.getBranchVariables(branchId);
    final shown = ManuscriptPresentation.fromRules(
      ManuscriptContent.plainText(text),
      rules: context.rules,
      macros: _macros(local: variables.local, global: variables.global),
      strict: false,
    );
    return const HtmlEscape()
        .convert(shown.content.text.trimRight())
        .replaceAll('\n', '<br>');
  }

  @override
  Future<Map<String, dynamic>> mvuParseMessage(
    String message,
    Map<String, dynamic> data,
  ) async => parseMvuMessage(message, data, substitute: _macros().render);

  @override
  Future<Map<String, dynamic>?> mvuReloadInitVar(
    Map<String, dynamic> data,
  ) async {
    final service = MvuService(repository, clock: _clock);
    final record = MvuData.fromJson(data);
    final loaded = MvuInit.load(
      record,
      await service.initEntries(branchId),
      substitute: _macros().render,
    );
    if (!loaded) return null;
    MvuInit.finalizeSchema(record);
    if (!await service.schemaChecks(branchId)) {
      record.schema = MvuService.anySchema;
    }
    return {...data, ...record.toJson()};
  }
}

/// `Mvu.parseMessage` for any backend: the record in [data] (other keys
/// kept) with the commands of [message] applied.
Map<String, dynamic> parseMvuMessage(
  String message,
  Map<String, dynamic> data, {
  String Function(String)? substitute,
}) {
  final record = MvuData.fromJson(data);
  MvuUpdater.apply(message, record, substitute: substitute);
  return {...data, ...record.toJson()};
}

/// A card's greetings before a novel exists: one message whose swipes are
/// the greetings. Variables stay in memory until the novel is created.
final class PreviewChatBackend implements TavernChatBackend {
  PreviewChatBackend({
    required this.greetings,
    required this.greetingIndex,
    required this.context,
    this.openingText,
    this.onGreetingChanged,
    this.onOpeningEdited,
  });

  /// Rendered greetings, in card order.
  List<String> greetings;
  int greetingIndex;
  DisplayContext context;

  /// The opening as currently edited, when it differs from the greeting.
  String? openingText;
  final void Function(int index)? onGreetingChanged;
  final void Function(String text)? onOpeningEdited;
  final chatVariables = <String, dynamic>{};
  final globalVariables = <String, dynamic>{};
  final otherVariables = <String, Map<String, dynamic>>{};

  /// `[InitVar]` entries of the card, for `Mvu.reloadInitVar` before a
  /// novel exists.
  List<MvuInitEntry> initEntries = const [];

  String get _text => openingText ?? greetings[greetingIndex];

  @override
  Future<Map<String, dynamic>> snapshot(int messageId) async => {
    'chat_id': 'preview',
    'name1': context.userName,
    'name2': context.charName,
    'card': context.card,
    'messages': [
      {
        'message_id': 0,
        'name': context.charName,
        'role': 'assistant',
        'is_hidden': false,
        'message': _text,
        'swipe_id': greetingIndex,
        'swipes': [
          for (final (i, g) in greetings.indexed)
            i == greetingIndex ? _text : g,
        ],
        'data': chatVariables,
        'extra': const <String, dynamic>{},
      },
    ],
    'variables': {
      'chat': chatVariables,
      'global': globalVariables,
      'messages': {'0': chatVariables},
      'other': otherVariables,
    },
    'preview': true,
    'version': 'sillydraft',
  };

  @override
  Future<void> setMessages(List<Map<String, dynamic>> changes) async {
    for (final change in changes) {
      final swipe = change['swipe_id'];
      if (swipe is num) {
        final index = swipe.toInt();
        if (index < 0 || index >= greetings.length) {
          throw const FormatException('备用开场不存在');
        }
        greetingIndex = index;
        openingText = null;
        onGreetingChanged?.call(index);
      }
      if (change['message'] is String && change['message'] != _text) {
        openingText = change['message'] as String;
        onOpeningEdited?.call(openingText!);
      }
      if (change['data'] is Map) {
        chatVariables
          ..clear()
          ..addAll((change['data'] as Map).cast<String, dynamic>());
      }
    }
  }

  @override
  Future<void> createMessages(
    List<Map<String, dynamic>> messages, {
    int? insertBefore,
  }) async {
    throw const FormatException('创建小说后才能添加场景');
  }

  Map<String, dynamic> _store(Map<String, dynamic> option) =>
      switch (option['type']) {
        'global' => globalVariables,
        'chat' || 'message' || null => chatVariables,
        _ => otherVariables.putIfAbsent(
          [
            option['type'],
            if (option['script_id'] != null) option['script_id'],
            if (option['extension_id'] != null) option['extension_id'],
          ].join(':'),
          () => {},
        ),
      };

  @override
  Future<Map<String, dynamic>> variables(
    Map<String, dynamic> option, {
    required int messageId,
  }) async => Map<String, dynamic>.from(_store(option));

  @override
  Future<void> replaceVariables(
    Map<String, dynamic> variables,
    Map<String, dynamic> option, {
    required int messageId,
  }) async {
    _store(option)
      ..clear()
      ..addAll(variables);
  }

  MacroEngine _macros() => MacroEngine(
    values: context.macroValues,
    clock: DateTime.now().toUtc(),
    seed: 0,
    local: encodeVariables(chatVariables),
    global: encodeVariables(globalVariables),
  );

  @override
  Future<String> substituteMacros(String text) async => _macros().render(text);

  @override
  Future<Map<String, dynamic>> mvuParseMessage(
    String message,
    Map<String, dynamic> data,
  ) async => parseMvuMessage(message, data, substitute: _macros().render);

  @override
  Future<Map<String, dynamic>?> mvuReloadInitVar(
    Map<String, dynamic> data,
  ) async {
    final record = MvuData.fromJson(data);
    if (!MvuInit.load(record, initEntries, substitute: _macros().render)) {
      return null;
    }
    MvuInit.finalizeSchema(record);
    return {...data, ...record.toJson()};
  }

  @override
  Future<String> formatDisplayed(String text) async {
    final shown = ManuscriptPresentation.fromRules(
      ManuscriptContent.plainText(text),
      rules: context.rules,
      macros: _macros(),
      strict: false,
    );
    return const HtmlEscape()
        .convert(shown.content.text.trimRight())
        .replaceAll('\n', '<br>');
  }
}
