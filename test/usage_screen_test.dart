import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft/features/settings/usage_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  testWidgets('usage scrolls from desktop gutters and keeps content centered', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final models = List.generate(
      30,
      (i) => UsageTotal(
        label: 'model $i',
        requests: 1,
        inputTokens: 10,
        outputTokens: 5,
        cost: 0,
        unpriced: 1,
        estimated: false,
        costEstimated: false,
      ),
    );
    for (final (windowWidth, paneWidth) in [
      (1440.0, 1440.0),
      (1440.0, 600.0),
      (390.0, 390.0),
    ]) {
      tester.view.physicalSize = Size(windowWidth, 800);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            usageProvider.overrideWith(
              (_) async => (
                months: [models.first],
                models: models,
                tools: <UsageTotal>[],
                books: <UsageTotal>[],
                days: <UsageTotal>[],
              ),
            ),
          ],
          child: testHost(
            Align(
              child: SizedBox(width: paneWidth, child: const UsageScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byType(ListView);
      final viewport = tester.getRect(list);
      expect(viewport.left, (windowWidth - paneWidth) / 2);
      expect(viewport.right, (windowWidth + paneWidth) / 2);
      final chart = tester.getRect(
        find
            .ancestor(of: find.text('近 30 天'), matching: find.byType(FCard))
            .first,
      );
      expect(chart.center.dx, windowWidth / 2);
      expect(chart.width, paneWidth > 800 ? 752 : paneWidth - 48);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: list, matching: find.byType(Scrollable)).first,
      );
      final before = scroll.position.pixels;
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: Offset(viewport.right - 12, viewport.center.dy),
          scrollDelta: const Offset(0, 200),
        ),
      );
      await tester.pumpAndSettle();
      expect(scroll.position.pixels, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
    // Month, unclassified tool and unassigned book cover the same requests.
    expect(
      find.text('3 次（1 次无价格） · 输入 ≈2010 · 输出 ≈405 token'),
      findsNWidgets(3),
    );
    expect(find.text('按工具'), findsOneWidget);
    expect(find.text('按书籍'), findsOneWidget);
    expect(find.text('未归属书籍'), findsOneWidget);
  });

  testWidgets('tool and book totals stay readable with long titles', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const bookTitle = '雾港来信：在漫长冬夜追寻失落灯塔的旅人';
    UsageTotal total(String label, double cost) => UsageTotal(
      label: label,
      requests: 2,
      inputTokens: 12345,
      outputTokens: 678,
      cost: cost,
      unpriced: 0,
      estimated: false,
      costEstimated: false,
    );
    for (final width in [390.0, 1000.0]) {
      tester.view.physicalSize = Size(width, 1000);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              usageProvider.overrideWith(
                (_) async => (
                  months: [total('2026-10', 3)],
                  models: [total('测试连接 · 模型', 3)],
                  tools: [total('正文生成', 1), total('生图', 2)],
                  books: [total(bookTitle, 2.5), total('第二本书', 0.5)],
                  days: <UsageTotal>[],
                ),
              ),
            ],
            child: testHost(
              Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(width < 400 ? 1.5 : 1),
                  ),
                  child: const UsageScreen(),
                ),
              ),
              brightness: brightness,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        for (final (label, price) in [
          ('正文生成', '\$1.00'),
          ('生图', '\$2.00'),
          (bookTitle, '\$2.50'),
          ('第二本书', '\$0.5000'),
        ]) {
          await tester.scrollUntilVisible(
            find.text(label),
            150,
            scrollable: scrollable,
          );
          await tester.pumpAndSettle();
          final row = find.ancestor(
            of: find.text(label),
            matching: find.byType(FTile),
          );
          expect(
            find.descendant(of: row, matching: find.text(price)),
            findsOneWidget,
          );
          for (final paragraph in tester.renderObjectList<RenderParagraph>(
            find.descendant(of: row, matching: find.byType(RichText)),
          )) {
            expect(paragraph.didExceedMaxLines, isFalse);
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    }
  });

  testWidgets('Codex estimates disclose their scope in every cost view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = StoryRepository.memory();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await repo.close();
    });
    final connection = ModelConnection(
      id: 'codex',
      name: 'Codex',
      baseUrl: '',
      model: 'gpt-6-astra',
      protocol: ModelProtocol.codexCli,
    );
    final usage = await tester.runAsync(() async {
      await repo.recordUsage(
        connection: connection,
        kind: 'image',
        inputTokens: 30000,
        outputTokens: 3000,
        costUsd: 0.297,
        source: CostSource.unknown,
        usage: {
          'cost_estimate': {'scope': 'conversation_only'},
        },
      );
      await repo.recordUsage(
        connection: connection.withModel('unknown'),
        kind: 'image',
        source: CostSource.unknown,
      );
      return (
        months: await repo.usageByMonth(),
        models: await repo.usageByModel(),
        tools: await repo.usageByTool(),
        books: await repo.usageByBook(),
        days: await repo.usageByDay(),
      );
    });
    const scope = 'Codex 对话模型估算，未含生图工具费';
    final summary = usageSummary(usage!.months);
    expect(summary.title, '累计 ≈\$0.2970 · 本月 ≈\$0.2970');
    expect(summary.note, contains(scope));
    expect(summary.note, contains('另有 1 次请求没有价格'));
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [usageProvider.overrideWith((_) async => usage)],
          child: testHost(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(1.5)),
                child: const UsageScreen(),
              ),
            ),
            brightness: brightness,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('今日 · ≈\$0.2970 · 1 次无价格 · $scope'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('按连接与模型'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final modelRow = find.ancestor(
        of: find.text('Codex · gpt-6-astra'),
        matching: find.byType(FTile),
      );
      expect(
        find.descendant(of: modelRow, matching: find.text('≈\$0.2970')),
        findsOneWidget,
      );
      expect(
        find.text('1 次 · 输入 30000 · 输出 3000 token\n$scope'),
        findsOneWidget,
      );
      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.textContaining(scope),
          matching: find.byType(RichText),
        ),
      )) {
        expect(paragraph.didExceedMaxLines, isFalse);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
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
                tools: [total('正文生成')],
                books: [total('测试作品')],
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
              tools: <UsageTotal>[],
              books: <UsageTotal>[],
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
