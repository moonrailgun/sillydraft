import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
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

  Future<AppServices> open(WidgetTester tester, {Uri? endpoint}) async {
    tester.view.physicalSize = const Size(1000, 2400);
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
      await services.close();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return services;
  }

  /// A local stand-in for GitHub's latest release, v0.2.0.
  Future<Uri> serve(WidgetTester tester) async {
    // Widget tests fake HttpClient; this one talks to a real local server.
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previous);
    final server = (await tester.runAsync(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ))!;
    addTearDown(() => server.close(force: true));
    server.listen((r) {
      r.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'tag_name': 'v0.2.0',
            'html_url': 'https://example.test/releases/v0.2.0',
            'body': '- feat(reader): 新功能',
            'assets': [],
          }),
        )
        ..close();
    });
    return Uri.parse('http://127.0.0.1:${server.port}/latest');
  }

  /// Taps 检查更新 and waits for the offer.
  Future<void> checkNow(WidgetTester tester, {int taps = 1}) async {
    await tester.runAsync(() async {
      for (var i = 0; i < taps; i++) {
        await tester.tap(find.byKey(const Key('settings-check-update')));
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
    await tester.pumpAndSettle();
  }

  testWidgets('settings shows the version; no endpoint, no update tiles', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('SillyDraft 0.1.0 (1)'), findsOneWidget);
    expect(find.byKey(const Key('settings-check-update')), findsNothing);
    expect(find.byKey(const Key('settings-auto-update')), findsNothing);
  });

  testWidgets('manual check offers a newer release and can skip it', (
    tester,
  ) async {
    final services = await open(tester, endpoint: await serve(tester));

    await tester.tap(find.byKey(const Key('settings-auto-update')));
    await tester.pumpAndSettle();
    expect((await services.repository.getSetting('update'))!['auto'], false);

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
    final setting = (await services.repository.getSetting('update'))!;
    expect(setting['skip'], '0.2.0');
    expect(setting['auto'], false);
    expect(
      (await services.repository.getSetting('updateCheck'))!['at'],
      isA<int>(),
    );
  });

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
