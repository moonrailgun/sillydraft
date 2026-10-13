import 'dart:convert';

/// A page's view of the story, as 酒馆助手 shows a chat to its iframes.
///
/// Implementations map SillyTavern's chat onto something else: the chapters of
/// a branch, or the greetings of a card not yet turned into a novel.
abstract interface class TavernChatBackend {
  /// The `window.__SD_STATE` object for a block hosted in message
  /// [messageId]: messages, swipes, variables, names and card data.
  Future<Map<String, dynamic>> snapshot(int messageId);

  /// Applies `setChatMessages` changes: a new text, a swipe choice, or
  /// message variables.
  Future<void> setMessages(List<Map<String, dynamic>> changes);

  /// Appends messages as `createChatMessages` does.
  Future<void> createMessages(
    List<Map<String, dynamic>> messages, {
    int? insertBefore,
  });

  /// Variables of one store: `chat`, `global`, `message` or another type.
  Future<Map<String, dynamic>> variables(
    Map<String, dynamic> option, {
    required int messageId,
  });

  Future<void> replaceVariables(
    Map<String, dynamic> variables,
    Map<String, dynamic> option, {
    required int messageId,
  });

  Future<String> substituteMacros(String text);

  /// Text as the reader would show it: macros, then display regex.
  Future<String> formatDisplayed(String text);

  /// `Mvu.parseMessage`: [data] with the update commands of [message]
  /// applied (MVU's `stat_data`/`display_data`/`delta_data`/`schema`).
  Future<Map<String, dynamic>> mvuParseMessage(
    String message,
    Map<String, dynamic> data,
  );

  /// `Mvu.reloadInitVar`: [data] with the `[InitVar]` entries of books not
  /// yet loaded merged in, or null when nothing was loaded.
  Future<Map<String, dynamic>?> mvuReloadInitVar(Map<String, dynamic> data);
}

/// What a page asked the author to do next.
final class TavernWritingRequest {
  const TavernWritingRequest({
    required this.brief,
    this.rewriteMessageId,
    this.triggered = false,
    this.continueNextChapter = false,
  });

  /// Text from `/send`, `/sys`, `/sendas` and the like.
  final String brief;

  /// A message the page removed with `/cut`; the request rewrites that
  /// chapter instead of appending after the last one.
  final int? rewriteMessageId;

  /// Whether `/trigger` or `/continue` asked for generation.
  final bool triggered;

  /// Composer input maps to the reader's direct next-chapter workflow.
  final bool continueNextChapter;
}

/// Effects a page cannot have by itself.
abstract interface class TavernHostActions {
  void toast(String severity, String message, {String title = ''});
  Future<void> requestWriting(TavernWritingRequest request);

  /// Delivers `eventEmit` to the other blocks on the page.
  void broadcast(String event, List<Object?> args, {Object? source});
  void log(String level, String message);
}

/// Serves one HTML block's calls to the host.
final class TavernBridge {
  TavernBridge({
    required this.backend,
    required this.actions,
    required this.messageId,
    this.blockIndex = 0,
    this.maxMessageBytes = 1 << 20,
  });

  final TavernChatBackend backend;
  final TavernHostActions actions;

  /// Index of the message (chapter) hosting the block.
  final int messageId;
  final int blockIndex;
  final int maxMessageBytes;

  /// 酒馆助手's `TH-message--楼层号--序号`.
  String get iframeName => 'TH-message--$messageId--$blockIndex';

  Future<Map<String, dynamic>> state() async => {
    ...await backend.snapshot(messageId),
    'message_id': messageId,
    'iframe_name': iframeName,
  };

  /// Handles one `SillyDraftBridge` message and says what to resolve.
  Future<({int id, bool ok, Object? payload})> handleMessage(String raw) async {
    if (raw.length > maxMessageBytes) {
      return (id: 0, ok: false, payload: '桥接消息过大');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return (id: 0, ok: false, payload: '桥接消息不是 JSON');
    }
    if (decoded is! Map<String, dynamic> || decoded['id'] is! int) {
      return (id: 0, ok: false, payload: '桥接消息格式无效');
    }
    final id = decoded['id'] as int;
    final method = decoded['method'], args = decoded['args'];
    if (method is! String || args is! List) {
      return (id: id, ok: false, payload: '桥接消息格式无效');
    }
    try {
      return (id: id, ok: true, payload: await handle(method, args));
    } catch (error) {
      return (id: id, ok: false, payload: error.toString());
    }
  }

