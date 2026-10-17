import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../st/import_types.dart';
import 'provider.dart';

/// Generates with the author's own Claude Code or Codex subscription by
/// running the installed command-line tool. The tool's own agent features are
/// switched off: built-in tools disabled (Claude Code) or a read-only sandbox
/// (Codex), in an empty temporary working directory, without saved sessions.
///
/// Neither tool exposes function calling, so editor tools are described in the
/// prompt and calls are read back from a fenced JSON block (see [toolFence]).
final class LocalCliProvider implements ModelProvider {
  LocalCliProvider({required this.config, CliLocator? locator})
    : _locator = locator ?? CliLocator.shared {
    if (!config.protocol.isLocalCli) {
      throw ArgumentError('不是本地 CLI 连接');
    }
  }
  @override
  final ModelConnection config;
  final CliLocator _locator;
  final _processes = <Process>{};

  static const toolFence = '```sillydraft-tool-calls';
  static const _outputLimit = 16 * 1024 * 1024;

  bool get _claude => config.protocol == ModelProtocol.claudeCode;
  String get _toolName => _claude ? 'claude' : 'codex';
  String get _label => _claude ? 'Claude Code' : 'Codex';
  bool get _defaultModel =>
      config.model.trim().isEmpty || config.model.trim() == 'default';

