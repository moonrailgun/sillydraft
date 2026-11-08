import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/bookshelf/novel_dialog.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  for (final width in [390.0, 1000.0]) {
    testWidgets('beta setting persists and gates comic creation at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
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
      Future<void> mount(Widget page) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(page),
          ),
        );
        await tester.pumpAndSettle();
      }

      final betaSwitch = find.descendant(
        of: find.byKey(const Key('settings-beta')),
        matching: find.byType(FSwitch),
      );
      await mount(const NovelDialog());
      expect(find.text('作品类型'), findsNothing);
      expect(find.text('创建小说'), findsOneWidget);

      await mount(const SettingsScreen());
      await tester.ensureVisible(betaSwitch);
      expect(tester.widget<FSwitch>(betaSwitch).value, isFalse);
      await tester.tap(betaSwitch);
      await tester.pumpAndSettle();
      expect(await services.repository.getSetting('beta'), {'enabled': true});

      await mount(const NovelDialog());
      await tester.tap(find.text('小说').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('漫画').last);
      await tester.pumpAndSettle();
      expect(find.text('创建漫画'), findsOneWidget);

      await mount(const SettingsScreen());
      await tester.ensureVisible(betaSwitch);
      expect(tester.widget<FSwitch>(betaSwitch).value, isTrue);
      await tester.tap(find.text('Beta 模式'));
      await tester.pumpAndSettle();
      expect(tester.widget<FSwitch>(betaSwitch).value, isFalse);
      expect(await services.repository.getSetting('beta'), {'enabled': false});

      await mount(const NovelDialog());
      expect(find.text('作品类型'), findsNothing);
      await tester.enterText(find.byKey(const Key('novel-title')), '普通小说');
      await tester.ensureVisible(find.text('创建小说'));
      await tester.tap(find.text('创建小说'));
      await tester.pumpAndSettle();
      expect(
        (await services.repository.listNovels()).single.workFormat,
        WorkFormat.novel,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
