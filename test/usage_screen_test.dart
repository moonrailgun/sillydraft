import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  test('requests through the app providers are recorded', () async {
    // Real loopback traffic; the test binding's own HttpClient answers 400.
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      r.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      final chunk = {
        'choices': [
          {
            'delta': {'content': '好'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 3, 'completion_tokens': 1, 'cost': 0.01},
      };
      r.response.write('data: ${jsonEncode(chunk)}\n\ndata: [DONE]\n\n');
      await r.response.close();
    });
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final connection = ModelConnection(
      id: 'local',
      name: '本地',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'm',
    );
    await services.saveConnection(connection, apiKey: 'k');
    final provider = await services.provider(connection);
    final written = services.repository.changes.first;
    await provider
        .generate(
          ProviderRequest(
            messages: const [
              {'role': 'user', 'content': '你好'},
            ],
          ),
        )
        .drain<void>();
    await written;
    final total = (await services.repository.usageByModel()).single;
    expect(total.label, '本地 · m');
    expect(total.cost, 0.01);
  });

  testWidgets('settings totals what requests cost and opens the breakdown', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await services.close();
    });
    final gateway = ModelConnection(
      id: 'g',
      name: '网关',
      baseUrl: 'https://gateway.example/v1',
      model: 'gemini',
    );
    await tester.runAsync(() async {
      for (final cost in [1.25, 0.25]) {
        await services.repository.recordUsage(
          connection: gateway,
          kind: 'text',
          inputTokens: 1000,
          outputTokens: 200,
          costUsd: cost,
          source: CostSource.upstream,
        );
      }
      await services.repository.recordUsage(
        connection: gateway.withModel('flash'),
        kind: 'text',
        inputTokens: 10,
        outputTokens: 5,
        estimated: true,
        source: CostSource.unknown,
      );
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('累计 \$1.50 · 本月 \$1.50\n另有 1 次请求没有价格'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-usage')));
    await tester.pumpAndSettle();
    expect(find.text('网关 · gemini'), findsOneWidget);
    expect(find.text('2 次 · 输入 2000 · 输出 400 token'), findsOneWidget);
    expect(find.text('网关 · flash'), findsOneWidget);
    expect(find.text('1 次（1 次无价格） · 输入 ≈10 · 输出 ≈5 token'), findsOneWidget);
    // Per month the same three requests.
    expect(find.text('3 次（1 次无价格） · 输入 ≈2010 · 输出 ≈405 token'), findsOneWidget);
  });
}
