import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

void main() {
  testWidgets('only archived works can be deleted, after confirming', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = StoryRepository.memory();
    final services = AppServices(repository: repo, secrets: MemorySecrets());
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    await repo.createNovel(title: '旧稿');
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();

    await tester.tap(findAction('作品操作'));
    await tester.pumpAndSettle();
    expect(find.text('删除作品'), findsNothing);
    await tester.tap(find.text('归档作品'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    await tester.tap(findAction('作品操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除作品'));
    await tester.pumpAndSettle();
    expect(find.text('删除“旧稿”？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FButton, '删除作品'));
    await tester.pumpAndSettle();

    expect(find.text('旧稿'), findsNothing);
    expect(
      await tester.runAsync(() => repo.listNovels(includeArchived: true)),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
