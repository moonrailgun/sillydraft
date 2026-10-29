import 'dart:async';
import 'dart:convert';
import 'dart:io' show stderr;

import 'package:dio/dio.dart';

import '../model/usage.dart';
import '../st/import_types.dart' show CompatibilityDiagnostic;
import '../st/world_book_engine.dart' show estimateTokens;
import '../storage/story_repository.dart';
import 'image_provider.dart';
import 'provider.dart';
import 'remote_provider.dart' show RemoteJobControl;

/// A model's list price in US dollars per token.
typedef ModelPrice = ({double input, double output});

/// How one of ST's priced sources lists a model's prices in `/models`: the
/// two `pricing` fields, each per [perTokens] tokens.
final class StPricing {
  const StPricing(this.input, this.output, this.perTokens);
  final String input, output;
  final int perTokens;
}

/// The only sources ST 1.19.0 prices, by API host (`public/scripts/openai.js`):
/// `calculateOpenRouterCost` in dollars per token, `calculateElectronHubCost`
/// and `calculateChutesCost` per million. ST's server renames Chutes'
/// `prompt`/`completion` to `input`/`output` before the client reads them
/// (`src/endpoints/backends/chat-completions.js`); this reads them as sent.
const stPricedSources = {
  'openrouter.ai': StPricing('prompt', 'completion', 1),
  'api.electronhub.ai': StPricing('input', 'output', 1000000),
  'llm.chutes.ai': StPricing('prompt', 'completion', 1000000),
};

/// ST's list prices, fetched once per source address.
final class StPriceBook {
  StPriceBook({this.sources = stPricedSources, Dio? client})
    : _client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              followRedirects: false,
            ),
          );
  final Map<String, StPricing> sources;
  final Dio _client;
  final _lists = <String, Future<Map<String, ModelPrice>>>{};

  /// [connection]'s model price, or null when ST has none for it.
  Future<ModelPrice?> lookup(ModelConnection connection, String apiKey) async {
    final pricing = sources[Uri.parse(connection.baseUrl).host];
    if (pricing == null ||
        connection.protocol != ModelProtocol.openAICompatible) {
      return null;
    }
    final base = connection.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final list = _lists[base] ??= _fetch(base, apiKey, pricing);
    try {
      return (await list)[connection.model];
    } catch (_) {
      // Unpriced this time; the next request asks again.
      if (identical(_lists[base], list)) _lists.remove(base);
      return null;
    }
  }

  Future<Map<String, ModelPrice>> _fetch(
    String base,
    String apiKey,
    StPricing pricing,
  ) async {
    final response = await _client.get<Object?>(
      '$base/models',
      options: Options(
        headers: {if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
      ),
    );
    final body = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    // OpenRouter sends prices as strings, the others as numbers.
    double? price(Object? value) =>
        value is num ? value.toDouble() : double.tryParse('$value');
    return {
      for (final model in ((body as Map)['data'] as List).whereType<Map>())
        if ((model['id'], model['pricing']) case (
          final String id,
          final Map prices,
        ))
          if ((price(prices[pricing.input]), price(prices[pricing.output]))
              case (final double input?, final double output?))
            id: (
              input: input / pricing.perTokens,
              output: output / pricing.perTokens,
            ),
    };
  }

  void close() => _client.close(force: true);
}

/// The cost a response reported, in US dollars: OpenRouter's `usage.cost`,
/// what the account was charged, plus with the author's own provider key
/// (`is_byok`) what that provider billed; else Claude Code's run cost.
double? upstreamCost(Map<String, dynamic> usage) {
  final cost = usage['cost'] ?? usage['total_cost_usd'];
  if (cost is! num || cost < 0) return null;
  final byok = switch (usage['cost_details']) {
    {'upstream_inference_cost': final num upstream}
        when usage['is_byok'] == true =>
      upstream,
    _ => 0,
  };
  return cost.toDouble() + byok;
}

/// A response's input and output tokens as OpenAI- or Anthropic-style usage
/// names them. Anthropic counts cached input apart; Codex already includes it.
({int? input, int? output}) usageTokens(Map<String, dynamic> usage) {
  int? count(String key) => switch (usage[key]) {
    final num n => n.toInt(),
    _ => null,
  };
  final input = count('input_tokens');
  return (
    input:
        count('prompt_tokens') ??
        (input == null
            ? null
            : input +
                  (count('cache_creation_input_tokens') ?? 0) +
                  (count('cache_read_input_tokens') ?? 0)),
    output: count('completion_tokens') ?? count('output_tokens'),
  );
}

