@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

/// A stand-in for `claude` / `codex`: records its arguments and stdin, then
/// prints the given JSON lines (optionally sleeping between them).
Future<File> _fakeTool(Directory dir, List<Object> lines) async {
  final script = File('${dir.path}/fake-tool');
  final body = StringBuffer('#!/bin/sh\n')
    ..writeln('printf "%s\\n" "\$@" > "${dir.path}/args"')
    ..writeln('cat > "${dir.path}/stdin"');
  for (final line in lines) {
    if (line is Duration) {
      body.writeln('sleep ${line.inMilliseconds / 1000}');
    } else {
      final json = jsonEncode(line).replaceAll("'", "'\\''");
      body.writeln("printf '%s\\n' '$json'");
    }
  }
  await script.writeAsString(body.toString());
  await Process.run('chmod', ['+x', script.path]);
  return script;
}

ModelConnection _connection(
  ModelProtocol protocol,
  File command, {
  String model = 'default',
}) => ModelConnection(
  id: 'cli',
  name: '本地订阅',
  baseUrl: '',
  model: model,
  protocol: protocol,
  command: command.path,
);

Map<String, dynamic> _delta(String text) => {
  'type': 'stream_event',
  'event': {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
};

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('cli-test-'));
  tearDown(() => dir.delete(recursive: true));

  final request = ProviderRequest(
    messages: [
      {'role': 'system', 'content': '你是小说作者。'},
      {'role': 'user', 'content': '写雾港的开头'},
    ],
  );

  test('Claude Code streams text deltas with tools disabled', () async {
    final tool = await _fakeTool(dir, [
      {'type': 'system', 'subtype': 'init'},
      _delta('雾从'),
      _delta('港口升起。'),
      {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': '雾从港口升起。'},
          ],
        },
      },
      {
        'type': 'result',
        'subtype': 'success',
        'is_error': false,
        'result': '雾从港口升起。',
        'usage': {'output_tokens': 8},
        'total_cost_usd': 0.0123,
      },
    ]);
    final provider = LocalCliProvider(
      config: _connection(ModelProtocol.claudeCode, tool),
    );
    final events = await provider.generate(request).toList();
    expect(
      events.whereType<TextDelta>().map((e) => e.text).join(),
      '雾从港口升起。',
      reason: 'the complete assistant message must not repeat streamed text',
    );
    final finish = events.whereType<GenerationFinished>().single;
    expect(finish.isComplete, isTrue);
    expect(finish.usage['output_tokens'], 8);
    // The run's cost sits beside its usage; metering reads it from usage.
    expect(finish.usage['total_cost_usd'], 0.0123);

    final args = await File('${dir.path}/args').readAsLines();
    expect(args.take(2), ['-p', '--output-format']);
    expect(args, containsAllInOrder(['--tools', '']));
    expect(args, contains('--no-session-persistence'));
    expect(args, isNot(contains('--model')));
    expect(args.join('\n'), isNot(contains('写雾港的开头')));
    final stdin = await File('${dir.path}/stdin').readAsString();
    expect(stdin, contains('【指令】\n你是小说作者。'));
    expect(stdin, contains('【用户】\n写雾港的开头'));
  });

  test(
    'Codex runs read-only, reads the prompt from stdin, passes the model',
    () async {
      final tool = await _fakeTool(dir, [
        {'type': 'thread.started', 'thread_id': 't'},
        {
          'type': 'item.completed',
          'item': {'id': 'r', 'type': 'reasoning', 'text': '先想想'},
        },
        {
          'type': 'item.completed',
          'item': {'id': 'a', 'type': 'agent_message', 'text': '灯塔熄灭了。'},
        },
        {
          'type': 'turn.completed',
          'usage': {'output_tokens': 5},
        },
      ]);
      final provider = LocalCliProvider(
        config: _connection(ModelProtocol.codexCli, tool, model: 'gpt-5'),
      );
      final events = await provider.generate(request).toList();
      expect(events.whereType<TextDelta>().single.text, '灯塔熄灭了。');
      expect(events.whereType<ReasoningDelta>().single.text, '先想想');
      expect(events.last, isA<GenerationFinished>());
      final args = await File('${dir.path}/args').readAsLines();
      expect(args.first, 'exec');
      expect(args, containsAllInOrder(['--sandbox', 'read-only']));
      expect(args, containsAllInOrder(['--model', 'gpt-5']));
      expect(args.last, '-');
      final stdin = await File('${dir.path}/stdin').readAsString();
      expect(stdin, startsWith('你在 SillyDraft'));
      expect(stdin, contains('写雾港的开头'));
    },
  );

  test('editor tools are emulated: a split fence becomes tool calls', () async {
    final tool = await _fakeTool(dir, [
      _delta('我先看看章节。\n``'),
      _delta('`sillydraft-tool'),
      _delta('-calls\n[{"name": "read_chapter", '),
      _delta('"arguments": {"chapterId": "s1"}}]\n```'),
      {'type': 'result', 'subtype': 'success', 'is_error': false},
    ]);
    final provider = LocalCliProvider(
      config: _connection(ModelProtocol.claudeCode, tool),
    );
    final events = await provider
        .generate(
          ProviderRequest(
            messages: [
              {'role': 'user', 'content': '帮我改第一场'},
              {
                'role': 'assistant',
                'content': '',
                'tool_calls': [
                  {
                    'id': 'old',
                    'type': 'function',
                    'function': {'name': 'list_chapters', 'arguments': '{}'},
                  },
                ],
              },
              {'role': 'tool', 'tool_call_id': 'old', 'content': '[s1]'},
            ],
            tools: [
              {
                'type': 'function',
                'function': {
                  'name': 'read_chapter',
                  'description': '读取章节',
                  'parameters': {'type': 'object'},
                },
              },
            ],
          ),
        )
        .toList();
    expect(
      events.whereType<TextDelta>().map((e) => e.text).join(),
      '我先看看章节。\n',
    );
    final call = events.whereType<ToolCallReady>().single;
    expect(call.name, 'read_chapter');
    expect(call.arguments, {'chapterId': 's1'});
    expect(events.whereType<GenerationFinished>().single.reason, 'tool_calls');

    final args = await File('${dir.path}/args').readAsString();
    expect(args, contains('read_chapter'), reason: 'tools described to model');
    final stdin = await File('${dir.path}/stdin').readAsString();
    expect(stdin, contains('【助手调用工具】'));
    expect(stdin, contains('"name":"list_chapters"'));
    expect(stdin, contains('【工具结果】\n[s1]'));
  });

  test('a malformed tool block is an error, not prose', () async {
    final tool = await _fakeTool(dir, [
      _delta('```sillydraft-tool-calls\n[{"name": oops}]\n```'),
      {'type': 'result', 'subtype': 'success', 'is_error': false},
    ]);
    final provider = LocalCliProvider(
      config: _connection(ModelProtocol.claudeCode, tool),
    );
    expect(
      provider
          .generate(
            ProviderRequest(
              messages: request.messages,
              tools: [
                {
                  'type': 'function',
                  'function': {'name': 'list_chapters'},
                },
              ],
            ),
          )
          .toList(),
      throwsA(
        isA<ProviderException>().having((e) => e.code, 'code', 'invalid_tool'),
      ),
    );
  });

  test('a signed-out tool explains how to sign in', () async {
    final tool = await _fakeTool(dir, [
      {
        'type': 'result',
        'subtype': 'success',
        'is_error': true,
        'result': 'Not logged in · Please run /login',
      },
    ]);
    final provider = LocalCliProvider(
      config: _connection(ModelProtocol.claudeCode, tool),
    );
    await expectLater(
      provider.generate(request).toList(),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          contains('未登录'),
        ),
      ),
    );
  });

  test(
    'exiting without a completion keeps partial text and reports it',
    () async {
      final tool = await _fakeTool(dir, [_delta('半句')]);
      final provider = LocalCliProvider(
        config: _connection(ModelProtocol.claudeCode, tool),
      );
      final seen = <ProviderEvent>[];
      await expectLater(
        provider.generate(request).forEach(seen.add),
        throwsA(
          isA<ProviderException>().having((e) => e.code, 'code', 'interrupted'),
        ),
      );
      expect(seen.whereType<TextDelta>().single.text, '半句');
    },
  );

  test('cancelling stops the process promptly', () async {
    final tool = await _fakeTool(dir, [
      _delta('开头'),
      const Duration(seconds: 30),
      {'type': 'result', 'subtype': 'success', 'is_error': false},
    ]);
    final provider = LocalCliProvider(
      config: _connection(ModelProtocol.claudeCode, tool),
    );
    final cancel = GenerationCancellation();
    final watch = Stopwatch()..start();
    await expectLater(
      provider.generate(request, cancellation: cancel).forEach((event) {
        if (event is TextDelta) cancel.cancel();
      }),
      throwsA(isA<GenerationCancelled>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
  });

  test('unsupported request shapes are reported, never silently dropped', () {
    final provider = LocalCliProvider(
      config: ModelConnection(
        id: 'c',
        name: 'c',
        baseUrl: '',
        model: 'default',
        protocol: ModelProtocol.codexCli,
      ),
    );
    final diagnostics = provider.validateParameters(
      ProviderRequest(
        completionText: '续写',
        parameters: {'temperature': 0.8, 'max_tokens': 900},
        stopStrings: ['\n\n'],
      ),
    );
    expect(
      diagnostics
          .where((d) => d.severity == DiagnosticSeverity.error)
          .single
          .code,
      'cli_text_completion',
    );
    expect(
      diagnostics.map((d) => d.path),
      containsAll(['temperature', 'stop']),
    );
    expect(diagnostics.map((d) => d.path), isNot(contains('max_tokens')));
  });

  test('a missing explicit command fails clearly', () async {
    final provider = LocalCliProvider(
      config: ModelConnection(
        id: 'c',
        name: 'c',
        baseUrl: '',
        model: 'default',
        protocol: ModelProtocol.claudeCode,
        command: '${dir.path}/nope',
      ),
    );
    await expectLater(
      provider.generate(request).toList(),
      throwsA(
        isA<ProviderException>().having((e) => e.code, 'code', 'cli_missing'),
      ),
    );
  });

  test('local CLI connections need no endpoint and round-trip', () {
    final saved = ModelConnection.fromJson(
      ModelConnection(
        id: 'c',
        name: 'Claude 订阅',
        baseUrl: '',
        model: 'sonnet',
        protocol: ModelProtocol.claudeCode,
        command: '/usr/local/bin/claude',
      ).raw,
    );
    expect(saved.protocol.isLocalCli, isTrue);
    expect(saved.command, '/usr/local/bin/claude');
    expect(
      () => ModelConnection(id: 'x', name: 'x', baseUrl: '', model: 'm'),
      throwsFormatException,
      reason: 'HTTP connections still require a valid endpoint',
    );
  });
}
