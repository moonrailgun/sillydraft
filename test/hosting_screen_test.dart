import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/remote/hosting_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets('sharing on shows the pairing code and link', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'SillyDraft',
      packageName: 'com.moonrailgun.sillydraft',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    // Tall viewport: the ListView builds the warning at the bottom lazily.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sd-hosting-ui'),
    ))!;
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
    );
    addTearDown(
      () => tester.runAsync(() async {
        await services.close();
        await dir.delete(recursive: true);
      }),
    );
    await tester.runAsync(() => services.hosting.setEnabled(true, port: 0));
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    tester
        .state<NavigatorState>(find.byType(Navigator).first)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => HostingScreen(addresses: () async => ['127.0.0.1']),
          ),
        );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(find.text('允许手机连接'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('sillydraft://connect?'), findsOneWidget);
    expect(find.textContaining('读写这台电脑上的全部作品'), findsOneWidget);

    // Turning sharing off leaves no stale code and no uncaught error.
    await tester.runAsync(() => services.hosting.setEnabled(false));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    expect(services.hosting.host, isNull);
    expect(find.byType(QrImageView), findsNothing);
    expect(find.textContaining('sillydraft://connect?'), findsNothing);
  });
}