  Future<Object?> handle(String method, List<Object?> args) async {
    switch (method) {
      case 'setChatMessages':
        await backend.setMessages(_maps(args.elementAtOrNull(0), 'changes'));
        return null;
      case 'createChatMessages':
        final option = _map(args.elementAtOrNull(1));
        final before = option['insert_before'] ?? option['insert_at'];
        await backend.createMessages(
          _maps(args.elementAtOrNull(0), 'messages'),
          insertBefore: before is num ? before.toInt() : null,
        );
        return null;
      case 'deleteChatMessages':
        throw StateError(
          'SillyDraft 不允许界面删除正文章节；要替换本章，请使用 /cut 楼层号 | /trigger 发起改写。',
        );
      case 'replaceVariables':
        await backend.replaceVariables(
          _map(args.elementAtOrNull(0)),
          _map(args.elementAtOrNull(1)),
          messageId: messageId,
        );
        return null;
      case 'triggerSlash':
        return runSlash(_string(args.elementAtOrNull(0)));
      case 'continueWriting':
        final text = args.elementAtOrNull(0);
        if (text is! String) throw ArgumentError('续写要求必须是文本');
        if (text.trim().isNotEmpty) {
          await actions.requestWriting(
            TavernWritingRequest(brief: text, continueNextChapter: true),
          );
        }
        return null;
      case 'toast':
        actions.toast(
          _string(args.elementAtOrNull(0), fallback: 'info'),
          _string(args.elementAtOrNull(1)),
          title: _string(args.elementAtOrNull(2)),
        );
        return null;
      case 'eventEmit':
        actions.broadcast(
          _string(args.elementAtOrNull(0)),
          args.elementAtOrNull(1) is List
              ? List<Object?>.from(args[1] as List)
              : const [],
          source: this,
        );
        return null;
      case 'log':
        actions.log(
          _string(args.elementAtOrNull(0), fallback: 'info'),
          _string(args.elementAtOrNull(1)),
        );
        return null;
      case 'formatAsDisplayedMessage':
        return backend.formatDisplayed(_string(args.elementAtOrNull(0)));
      case 'mvuParseMessage':
        return backend.mvuParseMessage(
          _string(args.elementAtOrNull(0)),
          _map(args.elementAtOrNull(1)),
        );
      case 'mvuReloadInitVar':
        return backend.mvuReloadInitVar(_map(args.elementAtOrNull(0)));
      default:
        throw ArgumentError('未知的桥接方法：$method');
    }
  }

  /// Runs a slash pipeline such as `/send 开启仙途 | /trigger`, returning
  /// the last pipe value. Message-sending commands collect a writing
  /// request handed to the host at the end.
  Future<String> runSlash(String command) async {
    final brief = <String>[];
    int? rewrite;
    var triggered = false, aborted = false, input = false;
    var pipe = '';
    for (final segment in _splitPipeline(command)) {
      if (aborted) break;
      final parsed = _parseCommand(segment, pipe);
      if (parsed == null) {
        throw FormatException('不是 Slash 命令：${segment.trim()}');
      }
      final (name, named, text) = parsed;
      switch (name) {
        case 'send' ||
            'sys' ||
            'sendas' ||
            'comment' ||
            'impersonate' ||
            'sendsystem':
          if (text.isNotEmpty) {
            brief.add(
              name == 'sendas' && named['name'] != null
                  ? '${named['name']}：$text'
                  : text,
            );
          }
          pipe = '';
        case 'setinput':
          // ST 1.19.0 setInputCallback fills #send_textarea and returns text.
          // SillyDraft maps that composer operation to writing the next chapter.
          input = true;
          if (text.isNotEmpty) brief.add(text);
          pipe = text;
        case 'trigger' || 'continue':
          triggered = true;
          pipe = '';
        case 'cut':
          final target = int.tryParse(text.split('-').first.trim());
          if (target == null) throw const FormatException('/cut 需要楼层号');
          rewrite = target;
          pipe = '';
        case 'echo':
          actions.toast(
            named['severity'] ?? 'info',
            text,
            title: named['title'] ?? '',
          );
          pipe = text;
        case 'pass' || 'let' || 'var':
          pipe = text;
        case 'setvar' || 'setglobalvar':
          final key = named['key'] ?? '';
          if (key.isEmpty) throw FormatException('/$name 需要 key=变量名');
          pipe = await _assign(name.contains('global'), key, text);
        case 'getvar' || 'getglobalvar':
          pipe = await _read(name.contains('global'), named['key'] ?? text);
        case 'addvar' || 'addglobalvar':
          final key = named['key'] ?? '';
          final current = await _read(name.contains('global'), key);
          final a = num.tryParse(current), b = num.tryParse(text);
          pipe = await _assign(
            name.contains('global'),
            key,
            a != null && b != null ? _number(a + b) : '$current$text',
          );
        case 'incvar' || 'decvar' || 'incglobalvar' || 'decglobalvar':
          final key = named['key'] ?? text;
          final current =
              num.tryParse(await _read(name.contains('global'), key)) ?? 0;
          pipe = await _assign(
            name.contains('global'),
            key,
            _number(name.startsWith('inc') ? current + 1 : current - 1),
          );
        case 'flushvar' || 'flushglobalvar':
          final key = named['key'] ?? text;
          final global = name.contains('global');
          final store = await backend.variables({
            'type': global ? 'global' : 'chat',
          }, messageId: messageId);
          store.remove(key);
          await backend.replaceVariables(store, {
            'type': global ? 'global' : 'chat',
          }, messageId: messageId);
          pipe = '';
        case 'abort':
          aborted = true;
        case 'delay' ||
            'sleep' ||
            'wait' ||
            'hide' ||
            'unhide' ||
            'flushinject' ||
            'inject' ||
            'listinjects' ||
            'setinput:' ||
            'lastmessage':
          pipe = '';
        case 'gen' || 'genraw' || 'run' || 'qr' || 'eval' || 'exec':
          throw FormatException(
            'SillyDraft 不支持 /$name，请改用 /send 或 /trigger 发起写作请求。',
          );
        default:
          throw FormatException('未支持的 Slash 命令：/$name');
      }
    }
    if (brief.isNotEmpty || triggered || rewrite != null) {
      await actions.requestWriting(
        TavernWritingRequest(
          brief: brief.join('\n\n'),
          rewriteMessageId: rewrite,
          triggered: triggered,
          continueNextChapter: input && rewrite == null,
        ),
      );
    }
    return pipe;
  }