  // Parameters the tools cannot receive. Reported, never silently dropped.
  static const _internal = {
    'openai_max_context',
    'max_context_length',
    'truncation_length',
    'streaming',
    'stream_openai',
    'n',
    'include_reasoning',
    'max_tokens',
    'max_completion_tokens',
  };

  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) {
    final diagnostics = <CompatibilityDiagnostic>[];
    if (request.completionText != null) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'cli_text_completion',
          '$_label 只能接收对话消息，不支持文本补全模板；请改用聊天预设',
          severity: DiagnosticSeverity.error,
        ),
      );
    }
    if (request.parameters['continue_prefill'] == true) {
      diagnostics.add(continuePrefillIgnored);
    }
    for (final key in ['assistant_prefill', 'claude_assistant_prefill']) {
      final value = request.parameters[key];
      if (value != null && value != false && value != '') {
        diagnostics.add(
          CompatibilityDiagnostic(
            'unsupported_prefill',
            '$_label 不支持 $key，需调整预设',
            path: key,
            severity: DiagnosticSeverity.error,
          ),
        );
      }
    }
    if ((request.parameters['n'] as num? ?? 1) != 1) {
      diagnostics.add(
        const CompatibilityDiagnostic(
          'multiple_choices',
          '一次生成只处理一个候选；多个走向使用独立任务',
          severity: DiagnosticSeverity.error,
        ),
      );
    }
    for (final e in request.parameters.entries) {
      if (_internal.contains(e.key) || e.key.endsWith('_prefill')) continue;
      diagnostics.add(
        CompatibilityDiagnostic(
          'cli_ignored_parameter',
          '$_label 不接受采样参数 ${e.key}，本次生成不会使用它',
          path: e.key,
        ),
      );
    }
    if (request.stopStrings.isNotEmpty) {
      diagnostics.add(
        CompatibilityDiagnostic(
          'cli_ignored_stop',
          '$_label 不支持停止序列，本次生成不会使用它们',
          path: 'stop',
        ),
      );
    }
    return diagnostics;
  }

  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    final cancel = cancellation ?? GenerationCancellation();
    cancel.check();
    final errors = validateParameters(request)
        .where((d) => d.severity == DiagnosticSeverity.error);
    if (errors.isNotEmpty) {
      throw ProviderException(
        'invalid_request',
        errors.map((d) => d.message).join('\n'),
      );
    }
    final executable = await _locator.find(_toolName, config.command);
    final workspace = await Directory.systemTemp.createTemp('sillydraft-cli-');
    final (system, prompt) = renderPrompt(request);
    final arguments = _claude
        ? [
            '-p',
            '--output-format',
            'stream-json',
            '--verbose',
            '--include-partial-messages',
            '--tools',
            '',
            '--no-session-persistence',
            '--disable-slash-commands',
            '--strict-mcp-config',
            '--system-prompt',
            system,
            if (!_defaultModel) ...['--model', config.model.trim()],
          ]
        : [
            'exec',
            '--json',
            '--skip-git-repo-check',
            '--ephemeral',
            // Skip the author's coding setup (MCP servers, providers, exec
            // rules). Login is unaffected; it lives in CODEX_HOME.
            '--ignore-user-config',
            '--ignore-rules',
            '--sandbox',
            'read-only',
            '--cd',
            workspace.path,
            if (!_defaultModel) ...['--model', config.model.trim()],
            '-',
          ];
    Process process;
    try {
      process = await executable.start(arguments, workspace.path);
    } on ProcessException catch (error) {
      await workspace.delete(recursive: true);
      throw ProviderException(
        'cli_start',
        '无法启动 $_label（${error.message}）。请确认已安装并能在终端运行 $_toolName',
      );
    }
    _processes.add(process);
    final stderr = _Tail();
    final stderrDone = process.stderr.listen(stderr.add).asFuture<void>();
    // A child of the tool can keep stdout open after the tool is killed, so
    // cancelling ends the line stream itself rather than waiting for EOF.
    final lines = StreamController<String>();
    final stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          lines.add,
          onError: lines.addError,
          onDone: () {
            if (!lines.isClosed) lines.close();
          },
        );
    final removeCancel = cancel.onCancel(() {
      process.kill();
      if (!lines.isClosed) lines.close();
    });
    final fence = request.tools.isEmpty ? null : _FenceFilter();
    try {
      // The prompt goes through stdin: no argument-length limit, and the
      // manuscript does not appear in the system process list. Codex has no
      // system-prompt flag, so it also receives the fixed instructions here.
      process.stdin.write(_claude ? prompt : '$system\n\n$prompt');
      await process.stdin.close();
      final parser = _claude ? _ClaudeStream() : _CodexStream();
      var total = 0;
      await for (final line in lines.stream) {
        cancel.check();
        total += line.length;
        if (total > _outputLimit) {
          process.kill();
          throw const ProviderException('response_limit', '模型响应超过大小限制');
        }
        if (line.trim().isEmpty) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException {
          continue; // Banners or warnings printed between JSON lines.
        }
        if (decoded is! Map<String, dynamic>) continue;
        for (final event in parser.read(decoded, _label)) {
          if (event is TextDelta && fence != null) {
            final visible = fence.feed(event.text);
            if (visible.isNotEmpty) yield TextDelta(visible);
          } else {
            yield event;
          }
        }
      }
      cancel.check();
      final code = await process.exitCode;
      await stderrDone.timeout(const Duration(seconds: 2), onTimeout: () {});
      if (parser.failure case final String message) {
        throw ProviderException('cli_error', _explain(message));
      }
      if (!parser.finished) {
        throw ProviderException(
          code == 0 ? 'interrupted' : 'cli_error',
          code == 0
              ? '$_label 没有返回完成标志，已收到的部分内容已保留'
              : _explain(stderr.text.isEmpty ? '退出码 $code' : stderr.text),
        );
      }
      if (fence != null) {
        final calls = fence.calls();
        if (fence.rest.isNotEmpty) yield TextDelta(fence.rest);
        for (final (i, call) in calls.indexed) {
          yield ToolCallReady(
            'cli_${DateTime.now().microsecondsSinceEpoch}_$i',
            call.$1,
            call.$2,
          );
        }
        yield GenerationFinished(
          calls.isEmpty ? 'stop' : 'tool_calls',
          usage: parser.usage,
        );
      } else {
        yield GenerationFinished('stop', usage: parser.usage);
      }
    } finally {
      removeCancel();
      await stdout.cancel();
      _processes.remove(process);
      process.kill();
      try {
        await workspace.delete(recursive: true);
      } on FileSystemException {
        // Temporary directory cleanup must not hide the generation result.
      }
    }
  }

  String _explain(String message) {
    final text = message.trim();
    final short = text.length > 600 ? '${text.substring(0, 600)}…' : text;
    if (RegExp(
      r'log ?in|logged|auth|credential|401',
      caseSensitive: false,
    ).hasMatch(text)) {
      return '$_label 未登录或登录已过期。请在终端运行 $_toolName 完成登录后重试。\n$short';
    }
    return '$_label 返回错误：$short';
  }

  /// Flattens chat messages into one prompt, since both tools take a single
  /// instruction. Returns the fixed backend instructions (small enough for a
  /// command-line argument) and the prompt, which carries the request's own
  /// system text. Tool traffic is kept as labelled blocks so the model can see
  /// what it already looked up.
  (String, String) renderPrompt(ProviderRequest request) {
    final system = StringBuffer();
    final transcript = StringBuffer();
    for (final m in request.messages) {
      final content = _text(m['content']);
      switch (m['role']) {
        case 'system':
          if (system.isNotEmpty) system.write('\n\n');
          system.write(content);
        case 'user':
          transcript.write('【用户】\n$content\n\n');
        case 'assistant':
          if (content.isNotEmpty) transcript.write('【助手】\n$content\n\n');
          final calls = m['tool_calls'];
          if (calls is List && calls.isNotEmpty) {
            transcript.write('【助手调用工具】\n$toolFence\n');
            transcript.write(
              jsonEncode([
                for (final c in calls.cast<Map<String, dynamic>>())
                  {
                    'name': (c['function'] as Map?)?['name'],
                    'arguments': _arguments(
                      (c['function'] as Map?)?['arguments'],
                    ),
                  },
              ]),
            );
            transcript.write('\n```\n\n');
          }
        case 'tool':
          transcript.write('【工具结果】\n$content\n\n');
      }
    }
    final fixed = StringBuffer(
      '你在 SillyDraft 小说应用中作为纯文本生成后端运行：不要读取或修改本机文件，'
      '不要执行命令，不要提及自己是命令行工具。严格按照提示中的【指令】输出内容。'
      '你可能还收到了面向编程工作的个人或项目说明（如 AGENTS.md、CLAUDE.md），'
      '它们与本次写作无关，请忽略，也不要在回复中提及。',
    );
    if (request.tools.isNotEmpty) fixed.write(_toolInstructions(request.tools));
    final prompt = StringBuffer();
    if (system.isNotEmpty) prompt.write('【指令】\n$system\n\n');
    prompt.write(
      transcript.isEmpty ? '请开始。' : '以下是到目前为止的对话，请作为助手给出下一条回复。\n\n$transcript',
    );
    return (fixed.toString(), prompt.toString().trimRight());
  }

  String _toolInstructions(List<Map<String, dynamic>> tools) {
    final out = StringBuffer(
      '\n\n# 可用工具\n'
      '需要调用工具时，回复中只能包含一个如下格式的代码块，代码块之后不要再写任何内容：\n'
      '$toolFence\n[{"name": "工具名", "arguments": {参数}}]\n```\n'
      '可以一次调用多个工具。代码块中必须是合法 JSON。工具结果会在下一轮以【工具结果】提供。'
      '不需要工具时直接回复，不要输出该代码块。\n',
    );
    for (final tool in tools) {
      final f = tool['function'] as Map<String, dynamic>? ?? tool;
      out.write(
        '\n- ${f['name']}：${f['description'] ?? ''}\n'
        '  参数 JSON Schema：${jsonEncode(f['parameters'] ?? {})}',
      );
    }
    return out.toString();
  }

  static String _text(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .map((part) => part is Map ? '${part['text'] ?? ''}' : '$part')
          .join();
    }
    return content == null ? '' : '$content';
  }

  static Object? _arguments(Object? value) {
    if (value is! String) return value;
    try {
      return jsonDecode(value);
    } on FormatException {
      return value;
    }
  }

  /// Confirms the tool is installed and signed in, for the settings dialog.
  Future<String> check() async {
    final executable = await _locator.find(_toolName, config.command);
    final version = await executable.run(['--version']);
    if (version.exitCode != 0) {
      throw ProviderException('cli_start', '$_label 无法运行：${version.output}');
    }
    final status = await executable.run(
      _claude ? ['auth', 'status'] : ['login', 'status'],
    );
    var signedIn = status.exitCode == 0;
    if (_claude) {
      try {
        signedIn = (jsonDecode(status.output) as Map)['loggedIn'] == true;
      } on Object {
        signedIn = false;
      }
    }
    if (!signedIn) {
      throw ProviderException(
        'cli_auth',
        '已找到 $_label（${version.output.trim()}），但尚未登录。请在终端运行 $_toolName 完成登录。',
      );
    }
    return '已找到 ${executable.path}（${version.output.trim()}），已登录';
  }

  @override
  Future<List<String>> listModels() async {
    await check();
    return _claude
        ? const ['default', 'sonnet', 'opus', 'haiku']
        : const ['default'];
  }

  @override
  void close() {
    for (final process in _processes) {
      process.kill();
    }
  }
}