/// Records every request made through the providers it wraps: the cost the
/// upstream reported, else ST's list price times the tokens, else none.
final class UsageMeter {
  UsageMeter(this._repository, {this._price});
  final StoryRepository _repository;
  final Future<ModelPrice?> Function(ModelConnection connection)? _price;

  /// Wraps [provider], keeping the capabilities callers test for.
  ModelProvider text(ModelProvider provider) => provider is RemoteJobControl
      ? _MeteredRemoteText(provider, this)
      : _MeteredText(provider, this);

  ImageProvider image(ImageProvider provider) => switch (provider) {
    WorkflowSource() => _MeteredWorkflow(provider, this),
    RemoteJobControl() => _MeteredRemoteImage(provider, this),
    _ => _MeteredImage(provider, this),
  };

  /// Never throws, and generation never waits for it: a lost record must
  /// not cost a chapter.
  Future<void> _record(
    ModelConnection connection,
    String kind,
    String? executionId,
    Map<String, dynamic> usage, {
    String? purpose,
    String? branchId,
    ({int input, int output}) Function()? estimate,
  }) async {
    try {
      final counted = usageTokens(usage);
      final guess = counted.input == null || counted.output == null
          ? estimate?.call()
          : null;
      final input = counted.input ?? guess?.input;
      final output = counted.output ?? guess?.output;
      var cost = upstreamCost(usage);
      var source = cost == null ? CostSource.unknown : CostSource.upstream;
      if (cost == null && kind == 'text' && input != null && output != null) {
        ModelPrice? price;
        try {
          price = await _price?.call(connection);
        } catch (_) {
          // An unreachable price list leaves the request unpriced.
        }
        if (price != null) {
          cost = input * price.input + output * price.output;
          source = CostSource.stPricing;
        }
      }
      await _repository.recordUsage(
        connection: connection,
        kind: kind,
        purpose: purpose,
        branchId: branchId,
        executionId: executionId,
        inputTokens: input,
        outputTokens: output,
        estimated: guess != null,
        costUsd: cost,
        source: source,
        usage: usage,
      );
    } catch (e) {
      stderr.writeln('SillyDraft: usage not recorded: $e');
    }
  }
}

class _MeteredText implements ModelProvider {
  _MeteredText(this._inner, this._meter);
  final ModelProvider _inner;
  final UsageMeter _meter;
  @override
  ModelConnection get config => _inner.config;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    final output = StringBuffer();
    GenerationFinished? finish;
    try {
      await for (final event in _inner.generate(
        request,
        cancellation: cancellation,
      )) {
        switch (event) {
          case TextDelta(:final text) || ReasoningDelta(:final text):
            output.write(text);
          case ToolCallReady():
            output.write(jsonEncode(event.toOpenAI()));
          case GenerationFinished():
            finish = event;
        }
        yield event;
      }
    } finally {
      // Output already streamed is billed even when the request then fails.
      if (finish != null || output.isNotEmpty) {
        unawaited(
          _meter._record(
            config,
            'text',
            request.executionId,
            finish?.usage ?? const {},
            purpose: request.usagePurpose,
            branchId: request.usageBranchId,
            estimate: () => (
              input: estimateTokens(
                request.completionText ?? jsonEncode(request.messages),
              ),
              output: estimateTokens('$output'),
            ),
          ),
        );
      }
    }
  }

  @override
  Future<List<String>> listModels() => _inner.listModels();
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      _inner.validateParameters(request);
  @override
  void close() => _inner.close();
}

final class _MeteredRemoteText extends _MeteredText
    implements RemoteJobControl {
  _MeteredRemoteText(super._inner, super._meter);
  @override
  Future<void> cancelRemote(String executionId) =>
      (_inner as RemoteJobControl).cancelRemote(executionId);
}

class _MeteredImage implements ImageProvider {
  _MeteredImage(this._inner, this._meter);
  final ImageProvider _inner;
  final UsageMeter _meter;
  @override
  ModelConnection get config => _inner.config;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final image = await _inner.generate(
      request,
      references: references,
      cancellation: cancellation,
    );
    unawaited(
      _meter._record(
        config,
        'image',
        request.executionId,
        image.usage,
        purpose: request.usagePurpose,
        branchId: request.usageBranchId,
      ),
    );
    return image;
  }

  @override
  void close() => _inner.close();
}

final class _MeteredWorkflow extends _MeteredImage implements WorkflowSource {
  _MeteredWorkflow(super._inner, super._meter);
  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) =>
      (_inner as WorkflowSource).readWorkflow(filename);
}

final class _MeteredRemoteImage extends _MeteredImage
    implements RemoteJobControl {
  _MeteredRemoteImage(super._inner, super._meter);
  @override
  Future<void> cancelRemote(String executionId) =>
      (_inner as RemoteJobControl).cancelRemote(executionId);
}
