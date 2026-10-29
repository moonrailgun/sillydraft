import 'dart:async';
import 'dart:math';

import 'provider.dart';

/// What a connection test saw: whether the model answered, what it said, how
/// the reply ended and how long it took.
final class ConnectionProbeResult {
  const ConnectionProbeResult({
    required this.ok,
    required this.elapsed,
    this.reply = '',
    this.finishReason,
    this.usage = const {},
    this.sawReasoning = false,
    this.error,
    this.warning,
  });
  final bool ok;
  final Duration elapsed;
  final String reply;
  final String? finishReason;
  final Map<String, dynamic> usage;
  final bool sawReasoning;

  /// Why the test failed, in the provider's own words.
  final String? error;

  /// The model answered, but something is worth knowing.
  final String? warning;
}

/// Sends one tiny chat request and reports the outcome. Uses the same
/// provider code as real generation, so a pass means writing will reach the
/// model too. Never throws: every failure becomes [ConnectionProbeResult.error].
Future<ConnectionProbeResult> probeConnection(
  ModelProvider provider, {
  Duration timeout = const Duration(seconds: 90),
  GenerationCancellation? cancellation,
}) async {
  final cancel = cancellation ?? GenerationCancellation();
  final watch = Stopwatch()..start();
  final reply = StringBuffer();
  var reasoning = false;
  GenerationFinished? finish;
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    cancel.cancel();
  });
  // The remote runner keeps jobs by ID; a test gets its own throwaway one.
  final random = Random.secure();
  final id = List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  try {
    await for (final event in provider.generate(
      ProviderRequest(
        messages: const [
          {'role': 'system', 'content': '这是 SillyDraft 的模型连接测试。'},
          {'role': 'user', 'content': '请只回复四个字：连接正常'},
        ],
        parameters: {'max_tokens': min(provider.config.maxOutputTokens, 512)},
        executionId: 'connection-test-$id',
        usagePurpose: 'connectionTest',
      ),
      cancellation: cancel,
    )) {
      switch (event) {
        case TextDelta():
          reply.write(event.text);
        case ReasoningDelta():
          reasoning = true;
        case ToolCallReady():
          break;
        case GenerationFinished():
          finish = event;
      }
    }
    final text = reply.toString().trim();
    final elapsed = watch.elapsed;
    if (text.isEmpty) {
      return ConnectionProbeResult(
        ok: finish != null,
        elapsed: elapsed,
        finishReason: finish?.reason,
        usage: finish?.usage ?? const {},
        sawReasoning: reasoning,
        error: finish == null ? '模型没有返回内容' : null,
        warning: finish == null
            ? null
            : '模型有响应，但没有返回正文（结束原因：${finish.reason}）。'
                  '${reasoning || finish.reason == 'length' ? '推理模型可能用完了输出上限，可调大“输出 token 上限”。' : ''}',
      );
    }
    return ConnectionProbeResult(
      ok: true,
      elapsed: elapsed,
      reply: text,
      finishReason: finish?.reason,
      usage: finish?.usage ?? const {},
      sawReasoning: reasoning,
      warning: finish != null && !finish.isComplete
          ? '回复未完整结束（${finish.reason}），已收到的内容如上。'
          : null,
    );
  } on GenerationCancelled {
    return ConnectionProbeResult(
      ok: false,
      elapsed: watch.elapsed,
      reply: reply.toString().trim(),
      error: timedOut ? '等待 ${timeout.inSeconds} 秒仍未完成，已停止测试' : '测试已取消',
    );
  } catch (e) {
    return ConnectionProbeResult(
      ok: false,
      elapsed: watch.elapsed,
      reply: reply.toString().trim(),
      error: '$e',
    );
  } finally {
    timer.cancel();
  }
}
