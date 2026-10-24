import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class _RecordingWakelock extends WakelockPlusMacOSPlugin {
  final calls = <bool>[];

  @override
  Future<void> toggle({required bool enable}) async => calls.add(enable);
}

// Active progress indicators intentionally never settle.
Future<void> pumpActivity(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late _RecordingWakelock wakelock;
  setUp(() {
    final platform = wakelockPlusPlatformInstance;
    wakelock = _RecordingWakelock();
    wakelockPlusPlatformInstance = wakelock;
    addTearDown(() => wakelockPlusPlatformInstance = platform);
  });

  testWidgets(
    'reader hides task activity with its toolbar and restores it on exit',
    (tester) async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      final novel = await services.repository.createNovel(title: '沉浸阅读');
      await services.repository.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('港口起雾了。'),
      );
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ReaderScreen(branchId: novel.activeBranchId),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-page'))),
      );
      await tester.pumpAndSettle();

      await services.repository.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.illustration,
        input: {},
      );
      await pumpActivity(tester);
      final activity = find.byKey(const Key('task-activity'));
      expect(activity, findsNothing);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-page'))),
      );
      await pumpActivity(tester);
      expect(activity.hitTestable(), findsOneWidget);
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('reader-page'))),
      );
      await pumpActivity(tester);
      expect(activity, findsNothing);
      final readerContext = tester.element(find.byType(ReaderScreen));
      showAppDialog<void>(
        context: readerContext,
        builder: (_) => const Center(child: Text('图片预览')),
      );
      await pumpActivity(tester);
      expect(activity, findsNothing);
      navigator.pop();
      await pumpActivity(tester);
      expect(activity, findsNothing);
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const PageScaffold(title: '其他页面', body: SizedBox()),
        ),
      );
      await pumpActivity(tester);
      expect(activity.hitTestable(), findsOneWidget);
      navigator.pop();
      await pumpActivity(tester);
      expect(activity, findsNothing);
      navigator.pop();
      await pumpActivity(tester);
      expect(activity.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop exit confirms active work and still saves drafts', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
    final novel = await services.repository.createNovel(title: '退出测试');
    await services.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {},
    );
    await tester.pumpWidget(SillyDraftApp(services: services));
    await pumpActivity(tester);
    var saved = 0;
    final owner = Object();
    services.registerDraft(owner, () async {
      saved++;
    });
    addTearDown(() => services.unregisterDraft(owner));

    final cancelled = tester.binding.handleRequestAppExit();
    final duplicate = tester.binding.handleRequestAppExit();
    await pumpActivity(tester);
    expect(find.text('仍有任务进行中'), findsOneWidget);
    expect(find.byKey(const Key('task-activity')), findsOneWidget);
    await tester.tap(find.text('继续等待'));
    await pumpActivity(tester);
    expect(await cancelled, AppExitResponse.cancel);
    expect(await duplicate, AppExitResponse.cancel);
    expect(saved, 0);

    final accepted = tester.binding.handleRequestAppExit();
    await pumpActivity(tester);
    await tester.tap(find.text('仍然退出'));
    await pumpActivity(tester);
    expect(await accepted, AppExitResponse.exit);
    expect(saved, 1);
  });

  testWidgets(
    'Android back leaves app only after confirmation, not on tab changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
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
        await tester.pump();
      });
      final novel = await services.repository.createNovel(title: '返回测试');
      await services.repository.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.writing,
        input: {},
      );
      var exits = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(SillyDraftApp(services: services));
      await pumpActivity(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AppBottomBar),
          matching: find.text('设置'),
        ),
      );
      await pumpActivity(tester);
      await tester.binding.handlePopRoute();
      await pumpActivity(tester);
      expect(find.text('仍有任务进行中'), findsNothing);
      expect(exits, 0);
      await tester.binding.handlePopRoute();
      await pumpActivity(tester);
      expect(find.text('仍有任务进行中'), findsOneWidget);
      await tester.tap(find.text('继续等待'));
      await pumpActivity(tester);
      expect(exits, 0);
      await tester.binding.handlePopRoute();
      await pumpActivity(tester);
      await tester.tap(find.text('仍然退出'));
      await pumpActivity(tester);
      expect(exits, 1);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'desktop' : 'phone'} shows tasks across novels and navigation',
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
        addTearDown(() => tester.pumpWidget(const SizedBox()));
        final first = await services.repository.createNovel(title: '第一部');
        final second = await services.repository.createNovel(title: '第二部');
        final wakeCalls = wakelock.calls;
        await tester.pumpWidget(SillyDraftApp(services: services));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('task-activity')), findsNothing);
        await tester.enterText(find.byType(EditableText), '保留搜索');

        final queued = await services.repository.createTask(
          branchId: first.activeBranchId,
          kind: TaskKind.writing,
          input: {},
        );
        final running = await services.repository.createTask(
          branchId: second.activeBranchId,
          kind: TaskKind.illustration,
          input: {},
        );
        await services.repository.updateTask(
          running.id,
          status: TaskStatus.running,
        );
        await pumpActivity(tester);
        expect(find.text('2 个任务进行中'), findsOneWidget);
        expect(wakeCalls, [true]);
        expect(
          tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text,
          '保留搜索',
        );
        final indicator = find.byKey(const Key('task-activity'));
        expect(tester.getRect(indicator).right, greaterThan(wide ? 1100 : 300));
        expect(tester.getRect(indicator).bottom, lessThan(100));

        if (!wide) {
          tester.view.physicalSize = const Size(320, 844);
          tester.platformDispatcher.textScaleFactorTestValue = 1.5;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await pumpActivity(tester);
          expect(tester.getRect(indicator).right, greaterThan(300));
          expect(tester.takeException(), isNull);
          tester.view.physicalSize = const Size(390, 844);
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await pumpActivity(tester);
        }

        final navigation = find.byType(wide ? AppSidebar : AppBottomBar);
        for (final label in ['资源', '设置']) {
          await tester.tap(
            find.descendant(of: navigation, matching: find.text(label)),
          );
          await pumpActivity(tester);
          expect(find.text('2 个任务进行中'), findsOneWidget);
        }
        await tester.tap(indicator);
        await pumpActivity(tester);
        expect(find.textContaining('请勿离开或关闭应用'), findsWidgets);
        await tester.tap(find.text('插画生成'));
        await pumpActivity(tester);
        expect(find.text('生成任务'), findsOneWidget);
        expect(find.text('2 个任务进行中'), findsOneWidget);

        await services.repository.updateTask(
          queued.id,
          status: TaskStatus.cancelled,
        );
        await pumpActivity(tester);
        expect(find.text('1 个任务进行中'), findsOneWidget);
        expect(wakeCalls, [true]);
        await services.repository.updateTask(
          running.id,
          status: TaskStatus.failed,
          error: '测试失败',
        );
        await tester.pumpAndSettle();
        expect(indicator, findsNothing);
        expect(wakeCalls, [true, false]);
        expect(find.text('生成任务'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
