import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/settings/default_preset_setting.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  testWidgets('an unavailable default can be cleared from settings', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await services.close();
    });
    await services.repository.setSetting('writingDefaults', {
      'presetId': 'missing',
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          ListView(
            padding: const EdgeInsets.all(24),
            children: const [DefaultPresetSetting()],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('默认预设已失效，请重新选择或清除。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('default-preset-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不使用默认预设').last);
    await tester.pumpAndSettle();
    expect(await services.repository.getSetting('writingDefaults'), isEmpty);
    expect(find.text('默认预设已失效，请重新选择或清除。'), findsNothing);
    expect(find.text('先到资源库导入预设，再在这里选择。新建小说时会自动使用。'), findsOneWidget);
  });

  for (final width in [390.0, 1000.0]) {
    testWidgets(
      'default preset can be saved, reopened and cleared at width $width',
      (tester) async {
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
        await services.repository.storeResource(
          id: 'preset',
          kind: ResourceKind.preset,
          name: '日常写作预设',
          filename: 'preset.json',
          sourceHash: 'fixture',
          encryptedSource: [],
          data: {'temperature': 0.7},
        );
        Future<void> mount() async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [servicesProvider.overrideWithValue(services)],
              child: testHost(const SettingsScreen()),
            ),
          );
          await tester.pumpAndSettle();
        }

        await mount();
        final select = find.byKey(const Key('default-preset-select'));
        await tester.ensureVisible(select);
        await tester.tap(select);
        await tester.pumpAndSettle();
        await tester.tap(find.text('日常写作预设').last);
        await tester.pumpAndSettle();
        expect(await services.repository.getSetting('writingDefaults'), {
          'presetId': 'preset',
        });
        await tester.pumpWidget(const SizedBox());
        await mount();
        expect(find.text('日常写作预设'), findsOneWidget);
        final novel = await services.repository.createNovel(title: '新小说');
        expect(
          (await services.repository.getSetting(
            'writing/${novel.activeBranchId}',
          ))?['presetId'],
          'preset',
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(select);
        await tester.tap(select);
        await tester.pumpAndSettle();
        await tester.tap(find.text('不使用默认预设').last);
        await tester.pumpAndSettle();
        expect(
          (await services.repository.getSetting(
            'writingDefaults',
          ))?['presetId'],
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
