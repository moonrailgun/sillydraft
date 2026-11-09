import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/home_screen.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart'
    show AppBackButton, AppBottomBar, AppSidebar;
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft/features/update/update_prompt.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'SillyDraft',
      packageName: 'app.sillydraft.sillydraft',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );

  // HTTP completion invalidates providers outside the widget test's fake
  // clock. Pump both zones until all tabs' repository reads have caught up.
  Future<void> settleUpdates(WidgetTester tester) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsScreen)),
    );
    await tester.runAsync(() async {
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
        if (!container.read(settingProvider('updateCheck')).isLoading &&
            !container.read(settingProvider('update')).isLoading &&
            find
                .byType(FCircularProgress, skipOffstage: false)
                .evaluate()
                .isEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> recheck(
    WidgetTester tester, {
    Future<void> Function()? before,
  }) async {
    final state = tester.state<ConsumerState>(find.byType(HomeScreen));
    await tester.runAsync(() async {
      var done = false;
      final check = (() async {
        await before?.call();
        await checkUpdates(state.context, state.ref);
      })().whenComplete(() => done = true);
      await Future.wait([
        check.timeout(const Duration(seconds: 5)),
        (() async {
          for (var i = 0; i < 250 && !done; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            await tester.pump();
          }
        })(),
      ]);
    });
    await settleUpdates(tester);
  }

  Future<void> mount(
    WidgetTester tester,
    AppServices services, {
    bool home = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          home
              ? HomeScreen(
                  selectedIndex: HomeTab.settings,
                  onDestinationSelected: (_) {},
                  onExitRequested: () async {},
                )
              : const SettingsScreen(initialTab: SettingsTab.about),
        ),
      ),
    );
    await settleUpdates(tester);
    if (home) {
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
    }
  }

  Future<AppServices> open(
    WidgetTester tester, {
    Uri? endpoint,
    bool home = false,
    Size size = const Size(1000, 2400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      updateEndpoint: endpoint,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.close);
    });
    // These fixtures exercise update reminders independently of model setup.
    await services.saveConnection(
      ModelConnection(
        id: 'test',
        name: '测试',
        baseUrl: 'https://example.test/v1',
        model: 'test',
      ),
    );
    await mount(tester, services, home: home);
    return services;
  }

  /// A local stand-in for GitHub's latest release, v0.2.0.
  Future<Uri> serve(
    WidgetTester tester, {
    VoidCallback? onRequest,
    String Function()? latestVersion,
    bool Function()? fail,
  }) async {
    // Widget tests fake HttpClient; this one talks to a real local server.
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => server.close(force: true));
    server.listen((r) {
      onRequest?.call();
      if (fail?.call() ?? false) {
        r.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..close();
        return;
      }
      final version = latestVersion?.call() ?? '0.2.0';
      r.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'tag_name': 'v$version',
            'html_url': 'https://example.test/releases/v$version',
            'body': '- feat(reader): 新功能',
            'assets': [],
          }),
        )
        ..close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}/latest');
  }

  /// Opens the update entry and waits for the offer.
  Future<void> checkNow(
    WidgetTester tester, {
    int taps = 1,
    String key = 'settings-check-update',
  }) async {
    await tester.runAsync(() async {
      for (var i = 0; i < taps; i++) {
        await tester.tap(find.byKey(Key(key)));
      }
      // Real I/O: let the request, the setting write and the dialog land.
      for (
        var i = 0;
        i < 50 && find.text('发现新版本 0.2.0').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await settleUpdates(tester);
  }

  testWidgets('settings shows the version; no endpoint, no update tiles', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('SillyDraft 0.1.0 (1)'), findsOneWidget);
    expect(find.byKey(const Key('settings-check-update')), findsNothing);
    expect(find.byKey(const Key('settings-auto-update')), findsNothing);
  });

  testWidgets('startup waits for model setup before offering an update', (
    tester,
  ) async {
    var requests = 0;
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      updateEndpoint: await serve(tester, onRequest: () => requests++),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(services.close);
    });
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    expect(find.text('连接模型，开始 AI 创作'), findsOneWidget);
    expect(requests, 0);
    await tester.tap(find.text('去配置'));
    await tester.pumpAndSettle();
    expect(find.text('添加连接'), findsOneWidget);
    expect(requests, 0);
    // Startup retains the fake zone; advance its timers alongside real HTTP.
    await tester.runAsync(() async {
      await tester.tap(find.byType(AppBackButton));
      for (
        var i = 0;
        i < 50 && find.text('发现新版本 0.2.0').evaluate().isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('发现新版本 0.2.0'), findsOneWidget);
    expect(find.byKey(const Key('model-setup-dialog')), findsNothing);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
  });

  testWidgets('manual check offers a newer release and can skip it', (
    tester,
  ) async {
    final services = await open(tester, endpoint: await serve(tester));

    await tester.tap(find.byKey(const Key('settings-auto-update')));
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(
        () => services.repository.getSetting('update'),
      ))!['auto'],
      false,
    );

    // A second tap while the first check runs must not stack a dialog.
    await checkNow(tester, taps: 2);
    expect(find.text('发现新版本 0.2.0'), findsOneWidget);
    expect(find.textContaining('当前版本 0.1.0'), findsOneWidget);
    expect(find.textContaining('新功能'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text('跳过此版本'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 0.2.0'), findsNothing);
    final setting = (await tester.runAsync(
      () => services.repository.getSetting('update'),
    ))!;
    expect(setting['skip'], '0.2.0');
    expect(setting['auto'], false);
    expect(
      (await tester.runAsync(
        () => services.repository.getSetting('updateCheck'),
      ))!['at'],
      isA<int>(),
    );
  });

  testWidgets(
    'desktop shows an update above settings only when a release is available',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      var requests = 0;
      final services = await open(
        tester,
        endpoint: await serve(tester, onRequest: () => requests++),
        home: true,
        size: const Size(1280, 900),
      );
      int badge() => tester
          .widget<AppSidebar>(find.byType(AppSidebar))
          .destinations[HomeTab.settings]
          .badge;
      final entry = find.byKey(const Key('desktop-update'));
      final settings = find.widgetWithText(FSidebarItem, '设置');
      final settingsWithoutUpdate = tester.getRect(settings);
      expect(entry, findsNothing);
      expect(tester.widget<AppSidebar>(find.byType(AppSidebar)).footer, isNull);
      expect(find.text('检查更新'), findsOneWidget);
      expect(badge(), 0);

      await checkNow(tester);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(entry, findsOneWidget);
      expect(find.text('新版本 0.2.0'), findsOneWidget);
      expect(
        tester.getRect(entry).bottom + 8,
        lessThanOrEqualTo(tester.getRect(settings).top),
      );
      expect(tester.getRect(settings), settingsWithoutUpdate);
      expect(find.text('更新至 0.2.0'), findsOneWidget);
      expect(badge(), 0);

      // Recreate the provider scope: the daily throttle must not hide an offer.
      await tester.pumpWidget(const SizedBox());
      await mount(tester, services, home: true);
      expect(entry, findsOneWidget);
      expect(find.text('更新至 0.2.0'), findsOneWidget);
      expect(badge(), 0);
      await recheck(tester);
      expect(requests, 1);
      await checkNow(tester, key: 'desktop-update');
      expect(find.text('发现新版本 0.2.0'), findsOneWidget);
      expect(requests, 1);
      await tester.tap(find.text('跳过此版本'));
      await settleUpdates(tester);
      expect(find.text('更新至 0.2.0'), findsNothing);
      expect(find.text('检查更新'), findsOneWidget);
      expect(badge(), 0);
      expect(entry, findsNothing);
      expect(tester.widget<AppSidebar>(find.byType(AppSidebar)).footer, isNull);
      expect(tester.getRect(settings), settingsWithoutUpdate);
    },
  );

  testWidgets('failed recheck keeps the offer; no newer release clears it', (
    tester,
  ) async {
    var fail = false;
    var latest = '0.2.0';
    final services = await open(
      tester,
      endpoint: await serve(
        tester,
        fail: () => fail,
        latestVersion: () => latest,
      ),
      home: true,
    );
    await checkNow(tester);
    await tester.tap(find.text('稍后'));
    await settleUpdates(tester);
    fail = true;
    await recheck(
      tester,
      before: () async {
        final check = (await services.repository.getSetting('updateCheck'))!;
        await services.repository.setSetting('updateCheck', {
          ...check,
          'at': 0,
        });
      },
    );
    expect(find.text('更新至 0.2.0'), findsOneWidget);

    fail = false;
    latest = '0.1.0';
    await recheck(tester);
    expect(find.text('更新至 0.2.0'), findsNothing);
  });

  testWidgets(
    'phone settings badge survives later and clears when the release is skipped',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      await open(
        tester,
        endpoint: await serve(tester),
        home: true,
        size: const Size(390, 844),
      );
      int badge() => tester
          .widget<AppBottomBar>(find.byType(AppBottomBar))
          .destinations[HomeTab.settings]
          .badge;
      expect(badge(), 0);
      expect(find.byKey(const Key('desktop-update')), findsNothing);
      await checkNow(tester);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(badge(), 1);
      expect(find.text('更新至 0.2.0'), findsOneWidget);

      await checkNow(tester);
      await tester.tap(find.text('跳过此版本'));
      await settleUpdates(tester);
      expect(badge(), 0);
    },
  );

  testWidgets(
    'cached update is hidden after installing the offered version',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final services = await open(tester, endpoint: await serve(tester));
      await checkNow(tester);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(find.text('更新至 0.2.0'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      PackageInfo.setMockInitialValues(
        appName: 'SillyDraft',
        packageName: 'app.sillydraft.sillydraft',
        version: '0.2.0',
        buildNumber: '2',
        buildSignature: '',
      );
      await mount(tester, services, home: true);
      expect(find.text('新版本 0.2.0'), findsNothing);
      expect(find.text('更新至 0.2.0'), findsNothing);
    },
  );

  testWidgets(
    'on a phone the download spans the dialog below the other actions',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      await open(tester, endpoint: await serve(tester));
      await checkNow(tester);
      Rect button(String label) => tester.getRect(
        find.ancestor(of: find.text(label), matching: find.byType(FButton)),
      );
      final download = button('下载'),
          skip = button('跳过此版本'),
          later = button('稍后');
      expect(download.top, greaterThan(skip.bottom));
      expect(skip.top, later.top);
      expect(download.left, skip.left);
      expect(download.right, later.right);
    },
  );
}