  Future<String> _assign(bool global, String key, String value) async {
    final option = {'type': global ? 'global' : 'chat'};
    final store = await backend.variables(option, messageId: messageId);
    store[key] = value;
    await backend.replaceVariables(store, option, messageId: messageId);
    return value;
  }

  Future<String> _read(bool global, String key) async {
    final store = await backend.variables({
      'type': global ? 'global' : 'chat',
    }, messageId: messageId);
    final value = store[key];
    return value == null
        ? ''
        : value is String
        ? value
        : jsonEncode(value);
  }

  static String _number(num value) =>
      value == value.truncate() ? value.toInt().toString() : value.toString();

  /// Splits on unescaped `|` outside double quotes.
  static List<String> _splitPipeline(String command) {
    final parts = <String>[];
    final current = StringBuffer();
    var quoted = false;
    for (var i = 0; i < command.length; i++) {
      final char = command[i];
      if (char == r'\' && i + 1 < command.length && command[i + 1] == '|') {
        current.write('|');
        i++;
      } else if (char == '"') {
        quoted = !quoted;
        current.write(char);
      } else if (char == '|' && !quoted) {
        parts.add(current.toString());
        current.clear();
      } else {
        current.write(char);
      }
    }
    parts.add(current.toString());
    return parts.where((p) => p.trim().isNotEmpty).toList();
  }

  static final _command = RegExp(r'^\s*/([a-zA-Z0-9_:-]+)\s*([\s\S]*)$');
  static final _named = RegExp(r'^([a-zA-Z_][\w-]*)=(?:"([^"]*)"|(\S+))\s*');

  static (String, Map<String, String>, String)? _parseCommand(
    String segment,
    String pipe,
  ) {
    final match = _command.firstMatch(segment);
    if (match == null) return null;
    final name = match.group(1)!.toLowerCase();
    var rest = match.group(2)!;
    final named = <String, String>{};
    while (true) {
      final arg = _named.firstMatch(rest);
      if (arg == null) break;
      named[arg.group(1)!] = _pipe(arg.group(2) ?? arg.group(3)!, pipe);
      rest = rest.substring(arg.end);
    }
    var text = rest.trim();
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      text = text.substring(1, text.length - 1);
    }
    return (name, named, _pipe(text, pipe));
  }

  static String _pipe(String value, String pipe) => value.replaceAll(
    RegExp(r'\{\{\s*pipe\s*\}\}', caseSensitive: false),
    pipe,
  );

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
  static List<Map<String, dynamic>> _maps(Object? value, String what) {
    if (value is! List) throw ArgumentError('$what 必须是数组');
    return [for (final item in value) _map(item)];
  }

  static String _string(Object? value, {String fallback = ''}) =>
      value is String
      ? value
      : value == null
      ? fallback
      : value.toString();
}
