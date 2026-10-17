import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

final connection = ModelConnection(
  id: 'c1',
  name: '网关',
  baseUrl: 'https://gateway.example/v1',
  model: 'm1',
);

Stream<ProviderEvent> _reply(List<ProviderEvent> events) =>
    Stream.fromIterable(events);

/// Runs [provider] to the end, as a task does, and waits for its record.
Future<void> _drain(StoryRepository repo, ModelProvider provider) async {
  final written = repo.changes.first;
  await provider.generate(ProviderRequest(messages: const [])).drain<void>();
  await written.timeout(const Duration(seconds: 5));
}

final class _Painter implements ImageProvider, WorkflowSource {
  @override
  ModelConnection get config => connection;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async => GeneratedImage(
    bytes: Uint8List(1),
    usage: {'input_tokens': 7, 'output_tokens': 70},
  );
  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) async => {};
  @override
  void close() {}
}

void main() {
  late StoryRepository repo;
  setUp(() => repo = StoryRepository.memory());
  tearDown(() => repo.close());

  test('a cost the upstream reports is taken as it is', () async {
    final meter = UsageMeter(
      repo,
      price: (_) async => (input: 1.0, output: 1.0),
    );
    await _drain(
      repo,
      meter.text(
        ScriptProvider(
          connection,
          (_, _) => _reply([
            const TextDelta('好'),
            const GenerationFinished(
              'stop',
              usage: {
                'prompt_tokens': 10,
                'completion_tokens': 5,
                'cost': 0.002,
              },
            ),
          ]),
        ),
      ),
    );
    final total = (await repo.usageByModel()).single;
    expect(total.label, '网关 · m1');
    expect(total.requests, 1);
    expect(total.inputTokens, 10);
    expect(total.outputTokens, 5);
    expect(total.cost, 0.002);
    expect(total.unpriced, 0);
    expect(total.estimated, isFalse);
    expect(total.costEstimated, isFalse);
  });

  test('OpenRouter BYOK adds the upstream provider bill', () {
    expect(
      upstreamCost({
        'cost': 0.001,
        'is_byok': true,
        'cost_details': {'upstream_inference_cost': 0.02},
      }),
      closeTo(0.021, 1e-12),
    );
    expect(
      upstreamCost({
        'cost': 0.001,
        'cost_details': {'upstream_inference_cost': 0.001},
      }),
      0.001,
    );
    expect(upstreamCost({'total_cost_usd': 0.3}), 0.3);
    expect(upstreamCost({'cost': -1}), isNull);
  });

  test('without an upstream cost, ST list prices times the tokens', () async {
    final meter = UsageMeter(
      repo,
      price: (_) async => (input: 0.000001, output: 0.000004),
    );
    await _drain(
      repo,
      meter.text(
        ScriptProvider(
          connection,
          (_, _) => _reply([
            const GenerationFinished(
              'stop',
              usage: {'prompt_tokens': 1000, 'completion_tokens': 500},
            ),
          ]),
        ),
      ),
    );
    final total = (await repo.usageByMonth()).single;
    expect(total.cost, closeTo(0.003, 1e-12));
    expect(total.unpriced, 0);
  });

  test(
    'without any price the tokens are kept and the request unpriced',
    () async {
      final meter = UsageMeter(repo);
      await _drain(
        repo,
        meter.text(
          ScriptProvider(
            connection,
            (_, _) => _reply([
              const GenerationFinished(
                'stop',
                usage: {
                  'input_tokens': 3,
                  'cache_read_input_tokens': 100,
                  'cache_creation_input_tokens': 20,
                  'output_tokens': 4,
                },
              ),
            ]),
          ),
        ),
      );
      final total = (await repo.usageByModel()).single;
      expect(total.inputTokens, 123);
      expect(total.outputTokens, 4);
      expect(total.cost, 0);
      expect(total.unpriced, 1);
    },
  );

  test('a request cut off after output is estimated', () async {
    final meter = UsageMeter(
      repo,
      price: (_) async => (input: 0.0, output: 1.0),
    );
    final written = repo.changes.first;
    final events = meter
        .text(
          ScriptProvider(connection, (_, _) async* {
            yield const TextDelta('一二三四');
            throw const ProviderException('interrupted', '连接中断');
          }),
        )
        .generate(ProviderRequest(messages: const []));
    await expectLater(events.drain<void>(), throwsA(isA<ProviderException>()));
    await written.timeout(const Duration(seconds: 5));
    final total = (await repo.usageByModel()).single;
    expect(total.outputTokens, estimateTokens('一二三四'));
    expect(total.cost, estimateTokens('一二三四'));
    expect(total.estimated, isTrue);
    expect(total.costEstimated, isTrue);
  });

  test('a request failing before any output is not recorded', () async {
    final meter = UsageMeter(repo);
    final events = meter
        .text(
          ScriptProvider(connection, (_, _) async* {
            throw const ProviderException('http_error', '拒绝');
          }),
        )
        .generate(ProviderRequest(messages: const []));
    await expectLater(events.drain<void>(), throwsA(isA<ProviderException>()));
    await pumpEventQueue();
    expect(await repo.usageByModel(), isEmpty);
  });

  test('one execution id is recorded once', () async {
    final meter = UsageMeter(repo);
    final provider = meter.text(
      ScriptProvider(
        connection,
        (_, _) => _reply([
          const GenerationFinished('stop', usage: {'prompt_tokens': 1}),
        ]),
      ),
    );
    for (final retrieveOnly in [false, true]) {
      final written = repo.changes.first;
      await provider
          .generate(
            ProviderRequest(executionId: 'task-1', retrieveOnly: retrieveOnly),
          )
          .drain<void>();
      await written.timeout(const Duration(seconds: 5));
    }
    expect((await repo.usageByModel()).single.requests, 1);
  });

  test('a failing price lookup leaves generation untouched', () async {
    final meter = UsageMeter(repo, price: (_) async => throw StateError('x'));
    final written = repo.changes.first;
    final events = await meter
        .text(
          ScriptProvider(
            connection,
            (_, _) => _reply([
              const TextDelta('好'),
              const GenerationFinished('stop', usage: {'prompt_tokens': 1}),
            ]),
          ),
        )
        .generate(ProviderRequest(messages: const []))
        .toList();
    expect(events.whereType<TextDelta>().single.text, '好');
    await written.timeout(const Duration(seconds: 5));
    expect((await repo.usageByModel()).single.unpriced, 1);
  });

  test('images are recorded and still read ComfyUI workflows', () async {
    final painter = UsageMeter(repo).image(_Painter());
    expect(painter, isA<WorkflowSource>());
    final written = repo.changes.first;
    await painter.generate(ImageRequest(prompt: '雾港'));
    await written.timeout(const Duration(seconds: 5));
    final total = (await repo.usageByModel()).single;
    expect(total.inputTokens, 7);
    expect(total.unpriced, 1);
  });

  test('remote runner adapters can still confirm cancellation', () {
    final runner = ModelConnection(
      id: 'r',
      name: '执行器',
      baseUrl: 'https://runner.example',
      model: 'm',
      protocol: ModelProtocol.sillyDraftRunner,
    );
    final meter = UsageMeter(repo);
    final text = meter.text(
      RemoteModelProvider(config: runner, accessToken: 'token'),
    );
    final image = meter.image(
      RemoteImageProvider(config: runner, accessToken: 'token'),
    );
    addTearDown(text.close);
    addTearDown(image.close);
    expect(text, isA<RemoteJobControl>());
    expect(image, isA<RemoteJobControl>());
    expect(image, isNot(isA<WorkflowSource>()));
    expect(
      meter.text(ScriptProvider(connection, (_, _) => _reply([]))),
      isNot(isA<RemoteJobControl>()),
    );
  });

  group('ST list prices', () {
    late HttpServer server;
    late Map<String, dynamic> models;
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          r.uri.path == '/v1/models' ? jsonEncode(models) : '{}',
        );
        await r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    ModelConnection at(String model) => ModelConnection(
      id: 'or',
      name: 'or',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: model,
    );

    test('OpenRouter lists dollars per token', () async {
      models = {
        'data': [
          {
            'id': 'a/b',
            'pricing': {'prompt': '0.000003', 'completion': '0.000015'},
          },
        ],
      };
      final book = StPriceBook(
        sources: {'127.0.0.1': stPricedSources['openrouter.ai']!},
      );
      addTearDown(book.close);
      expect(await book.lookup(at('a/b'), ''), (
        input: 0.000003,
        output: 0.000015,
      ));
      expect(await book.lookup(at('missing'), ''), isNull);
    });

    test('ElectronHub lists dollars per million tokens', () async {
      models = {
        'data': [
          {
            'id': 'gpt',
            'pricing': {'input': 2, 'output': 8},
          },
        ],
      };
      final book = StPriceBook(
        sources: {'127.0.0.1': stPricedSources['api.electronhub.ai']!},
      );
      addTearDown(book.close);
      expect(await book.lookup(at('gpt'), ''), (
        input: 0.000002,
        output: 0.000008,
      ));
    });

    test('other hosts have no ST price', () async {
      final book = StPriceBook();
      addTearDown(book.close);
      expect(await book.lookup(at('a/b'), ''), isNull);
      expect(stPricedSources.keys, {
        'openrouter.ai',
        'api.electronhub.ai',
        'llm.chutes.ai',
      });
    });
  });
}