/// Keeps the last few kilobytes of stderr for error messages.
final class _Tail {
  final _bytes = <int>[];
  void add(List<int> chunk) {
    _bytes.addAll(chunk);
    if (_bytes.length > 4096) _bytes.removeRange(0, _bytes.length - 4096);
  }

  String get text => utf8.decode(_bytes, allowMalformed: true).trim();
}

abstract class _CliStream {
  bool finished = false;
  String? failure;
  Map<String, dynamic> usage = const {};
  Iterable<ProviderEvent> read(Map<String, dynamic> event, String label);
}

/// `claude -p --output-format stream-json --include-partial-messages`.
final class _ClaudeStream extends _CliStream {
  var _streamed = false;
  @override
  Iterable<ProviderEvent> read(Map<String, dynamic> event, String label) sync* {
    switch (event['type']) {
      case 'stream_event':
        final inner = event['event'];
        if (inner is Map && inner['type'] == 'content_block_delta') {
          final delta = inner['delta'];
          if (delta is Map && delta['type'] == 'text_delta') {
            _streamed = true;
            final text = delta['text'];
            if (text is String && text.isNotEmpty) yield TextDelta(text);
          } else if (delta is Map && delta['type'] == 'thinking_delta') {
            final text = delta['thinking'];
            if (text is String && text.isNotEmpty) yield ReasoningDelta(text);
          }
        }
      case 'assistant':
        // Complete messages repeat the streamed deltas; use them only when the
        // tool did not stream (older versions or disabled partial output).
        if (_streamed) return;
        final content = (event['message'] as Map?)?['content'];
        if (content is List) {
          for (final block in content) {
            if (block is Map && block['type'] == 'text') {
              final text = block['text'];
              if (text is String && text.isNotEmpty) yield TextDelta(text);
            }
          }
        }
      case 'result':
        if (event['is_error'] == true || event['subtype'] != 'success') {
          failure = '${event['result'] ?? event['subtype'] ?? '未知错误'}';
        } else {
          finished = true;
          usage = {
            if (event['usage'] case final Map<String, dynamic> usage) ...usage,
            // The run's cost sits beside its usage; metering reads usage.
            if (event['total_cost_usd'] is num)
              'total_cost_usd': event['total_cost_usd'],
          };
        }
    }
  }
}

