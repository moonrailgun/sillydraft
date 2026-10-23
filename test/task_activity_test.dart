import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

// Active progress indicators intentionally never settle.
Future<void> pumpActivity(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
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
        await services.repository.updateTask(
          running.id,
          status: TaskStatus.failed,
          error: '测试失败',
        );
        await tester.pumpAndSettle();
        expect(indicator, findsNothing);
        expect(find.text('生成任务'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
