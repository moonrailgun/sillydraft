import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

/// Screenshots of the update prompt against a local stand-in for GitHub:
///
///   flutter drive --driver=test_driver/native_verification.dart \
///     --target=integration_test/update_prompt_test.dart -d DEVICE
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('startup prompt, settings and manual check', (tester) async {
    Future<void> waitFor(Finder finder) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsWidgets);
      await tester.pumpAndSettle();
    }

    // Pinned so a release bumping pubspec.yaml past v0.2.0 keeps this valid.
    PackageInfo.setMockInitialValues(
      appName: 'SillyDraft',
      packageName: 'com.moonrailgun.sillydraft',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    );
    var latest = 'v0.2.0';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) {
      final version = latest.substring(1);
      r.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'tag_name': latest,
            'html_url':
                'https://github.com/moonrailgun/sillydraft/releases/tag/$latest',
            'body':
                '- feat(reader): 阅读器支持跨章连续自动滚动\n'
                '- fix(presets): 停用的正则规则显示为灰色\n'
                '- fix(core): 旧版应用不再降级写入新版作品库\n\n'
                '### 安装\n\n'
                '- Android：下载 APK 安装。',
            'assets': [
              {
                'name': 'sillydraft-$version-android.apk',
                'browser_download_url':
                    'https://example.test/sillydraft-$version-android.apk',
              },
            ],
          }),
        )
        ..close();
    });

    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      updateEndpoint: Uri.parse('http://127.0.0.1:${server.port}/latest'),
    );
    final captureKey = GlobalKey();
    final captures = <String, String>{};
    Future<void> capture(String name) async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(
        pixelRatio: tester.view.devicePixelRatio,
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      captures[name] = base64Encode(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: SillyDraftApp(services: services),
      ),
    );
    // The automatic check runs after the first frame.
    await waitFor(find.text('发现新版本 0.2.0'));
    await capture('update-dialog');
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(
      (await services.repository.getSetting('updateCheck'))!['at'],
      isA<int>(),
    );

    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-version')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await capture('update-settings');

    latest = 'v0.1.0';
    await tester.tap(find.byKey(const Key('settings-check-update')));
    await waitFor(find.text('已是最新版本'));
    await capture('update-latest');

    await services.close();
    binding.reportData = {
      'platform': Platform.operatingSystem,
      'captures': captures,
    };
  });
}