/// `codex exec --json`: one complete agent message per item.
final class _CodexStream extends _CliStream {
  var _messages = 0;
  @override
  Iterable<ProviderEvent> read(Map<String, dynamic> event, String label) sync* {
    switch (event['type']) {
      case 'item.completed':
        final item = event['item'];
        if (item is! Map) return;
        final text = item['text'];
        if (text is! String || text.isEmpty) return;
        if (item['type'] == 'agent_message') {
          yield TextDelta(_messages++ == 0 ? text : '\n\n$text');
        } else if (item['type'] == 'reasoning') {
          yield ReasoningDelta(text);
        }
      case 'turn.completed':
        finished = true;
        if (event['usage'] is Map<String, dynamic>) {
          usage = event['usage'] as Map<String, dynamic>;
        }
      case 'turn.failed':
        failure = '${(event['error'] as Map?)?['message'] ?? '生成失败'}';
      case 'error':
        failure = '${event['message'] ?? '生成失败'}';
    }
  }
}

/// Streams visible text while holding back the tool-call block, which may
/// arrive split across chunks.
final class _FenceFilter {
  final _held = StringBuffer();
  var _inFence = false;
  final _fence = StringBuffer();
  String rest = '';

  String feed(String chunk) {
    if (_inFence) {
      _fence.write(chunk);
      return '';
    }
    _held.write(chunk);
    final text = _held.toString();
    final at = text.indexOf(LocalCliProvider.toolFence);
    if (at >= 0) {
      _inFence = true;
      _fence.write(text.substring(at + LocalCliProvider.toolFence.length));
      _held.clear();
      return text.substring(0, at);
    }
    // Keep back a suffix that could be the start of the fence marker.
    var keep = 0;
    for (var n = LocalCliProvider.toolFence.length - 1; n > 0; n--) {
      if (text.endsWith(LocalCliProvider.toolFence.substring(0, n))) {
        keep = n;
        break;
      }
    }
    _held.clear();
    _held.write(text.substring(text.length - keep));
    return text.substring(0, text.length - keep);
  }

