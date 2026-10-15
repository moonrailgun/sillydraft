import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late OpenAICompatibleProvider provider;
  late Future<void> Function(HttpRequest) handler;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (r) async {
      r.response.statusCode = 500;
      await r.response.close();
    };
    server.listen((r) => handler(r));
    provider = OpenAICompatibleProvider(
      config: ModelConnection(
        id: 'test',
        name: 'local',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
      ),
      apiKey: 'private-key',
    );
  });
  tearDown(() async {
    provider.close();
    await server.close(force: true);
  });

  test('unimplemented prefill is diagnosed instead of silently discarded', () {
    final diagnostics = provider.validateParameters(
      ProviderRequest(parameters: {'assistant_prefill': '开头'}),
    );
    expect(
      diagnostics.any(
        (d) =>
            d.code == 'unsupported_prefill' &&
            d.severity == DiagnosticSeverity.error,
      ),
      isTrue,
    );
  });

  test('text preset context sizes stay internal like openai_max_context', () {
    // ST text presets store the context size as `max_length` (NovelAI's
    // own as `max_context`); SillyDraft uses the connection's instead.
    final diagnostics = provider.validateParameters(
      ProviderRequest(
        completionText: 'x',
        parameters: {'max_length': 8192, 'max_context': 7800},
      ),
    );
    expect(diagnostics, isEmpty);
  });

  test('continue_prefill is noted as ignored, not refused', () {
    final diagnostics = provider.validateParameters(
      ProviderRequest(parameters: {'continue_prefill': true}),
    );
    expect(diagnostics.map((d) => (d.code, d.severity)), [
      ('continue_prefill_ignored', DiagnosticSeverity.warning),
    ]);
  });

  ProviderRequest request({List<Map<String, dynamic>> tools = const []}) =>
      ProviderRequest(
        messages: [
          {'role': 'user', 'content': '写小说'},
        ],
        tools: tools,
        parameters: {'temperature': 0.7},
      );
  String chunk(Map<String, dynamic> delta, {String? finish}) =>
      'data: ${jsonEncode({
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': finish},
        ],
      })}\r\n\r\n';

  test('stream handles UTF-8 byte fragments and leaves reasoning separate', () async {
    Map<String, dynamic>? sent;
    handler = (r) async {
      expect(r.uri.path, '/v1/chat/completions');
      expect(r.headers.value('authorization'), 'Bearer private-key');
      sent =
          jsonDecode(await utf8.decoder.bind(r).join()) as Map<String, dynamic>;
      r.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      final data = utf8.encode(
        ': ping\r\n\r\n${chunk({'reasoning_content': '分析'})}${chunk({'content': '雨夜。'})}${chunk({}, finish: 'stop')}data: [DONE]\r\n\r\n',
      );
      for (var i = 0; i < data.length; i += 2) {
        r.response.add(data.sublist(i, (i + 2).clamp(0, data.length)));
        await r.response.flush();
      }
      await r.response.close();
    };
    final events = await provider.generate(request()).toList();
    expect(events.whereType<TextDelta>().map((e) => e.text).join(), '雨夜。');
    expect(events.whereType<ReasoningDelta>().map((e) => e.text).join(), '分析');
    expect(events.whereType<GenerationFinished>().single.reason, 'stop');
    expect(sent!['model'], 'test-model');
    expect(sent!['temperature'], 0.7);
  });

  test(
    'tool deltas are assembled and only validated JSON arguments are exposed',
    () async {
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        r.response.write(
          chunk({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call1',
                'type': 'function',
                'function': {'name': 'read_chapter', 'arguments': '{"chapter'},
              },
            ],
          }),
        );
        r.response.write(
          chunk({
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': 'Id":"s"}'},
              },
            ],
          }),
        );
        r.response.write(chunk({}, finish: 'tool_calls'));
        r.response.write('data: [DONE]\n\n');
        await r.response.close();
      };
      final events = await provider
          .generate(
            request(
              tools: [
                {
                  'type': 'function',
                  'function': {
                    'name': 'read_chapter',
                    'parameters': {'type': 'object'},
                  },
                },
              ],
            ),
          )
          .toList();
      final call = events.whereType<ToolCallReady>().single;
      expect(call.id, 'call1');
      expect(call.name, 'read_chapter');
      expect(call.arguments, {'chapterId': 's'});
    },
  );

  test(
    'a disconnected stream is an interruption even with partial text',
    () async {
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        r.response.write(chunk({'content': '未写完'}));
        await r.response.close();
      };
      final received = <ProviderEvent>[];
      await expectLater(
        provider.generate(request()).forEach(received.add),
        throwsA(
          isA<ProviderException>().having((e) => e.code, 'code', 'interrupted'),
        ),
      );
      expect(received.whereType<TextDelta>().single.text, '未写完');
    },
  );

  test(
    'cancellation stops the active request and returns a typed cancellation',
    () async {
      final ready = Completer<void>();
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        r.response.write(chunk({'content': '开头'}));
        await r.response.flush();
        ready.complete();
      };
      final cancel = GenerationCancellation();
      final result = provider
          .generate(request(), cancellation: cancel)
          .toList();
      final check = expectLater(result, throwsA(isA<GenerationCancelled>()));
      await ready.future;
      cancel.cancel();
      await check;
    },
  );

  test(
    'provider errors cannot echo API keys into persisted task errors',
    () async {
      handler = (r) async {
        await r.drain<void>();
        r.response.statusCode = 401;
        r.response.write(
          jsonEncode({
            'error': {'message': 'Invalid private-key'},
          }),
        );
        await r.response.close();
      };
      await expectLater(
        provider.generate(request()).toList(),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.statusCode, 'status', 401)
              .having(
                (e) => e.toString(),
                'error',
                isNot(contains('private-key')),
              ),
        ),
      );
    },
  );

  test(
    'stream errors retain the message without credentials or payloads',
    () async {
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType('text', 'event-stream');
        r.response.write(
          'data: ${jsonEncode({
            'error': {
              'message': 'Invalid tool response with private-key and Bearer upstream-secret',
              'request': {'content': 'private manuscript'},
            },
          })}\n\n',
        );
        await r.response.close();
      };
      await expectLater(
        provider.generate(request()).toList(),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.code, 'code', 'stream_error')
              .having(
                (e) => e.message,
                'message',
                contains('Invalid tool response'),
              )
              .having((e) => e.message, 'key', isNot(contains('private-key')))
              .having(
                (e) => e.message,
                'bearer',
                isNot(contains('upstream-secret')),
              )
              .having(
                (e) => e.message,
                'payload',
                isNot(contains('private manuscript')),
              ),
        ),
      );
    },
  );

  test('string errors are bounded after credential redaction', () async {
    handler = (r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType('text', 'event-stream');
      r.response.write(
        'data: ${jsonEncode({'error': 'Quota exceeded ${'x' * 490}private-key${'x' * 500}'})}\n\n',
      );
      await r.response.close();
    };
    await expectLater(
      provider.generate(request()).toList(),
      throwsA(
        isA<ProviderException>()
            .having((e) => e.message, 'message', contains('Quota exceeded'))
            .having((e) => e.message.length, 'length', lessThan(600))
            .having((e) => e.message, 'key', isNot(contains('private-'))),
      ),
    );
  });

  test('unrecognized error objects keep a readable fallback', () async {
    handler = (r) async {
      await r.drain<void>();
      r.response.headers.contentType = ContentType('text', 'event-stream');
      r.response.write(
        'data: ${jsonEncode({
          'error': {
            'message': {'api_key': 'private-key'},
          },
        })}\n\n',
      );
      await r.response.close();
    };
    await expectLater(
      provider.generate(request()).toList(),
      throwsA(
        isA<ProviderException>().having(
          (e) => e.message,
          'message',
          '模型服务在生成中返回错误',
        ),
      ),
    );
  });

  test(
    'non-streaming compatible response and length stop are explicit',
    () async {
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'choices': [
              {
                'index': 0,
                'message': {'role': 'assistant', 'content': '截断'},
                'finish_reason': 'length',
              },
            ],
          }),
        );
        await r.response.close();
      };
      final events = await provider.generate(request()).toList();
      expect(events.whereType<TextDelta>().single.text, '截断');
      expect(events.whereType<GenerationFinished>().single.reason, 'length');
    },
  );

  test(
    'completion text travels through completions with no chat wrapper',
    () async {
      handler = (r) async {
        expect(r.uri.path, '/v1/completions');
        final sent = jsonDecode(
          await utf8.decoder.bind(r).join(),
        ) as Map<String, dynamic>;
        expect(sent['prompt'], 'plain prompt');
        expect(sent, isNot(contains('messages')));
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'choices': [
              {'text': '正文', 'finish_reason': 'stop'},
            ],
          }),
        );
        await r.response.close();
      };
      final events = await provider
          .generate(ProviderRequest(completionText: 'plain prompt'))
          .toList();
      expect(events.whereType<TextDelta>().single.text, '正文');
    },
  );
}
