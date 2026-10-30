import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/app/desktop_commands.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  for (final wide in [true, false]) {
    testWidgets(
      '${wide ? 'desktop' : 'phone'} destinations switch in place and retain filters',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1280, 900)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final services = AppServices(
          repository: StoryRepository.memory(),
          secrets: MemorySecrets(),
        );
        addTearDown(services.close);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        });
        await tester.pumpWidget(SillyDraftApp(services: services));
        await tester.pumpAndSettle();

        final navigation = find.byType(wide ? AppSidebar : AppBottomBar);
        Future<void> select(String label, int index) async {
          await tester.tap(
            find.descendant(of: navigation, matching: find.text(label)),
          );
          await tester.pumpAndSettle();
          expect(navigation, findsOneWidget);
          final selected = wide
              ? tester.widget<AppSidebar>(navigation).selectedIndex
              : tester.widget<AppBottomBar>(navigation).selectedIndex;
          expect(selected, index);
          expect(find.byType(AppBackButton), findsNothing);
          expect(Navigator.of(tester.element(navigation)).canPop(), isFalse);
        }

        await tester.enterText(find.byType(EditableText), '雾港');
        await tester.tap(find.text('已归档'));
        await select('资源', 1);
        await tester.enterText(find.byType(EditableText), '角色');
        await tester.tap(find.text('ST 预设'));
        await select('设置', 2);
        expect(find.byType(SettingsScreen), findsOneWidget);
        await select('资源', 1);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          '角色',
        );
        expect(
          tester
              .widget<ChoicePill>(find.widgetWithText(ChoicePill, 'ST 预设'))
              .selected,
          isTrue,
        );
        if (wide) {
          tester.view.physicalSize = const Size(390, 844);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<AppBottomBar>(find.byType(AppBottomBar))
                .selectedIndex,
            1,
          );
          expect(
            tester
                .widget<EditableText>(find.byType(EditableText))
                .controller
                .text,
            '角色',
          );
          tester.view.physicalSize = const Size(1280, 900);
          await tester.pumpAndSettle();
        }
        // The assistant belongs to a novel, so it is not a home destination.
        expect(
          find.descendant(of: navigation, matching: find.text('助手')),
          findsNothing,
        );
        await select('作品', 0);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          '雾港',
        );
        expect(
          tester
              .widget<ChoicePill>(find.widgetWithText(ChoicePill, '已归档'))
              .selected,
          isTrue,
        );
        await select('设置', 2);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('已归档'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('menu commands switch home tabs but return to an open novel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    await services.repository.createNovel(title: '雾港来信');
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();

    final commands = tester.widget<DesktopCommands>(
      find.byType(DesktopCommands),
    );
    commands.invoke(AppCommand.settings);
    await tester.pumpAndSettle();
    expect(find.byType(AppSidebar), findsOneWidget);
    expect(tester.widget<AppSidebar>(find.byType(AppSidebar)).selectedIndex, 2);
    commands.invoke(AppCommand.resources);
    await tester.pumpAndSettle();
    expect(tester.widget<AppSidebar>(find.byType(AppSidebar)).selectedIndex, 1);
    await tester.tap(find.text('作品'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('雾港来信'));
    await tester.pumpAndSettle();
    const sections = Key('workspace-sections');
    expect(find.byKey(sections), findsOneWidget);
    expect(Navigator.of(tester.element(find.byKey(sections))).canPop(), isTrue);
    commands.invoke(AppCommand.settings);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.byType(AppSidebar), findsNothing);
    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();
    expect(find.text('雾港来信'), findsWidgets);
    // Back on the open novel: its own section rail, not the home destinations.
    expect(find.byKey(sections), findsOneWidget);
    await tester.tap(find.byType(AppBackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(sections), findsNothing);
    expect(find.byType(AppSidebar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
