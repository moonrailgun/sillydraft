import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../test/support/model_setup.dart';

/// Run with flutter drive --profile: widget tests and debug builds do not
/// exercise the Windows AOT code that previously crashed on local settings.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('local settings opens repeatedly and all tabs remain usable', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp(
      'sillydraft-settings-native-',
    );
    final repository = StoryRepository.open('${directory.path}/library.sqlite');
    await repository.setSetting('update', {'auto': false});
    final services = AppServices(
      repository: repository,
      secrets: MemorySecrets(),
      dataDirectory: directory,
      updateEndpoint: Uri.parse('http://127.0.0.1:1/releases/latest'),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await services.close();
      await directory.delete(recursive: true);
    });

    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    await skipModelSetup(tester);
    await tester.pumpAndSettle();
    final navigation = find.byType(AppSidebar);
    expect(navigation, findsOneWidget);
    final panels = <String, Finder>{
      '通用': find.text('外观'),
      '模型': find.text('模型连接'),
      '创作': find.text('本章亮点生图'),
      '关于': find.byKey(const Key('settings-crash-logs')),
    };
    for (var round = 0; round < 5; round++) {
      await tester.tap(
        find.descendant(of: navigation, matching: find.text('设置')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      for (final entry in panels.entries) {
        await tester.tap(find.text(entry.key).hitTestable());
        await tester.pumpAndSettle();
        expect(entry.value, findsOneWidget);
        expect(find.byKey(const Key('settings-remote')), findsNothing);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(
        find.descendant(of: navigation, matching: find.text('作品')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsNothing);
    }
  });
}
