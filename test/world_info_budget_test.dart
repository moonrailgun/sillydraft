import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/writing_request_screen.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

Future<AppServices> _services(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1500);
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
  return services;
}

Future<WorldInfoBudget> _stored(AppServices services) async =>
    WorldInfoBudget.fromJson(
      await services.repository.getSetting(WorldInfoBudget.settingKey),
    );

void main() {
  testWidgets('settings edit the world info budget with ST\'s ranges', (
    tester,
  ) async {
    final services = await _services(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final percent = find.byKey(const Key('world-info-budget'));
    final cap = find.byKey(const Key('world-info-budget-cap'));
    await tester.ensureVisible(cap);
    expect(find.text('世界书预算'), findsOneWidget);
    expect(find.text('占提示词上限的比例（%）'), findsOneWidget);
    expect(find.text('预算上限（token，0 为不限）'), findsOneWidget);
    // A fresh ST install's values.
    expect(find.descendant(of: percent, matching: find.text('25')), findsOne);
    expect(find.descendant(of: cap, matching: find.text('0')), findsOne);

    await tester.enterText(percent, '40');
    await tester.pumpAndSettle();
    await tester.enterText(cap, '8000');
    await tester.pumpAndSettle();
    var saved = await _stored(services);
    expect((saved.percent, saved.cap), (40, 8000));

    // Out of range: not saved, and said so.
    await tester.enterText(percent, '101');
    await tester.pumpAndSettle();
    expect(find.text('请输入 1 到 100 的整数'), findsOneWidget);
    await tester.enterText(cap, '70000');
    await tester.pumpAndSettle();
    expect(find.text('请输入 0 到 65536 的整数'), findsOneWidget);
    saved = await _stored(services);
    expect((saved.percent, saved.cap), (40, 8000));
  });

  testWidgets('budget drops show one summary that opens the budget setting', (
    tester,
  ) async {
    final services = await _services(tester);
    final repo = services.repository;
    await services.saveConnection(
      ModelConnection(
        id: 'local',
        name: '本地',
        baseUrl: 'http://localhost:1/v1',
        model: 'm',
      ),
    );
    final novel = await repo.createNovel(title: '雾港');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('港口'),
    );
    await repo.storeResource(
      id: 'book',
      kind: ResourceKind.worldBook,
      name: '雾港设定',
      filename: 'book.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: {
        'name': '雾港设定',
        'entries': {
          '1': {'uid': 1, 'constant': true, 'comment': '灯塔', 'content': '旧灯塔'},
          '2': {'uid': 2, 'constant': true, 'comment': '渡口', 'content': '老渡口'},
        },
      },
    );
    await repo.setSetting('writing/${novel.activeBranchId}', {
      'worldBookIds': ['book'],
    });
    await repo.setSetting(
      WorldInfoBudget.settingKey,
      const WorldInfoBudget(cap: 1).toJson(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(WritingRequestScreen(chapter: chapter)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览提示词'));
    await tester.pumpAndSettle();

    final alert = find.byKey(const Key('world-book-budget'));
    expect(alert, findsOneWidget);
    expect(
      find.descendant(
        of: alert,
        matching: find.textContaining(
          '世界书预算不够，2 个条目未放入。本次预算 1 token，受「预算上限」限制',
        ),
      ),
      findsOneWidget,
    );
    // The entries are listed under it, not as warnings of their own.
    expect(
      tester
          .widgetList<FAlert>(find.byType(FAlert))
          .map((a) => (a.title as Text).data!)
          .where((title) => title.contains('超出世界书预算')),
      isEmpty,
    );
    await tester.ensureVisible(find.text('未放入的条目（2）'));
    await tester.tap(find.text('未放入的条目（2）'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: alert,
        matching: find.textContaining('世界书条目 1「灯塔」超出世界书预算（1 token）'),
      ),
      findsOneWidget,
    );
    // A warning: the request can still start.
    expect(
      tester.widget<FButton>(find.widgetWithText(FButton, '开始生成候选')).onPress,
      isNotNull,
    );

    await tester.ensureVisible(find.text('调整世界书预算'));
    await tester.tap(find.text('调整世界书预算'));
    await tester.pumpAndSettle();
    final cap = find.byKey(const Key('world-info-budget-cap'));
    expect(find.descendant(of: cap, matching: find.text('1')), findsOne);
    await tester.enterText(cap, '0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect((await _stored(services)).cap, 0);
    // Checked again with the new budget.
    expect(find.byKey(const Key('world-book-budget')), findsNothing);
    expect(find.text('开始生成候选'), findsOneWidget);
  });
}
