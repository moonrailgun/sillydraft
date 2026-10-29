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
    testWidgets('highlight count defaults to AI and persists at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1500);
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
      Future<void> mount() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(const SettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();
      }

      bool selected(String text) => tester
          .widget<ChoicePill>(find.widgetWithText(ChoicePill, text))
          .selected;
      await mount();
      expect(selected('由 AI 决定'), isTrue);
      for (var count = 1; count <= 6; count++) {
        expect(find.text('$count 张'), findsOneWidget);
      }
      await tester.tap(find.text('4 张'));
      await tester.pumpAndSettle();
      expect(selected('4 张'), isTrue);
      expect(await services.repository.getSetting('chapterHighlights'), {
        'count': 4,
      });
      await tester.pumpWidget(const SizedBox());
      await mount();
      expect(selected('4 张'), isTrue);
      await tester.tap(find.text('由 AI 决定'));
      await tester.pumpAndSettle();
      expect(selected('由 AI 决定'), isTrue);
      expect(await services.repository.getSetting('chapterHighlights'), {
        'count': null,
      });
      expect(tester.takeException(), isNull);
    });
  }
}