  List<(String, Map<String, dynamic>)> calls() {
    if (!_inFence) {
      rest = _held.toString();
      return const [];
    }
    rest = '';
    var body = _fence.toString();
    final end = body.indexOf('```');
    if (end >= 0) body = body.substring(0, end);
    final Object? decoded;
    try {
      decoded = jsonDecode(body.trim());
    } on FormatException {
      throw const ProviderException('invalid_tool', '模型的工具调用格式无效，请重试');
    }
    final list = decoded is List ? decoded : [decoded];
    if (list.isEmpty || list.length > 12) {
      throw const ProviderException('tool_limit', '工具调用数量无效');
    }
    return [
      for (final call in list)
        if (call is Map &&
            call['name'] is String &&
            (call['arguments'] ?? <String, dynamic>{}) is Map<String, dynamic>)
          (
            call['name'] as String,
            (call['arguments'] ?? <String, dynamic>{}) as Map<String, dynamic>,
          )
        else
          throw const ProviderException(
            'invalid_tool_arguments',
            '工具调用须包含名称和 JSON 对象参数',
          ),
    ];
  }
}

/// A resolved command-line tool and the environment it runs with.
final class CliExecutable {
  const CliExecutable(this.path, this.environment);
  final String path;
  final Map<String, String> environment;

  // npm installs `.cmd` shims on Windows, which need the shell to run.
  bool get _shell => Platform.isWindows && !path.toLowerCase().endsWith('.exe');

  Future<Process> start(List<String> arguments, String workingDirectory) =>
      Process.start(
        path,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        runInShell: _shell,
      );

  Future<({int exitCode, String output})> run(List<String> arguments) async {
    final workspace = await Directory.systemTemp.createTemp('sillydraft-cli-');
    try {
      final result = await Process.run(
        path,
        arguments,
        workingDirectory: workspace.path,
        environment: environment,
        runInShell: _shell,
      ).timeout(const Duration(seconds: 30));
      return (
        exitCode: result.exitCode,
        output: '${result.stdout}${result.stderr}'.trim(),
      );
    } on TimeoutException {
      throw const ProviderException('cli_timeout', '命令行工具没有响应');
    } finally {
      await workspace.delete(recursive: true);
    }
  }
}

/// Finds `claude` / `codex` the way a terminal would. Desktop apps started from
/// the Dock or Start menu do not inherit the shell's PATH, so the login shell
/// is asked once and common install locations are tried as well.
final class CliLocator {
  CliLocator({Map<String, String>? environment})
    : _environment = environment ?? Platform.environment;
  static final shared = CliLocator();
  final Map<String, String> _environment;
  Future<String>? _shellPath;

  String get _separator => Platform.isWindows ? ';' : ':';

  Future<String> _loginPath() => _shellPath ??= () async {
    if (Platform.isWindows) return '';
    final shell = _environment['SHELL'] ?? '/bin/zsh';
    try {
      final result = await Process.run(shell, [
        '-lc',
        r'printf %s "$PATH"',
      ]).timeout(const Duration(seconds: 10));
      return result.exitCode == 0 ? '${result.stdout}' : '';
    } on Object {
      return '';
    }
  }();

  Future<CliExecutable> find(String name, String explicit) async {
    final home = _environment['HOME'] ?? _environment['USERPROFILE'] ?? '';
    final directories = <String>{
      ...(await _loginPath()).split(_separator),
      ...(_environment['PATH'] ?? '').split(_separator),
      '$home/.local/bin',
      '$home/.claude/local',
      '$home/.npm-global/bin',
      '$home/.bun/bin',
      '$home/.volta/bin',
      '/opt/homebrew/bin',
      '/usr/local/bin',
      if (Platform.isWindows) '${_environment['APPDATA']}\\npm',
    }..removeWhere((d) => d.isEmpty);
    final path = [
      ...directories,
      if (Platform.isMacOS || Platform.isLinux) '/usr/bin',
    ].join(_separator);
    final environment = {..._environment, 'PATH': path};
    if (explicit.trim().isNotEmpty) {
      final file = File(explicit.trim());
      if (!file.isAbsolute || !await file.exists()) {
        throw ProviderException('cli_missing', '找不到命令：${file.path}');
      }
      return CliExecutable(file.path, {
        ...environment,
        'PATH': '${file.parent.path}$_separator$path',
      });
    }
    final names = Platform.isWindows
        ? ['$name.exe', '$name.cmd', '$name.bat']
        : [name];
    for (final directory in directories) {
      for (final candidate in names) {
        final file = File('$directory${Platform.pathSeparator}$candidate');
        if (await file.exists()) {
          return CliExecutable(file.path, {
            ...environment,
            'PATH': '$directory$_separator$path',
          });
        }
      }
    }
    throw ProviderException(
      'cli_missing',
      '没有找到 $name。请先安装并在终端完成登录，或在连接里填写命令的完整路径。',
    );
  }
}
