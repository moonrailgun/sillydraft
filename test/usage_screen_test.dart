import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft/features/settings/usage_screen.dart';
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
    expect(find.text('近 30 天'), findsOneWidget);
    expect(find.text('今日 · \$1.50 · 1 次无价格'), findsOneWidget);
    await tester.tap(find.text('Token'));
    await tester.pumpAndSettle();
    expect(find.text('今日 · ≈2415 token'), findsOneWidget);
    await tester.tap(find.text('调用次数'));
    await tester.pumpAndSettle();
    expect(find.text('今日 · 3 次'), findsOneWidget);
    expect(find.text('网关 · gemini'), findsOneWidget);
    expect(find.text('2 次 · 输入 2000 · 输出 400 token'), findsOneWidget);
    expect(find.text('网关 · flash'), findsOneWidget);
    expect(find.text('1 次（1 次无价格） · 输入 ≈10 · 输出 ≈5 token'), findsOneWidget);
    // Per month the same three requests.
    expect(find.text('3 次（1 次无价格） · 输入 ≈2010 · 输出 ≈405 token'), findsOneWidget);
  });

  testWidgets(
    'daily chart fills gaps and distinguishes unknown and zero costs',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      final now = DateTime.now();
      String date(int offset) => DateTime(
        now.year,
        now.month,
        now.day + offset,
      ).toIso8601String().substring(0, 10);
      UsageTotal total(String label, {int unpriced = 0}) => UsageTotal(
        label: label,
        requests: 1,
        inputTokens: 10,
        outputTokens: 5,
        cost: 0,
        unpriced: unpriced,
        estimated: false,
        costEstimated: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usageProvider.overrideWith(
              (_) async => (
                months: [total(date(0).substring(0, 7), unpriced: 1)],
                models: [total('网关 · m')],
                days: [total(date(-2)), total(date(0), unpriced: 1)],
              ),
            ),
          ],
          child: testHost(const UsageScreen(), brightness: Brightness.dark),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('今日 · 无价格'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('usage-day-${date(-1)}')));
      await tester.pumpAndSettle();
      expect(find.text('${date(-1)} · 无请求'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('usage-day-${date(-2)}')));
      await tester.pumpAndSettle();
      expect(find.text('${date(-2)} · \$0.00'), findsOneWidget);
      await tester.tap(find.text('Token'));
      await tester.pumpAndSettle();
      expect(find.text('${date(-2)} · 15 token'), findsOneWidget);
      // Tooltip groups reset after their closing animation has settled.
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('empty usage keeps the empty state instead of a chart', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          usageProvider.overrideWith(
            (_) async => (
              months: <UsageTotal>[],
              models: <UsageTotal>[],
              days: <UsageTotal>[],
            ),
          ),
        ],
        child: testHost(const UsageScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有模型请求。每次请求结束后会记在这里。'), findsOneWidget);
    expect(find.text('近 30 天'), findsNothing);
  });
}
