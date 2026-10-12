import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/maps/map_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets('leaving a dirty map can discard edits and return once', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final novel = await services.repository.createNovel(title: '未保存地图');
    final entry = await services.repository.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.map,
      name: '测试海岸',
      content: '',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => StoryMapScreen(entry: entry),
                  ),
                ),
                child: const Text('打开地图'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开地图'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加地点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新港口');
    await tester.tap(find.text('保存标记'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(find.text('打开地图'), findsOneWidget);
    expect(find.text('保存地图修改？'), findsNothing);
    expect(
      (await services.repository.getLoreEntry(
        branchId: entry.branchId,
        id: entry.id,
      )).data['points'],
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'phone map saves a route and removes dependent routes with a pin',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      final db = services.repository;
      addTearDown(services.close);
      final novel = await db.createNovel(title: '地图');
      final entry = await db.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.map,
        name: '海岸',
        content: '沿海旅行',
        data: {
          'points': [
            {'id': 'a', 'label': '港口', 'x': .2, 'y': .3},
            {'id': 'b', 'label': '灯塔', 'x': .7, 'y': .6},
          ],
          'routes': [],
        },
      );
      Widget screen(LoreEntry current) => ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: MaterialApp(home: StoryMapScreen(entry: current)),
      );
      await tester.pumpWidget(screen(entry));
      await tester.pumpAndSettle();
      await tester.tap(find.text('连接路线'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '沿海小径');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('港口'));
      await tester.tap(find.text('灯塔'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加路线'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存地图'));
      await tester.pumpAndSettle();
      var saved = await db.getLoreEntry(branchId: entry.branchId, id: entry.id);
      expect((saved.data['routes'] as List).single['pointIds'], ['a', 'b']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(screen(saved));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('地点 港口'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除地点标记'));
      await tester.tap(find.byTooltip('保存地图'));
      await tester.pumpAndSettle();
      saved = await db.getLoreEntry(branchId: entry.branchId, id: entry.id);
      expect(saved.data['routes'], isEmpty);
      expect((saved.data['points'] as List).length, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
