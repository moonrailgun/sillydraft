import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/crash_logging.dart';
import 'package:sillydraft/app/crash_log_button.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('sd-handlers-');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('Flutter and platform handlers persist stacks and preserve existing handlers', () {
    final oldFlutter = FlutterError.onError;
    final oldPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = oldFlutter;
      PlatformDispatcher.instance.onError = oldPlatform;
    });
    var forwardedFlutter = 0;
    var forwardedPlatform = 0;
    FlutterError.onError = (_) => forwardedFlutter++;
    PlatformDispatcher.instance.onError = (_, _) {
      forwardedPlatform++;
      return false;
    };
    installLocalErrorHandlers(LocalErrorLog.open(directory, version: 'test'));
    FlutterError.onError!(
      FlutterErrorDetails(
        exception: StateError('widget failure'),
        stack: StackTrace.fromString('build:10'),
      ),
    );
    expect(
      PlatformDispatcher.instance.onError!(
        StateError('async failure'),
        StackTrace.fromString('future:20'),
      ),
      isFalse,
    );
    expect(forwardedFlutter, 1);
    expect(forwardedPlatform, 1);
    final text = directory
        .listSync()
        .whereType<File>()
        .single
        .readAsStringSync();
    for (final part in [
      'widget failure',
      'build:10',
      'async failure',
      'future:20',
    ]) {
      expect(text, contains(part));
    }
  });

  test('folder opening creates the native log directory and reports launch failures', () async {
    final native = const MethodChannel('app.sillydraft/diagnostics');
    final paths = const MethodChannel('plugins.flutter.io/path_provider');
    final target = Directory('${directory.path}/日志 with spaces');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (
      call,
    ) async {
      expect(call.method, 'getLogDirectory');
      return target.path;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => directory.path,
    );
    addTearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
      binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, null);
    });
    final expected = Platform.isWindows
        ? target
        : Directory('${directory.path}/logs');
    await openCrashLogDirectory(
      launch: (uri) async {
        expect(uri, expected.uri);
        expect(expected.existsSync(), isTrue);
        return true;
      },
    );
    await expectLater(
      openCrashLogDirectory(launch: (_) async => false),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('log folder button shows a launcher failure and allows retry', (
    tester,
  ) async {
    const native = MethodChannel('app.sillydraft/diagnostics');
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    final target = Directory('${directory.path}/logs');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      native,
      (_) async => target.path,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      paths,
      (_) async => directory.path,
    );
    var succeed = false;
    var launches = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (
      call,
    ) async {
      expect(call.method, 'launch');
      expect((call.arguments as Map)['url'], target.uri.toString());
      expect(target.existsSync(), isTrue);
      launches++;
      return succeed;
    });
    addTearDown(() {
      for (final channel in [native, paths, launcher]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
    });
    await tester.pumpWidget(
      testHost(
        const Padding(padding: EdgeInsets.all(16), child: CrashLogButton()),
      ),
    );
    Future<void> openAndWait() async {
      await tester.tap(find.text('打开崩溃日志目录'));
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.text('正在打开…').evaluate().isEmpty) break;
      }
      await tester.pumpAndSettle();
    }

    await openAndWait();
    expect(launches, 1);
    expect(find.textContaining('无法打开崩溃日志目录：'), findsOneWidget);
    succeed = true;
    await openAndWait();
    expect(launches, 2);
    expect(find.textContaining('无法打开崩溃日志目录：'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
