import 'dart:async';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

final _config = ModelConnection(
  id: 'c',
  name: 'c',
  baseUrl: 'http://localhost:1/v1',
  model: 'm',
  maxOutputTokens: 4096,
);

ScriptProvider _provider(
  Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation) s,
) => ScriptProvider(_config, s);

void main() {
  test('a working model passes and shows what it said', () async {
    ProviderRequest? sent;
    final result = await probeConnection(
      _provider((request, _) async* {
        sent = request;
        yield const ReasoningDelta('想一想');
        yield const TextDelta('连接');
        yield const TextDelta('正常');
        yield const GenerationFinished('stop', usage: {'total_tokens': 12});
      }),
    );
    expect(result.ok, isTrue);
    expect(result.reply, '连接正常');
    expect(result.finishReason, 'stop');
    expect(result.usage['total_tokens'], 12);
    expect(result.sawReasoning, isTrue);
    expect(result.error, isNull);
    expect(result.warning, isNull);
    expect(sent!.messages.last['content'], contains('连接正常'));
    expect(sent!.parameters['max_tokens'], 512, reason: 'capped, not 4096');
    expect(sent!.executionId, startsWith('connection-test-'));
  });

  test('an answer without text is reported, with the likely cause', () async {
    final result = await probeConnection(
      _provider((_, _) async* {
        yield const ReasoningDelta('思考了很久');
        yield const GenerationFinished('length');
      }),
    );
    expect(result.ok, isTrue, reason: 'the model did respond');
    expect(result.reply, isEmpty);
    expect(result.warning, contains('输出 token 上限'));
  });

  test('provider errors are shown, never thrown', () async {
    final result = await probeConnection(
      _provider((_, _) async* {
        throw const ProviderException(
          'http_error',
          '模型服务拒绝请求，请检查连接、权限或额度',
          statusCode: 401,
        );
      }),
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('HTTP 401'));
  });

  test('a stream that ends without finishing is a failure', () async {
    final result = await probeConnection(_provider((_, _) async* {}));
    expect(result.ok, isFalse);
    expect(result.error, '模型没有返回内容');
  });

  test('a silent model times out and is stopped', () async {
    var cancelled = false;
    final result = await probeConnection(
      _provider((_, cancel) async* {
        final done = Completer<void>();
        cancel.onCancel(() {
          cancelled = true;
          done.complete();
        });
        await done.future;
        cancel.check();
      }),
      timeout: const Duration(milliseconds: 50),
    );
    expect(cancelled, isTrue);
    expect(result.ok, isFalse);
    expect(result.error, contains('仍未完成'));
  });
}
