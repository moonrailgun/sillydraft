// OpenAI standard USD / 1M tokens, verified 2026-10-29:
// https://developers.openai.com/api/docs/pricing
// https://developers.openai.com/api/docs/models/gpt-6-astra
// The four GPT-6 model pages share the 272K long-context rule.
const _prices = {
  'gpt-6-astra': (input: 10.0, cached: 1.0, write: 12.5, output: 50.0),
  'gpt-6.1-sol': (input: 2.0, cached: 0.1, write: 2.5, output: 10.0),
  'gpt-6.1-terra': (input: 1.0, cached: 0.05, write: 1.25, output: 5.0),
  'gpt-6-luna': (input: 0.1, cached: 0.01, write: 0.125, output: 0.5),
};

typedef _Tokens = ({int input, int cached, int write, int output});

_Tokens? _tokens(Object? value) {
  if (value is! Map) return null;
  final input = value['inputTokens'];
  final cached = value['cachedInputTokens'];
  final write = value['cacheWriteInputTokens'] ?? 0;
  final output = value['outputTokens'];
  if (input is! int ||
      cached is! int ||
      write is! int ||
      output is! int ||
      input < 0 ||
      cached < 0 ||
      write < 0 ||
      output < 0 ||
      cached + write > input) {
    return null;
  }
  final reasoning = value['reasoningOutputTokens'];
  final total = value['totalTokens'];
  if (reasoning != null &&
      (reasoning is! int || reasoning < 0 || reasoning > output)) {
    return null;
  }
  if (total != null && total != input + output) return null;
  return (input: input, cached: cached, write: write, output: output);
}

/// API-equivalent conversation cost, never a subscription or image-tool bill.
/// Missing request boundaries and reroutes cannot be priced reliably.
Map<String, dynamic>? codexConversationEstimate(Map<String, dynamic> usage) {
  final price = _prices[usage['model']];
  final codex = usage['codex'];
  if (price == null || codex is! Map || codex['model_provider'] != 'openai') {
    return null;
  }
  if (codex['model_reroutes'] case final List reroutes
      when reroutes.isNotEmpty) {
    return null;
  }
  final updates = codex['token_usage'];
  if (updates is! List || updates.isEmpty) return null;
  var previous = (input: 0, cached: 0, write: 0, output: 0);
  _Tokens? previousLast;
  var cost = 0.0;
  for (final update in updates) {
    if (update is! Map) return null;
    final total = _tokens(update['total']);
    final last = _tokens(update['last']);
    if (total == null || last == null) return null;
    if (total == previous && last == previousLast) continue;
    if ((
          input: total.input - previous.input,
          cached: total.cached - previous.cached,
          write: total.write - previous.write,
          output: total.output - previous.output,
        ) !=
        last) {
      return null;
    }
    final long = last.input > 272000;
    cost +=
        ((last.input - last.cached - last.write) * price.input +
                last.cached * price.cached +
                last.write * price.write) *
            (long ? 2 : 1) +
        last.output * price.output * (long ? 1.5 : 1);
    previous = total;
    previousLast = last;
  }
  return {
    'cost_usd': cost / 1000000,
    'scope': 'conversation_only',
    'price_version': '2026-10-29',
    // shortcut: Codex omits cache TTL; use a 30m reference until it reports TTL.
    'basis': 'openai_standard_30m',
    'currency': 'USD',
    'model': usage['model'],
    'rates_per_million': {
      'input': price.input,
      'cached_input': price.cached,
      'cache_write': price.write,
      'output': price.output,
    },
    'long_context': {
      'threshold': 272000,
      'input_multiplier': 2,
      'output_multiplier': 1.5,
    },
  };
}
