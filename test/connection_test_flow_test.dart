import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

class _Model implements ModelProvider {
  _Model(this.config, this.script);
  @override
  final ModelConnection config;
  final Stream<ProviderEvent> Function(GenerationCancellation) script;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => script(cancellation!);
  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => [];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest r) => [];
}

Future<List<ModelConnection>> _openAndTest(
  WidgetTester tester,
  Stream<ProviderEvent> Function(GenerationCancellation) script,
) async {
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final tested = <ModelConnection>[];
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
    modelProviderFactory: (c) async {
      tested.add(c);
      return _Model(c, script);
    },
  );
  addTearDown(services.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(const SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('添加连接'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(FTextFormField, '模型名称'),
    'gpt-test',
  );
  await tester.tap(find.byKey(const Key('connection-test')));
  await tester.pump();
  return tested;
}

void main() {
  testWidgets('testing a connection shows the model\'s reply without saving', (
    tester,
  ) async {
    final tested = await _openAndTest(tester, (_) async* {
      yield const TextDelta('连接正常');
      yield const GenerationFinished('stop', usage: {'total_tokens': 9});
    });
    await tester.pumpAndSettle();
    expect(tested.single.model, 'gpt-test', reason: 'uses the form as typed');
    expect(find.textContaining('模型正常返回'), findsOneWidget);
    expect(find.text('回复：连接正常'), findsOneWidget);
    expect(find.textContaining('用量 9 tokens'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
    // Testing does not save anything.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('尚未配置模型。你仍然可以离线编辑和阅读，添加连接后即可使用 AI 创作。'), findsOneWidget);
  });

  testWidgets('a failing connection explains why', (tester) async {
    await _openAndTest(tester, (_) async* {
      throw const ProviderException(
        'http_error',
        '模型服务拒绝请求，请检查连接、权限或额度',
        statusCode: 401,
      );
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('测试未通过'), findsOneWidget);
    expect(find.textContaining('HTTP 401'), findsOneWidget);
  });

  testWidgets('a test that hangs can be stopped', (tester) async {
    await _openAndTest(tester, (cancel) async* {
      final done = Completer<void>();
      cancel.onCancel(done.complete);
      await done.future;
      cancel.check();
    });
    await tester.pump();
    expect(find.text('停止测试'), findsOneWidget);
    await tester.tap(find.byKey(const Key('connection-test')));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试已取消'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);
  });
}
