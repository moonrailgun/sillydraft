import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  testWidgets('iOS ignores a saved NSFW role and keeps ordinary images', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
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
    final image = ModelConnection(
      id: 'image',
      name: '插画',
      baseUrl: 'http://localhost:1',
      model: 'image',
      kind: ModelKind.image,
    );
    await services.saveConnection(image);
    await services.repository.setSetting('modelRoles', {'imageNsfw': 'image'});
    expect(await services.connectionFor('imageNsfw'), isNull);
    expect((await services.connectionFor('image'))?.id, 'image');
    expect(
      (await services.repository.getSetting('modelRoles'))?['imageNsfw'],
      'image',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final ordinary = find.byKey(const Key('role-image'));
    await tester.scrollUntilVisible(
      ordinary,
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.byKey(const Key('role-imageNsfw')), findsNothing);
    expect(find.textContaining('iOS 版不提供 NSFW'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final width in [390.0, 900.0]) {
    testWidgets(
      'image roles select engines and models independently at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = width == 390
            ? 1.3
            : 1;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final services = AppServices(
          repository: StoryRepository.memory(),
          secrets: MemorySecrets(),
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await services.close();
        });
        for (final id in ['normal', 'adult']) {
          await services.saveConnection(
            ModelConnection(
              id: id,
              name: id,
              baseUrl: 'http://localhost:1',
              model: 'first',
              models: ['first', 'second'],
              kind: ModelKind.image,
            ),
          );
        }
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(
              const SettingsScreen(),
              brightness: width == 390 ? Brightness.light : Brightness.dark,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(await services.connectionFor('imageNsfw'), isNull);
        final adult = find.byKey(const Key('role-imageNsfw'));
        await tester.scrollUntilVisible(
          adult,
          300,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(adult);
        await tester.pumpAndSettle();
        expect(find.text('未指定（NSFW 画面将停止生成）'), findsOneWidget);
        await tester.tap(adult);
        await tester.pumpAndSettle();
        await tester.tap(find.text('adult · second').last);
        await tester.pumpAndSettle();
        final normal = find.byKey(const Key('role-image'));
        await tester.ensureVisible(normal);
        await tester.pumpAndSettle();
        await tester.tap(normal);
        await tester.pumpAndSettle();
        await tester.tap(find.text('normal · first').last);
        await tester.pumpAndSettle();
        final normalChoice = await services.connectionFor('image');
        final adultChoice = await services.connectionFor('imageNsfw');
        expect((normalChoice?.id, normalChoice?.model), ('normal', 'first'));
        expect((adultChoice?.id, adultChoice?.model), ('adult', 'second'));
        expect(find.text('普通生图引擎'), findsOneWidget);
        expect(find.text('NSFW 生图引擎'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
