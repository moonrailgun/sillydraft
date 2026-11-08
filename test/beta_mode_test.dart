import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  for (final width in [390.0, 1000.0]) {
    testWidgets('beta setting persists across page reloads at $width', (
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
      await mount(const SettingsScreen());
      await tester.ensureVisible(betaSwitch);
      expect(tester.widget<FSwitch>(betaSwitch).value, isFalse);
      await tester.tap(betaSwitch);
      await tester.pumpAndSettle();
      expect(await services.repository.getSetting('beta'), {'enabled': true});

      await mount(const SettingsScreen());
      await tester.ensureVisible(betaSwitch);
      expect(tester.widget<FSwitch>(betaSwitch).value, isTrue);
      await tester.tap(find.text('Beta 模式'));
      await tester.pumpAndSettle();
      expect(tester.widget<FSwitch>(betaSwitch).value, isFalse);
      expect(await services.repository.getSetting('beta'), {'enabled': false});

      await mount(const SettingsScreen());
      await tester.ensureVisible(betaSwitch);
      expect(tester.widget<FSwitch>(betaSwitch).value, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
