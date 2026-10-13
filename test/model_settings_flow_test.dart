import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft/features/agent/writing_request_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';
import 'support/finders.dart';
import 'comfyui_flow_test.dart' show workflow;

Future<AppServices> openSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
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
  await tester.tap(find.text('添加连接'));
  await tester.pumpAndSettle();
  return services;
}

void main() {
  testWidgets('save multiple models and choose a different model for writing', (
    tester,
  ) async {
    final services = await openSettings(tester);
    await tester.enterText(
      find.widgetWithText(FTextFormField, '模型名称'),
      'first\nsecond',
    );
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect((await services.connections()).single.models, ['first', 'second']);
    expect(await services.connectionFor('image'), isNull);
    final writing = find.byKey(const Key('role-writing'));
    await tester.ensureVisible(writing);
    await tester.tap(writing);
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的模型 · second').last);
    await tester.pumpAndSettle();
    expect((await services.connectionFor('writing'))!.model, 'second');
    await tester.tap(findAction('编辑连接'));
    await tester.pumpAndSettle();
    final field = tester.widget<FTextFormField>(
      find.widgetWithText(FTextFormField, '模型名称'),
    );
    expect(field, isNotNull);
    expect(find.text('first\nsecond'), findsOneWidget);
  });

  testWidgets(
    'writing uses the chosen model and changing it invalidates the preview',
    (tester) async {
      final services = await openSettings(tester);
      await tester.enterText(
        find.widgetWithText(FTextFormField, '模型名称'),
        'first\nsecond',
      );
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
      final novel = await services.repository.createNovel(title: '模型切换');
      final chapter = await services.repository.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('港口'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(WritingRequestScreen(chapter: chapter)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('writing-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的模型 · second').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览提示词'));
      await tester.pumpAndSettle();
      expect(find.textContaining('tokens · second'), findsOneWidget);
      expect(find.text('开始生成候选'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('writing-model')));
      await tester.tap(find.byKey(const Key('writing-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的模型 · first').last);
      await tester.pumpAndSettle();
      expect(find.text('开始生成候选'), findsNothing);
      expect(
        await services.repository.listTasks(branchId: chapter.branchId),
        isEmpty,
      );
    },
  );

  testWidgets(
    'ComfyUI configuration saves workflow bindings and serves only images',
    (tester) async {
      final services = await openSettings(tester);
      await tester.tap(find.text('OpenAI 兼容接口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ComfyUI（生图）').last);
      await tester.pumpAndSettle();
      expect(find.text('上下文 token 上限'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('comfy-workflow-json')),
        jsonEncode(workflow['nodes']),
      );
      await tester.ensureVisible(find.text('读取工作流'));
      await tester.tap(find.text('读取工作流'));
      await tester.pumpAndSettle();
      final binding = find.byKey(const Key('comfy-prompt-input'));
      await tester.ensureVisible(binding);
      await tester.tap(binding);
      await tester.pumpAndSettle();
      await tester.tap(find.text('6 · CLIPTextEncode · text').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
      final saved = (await services.connections()).single;
      expect(saved.protocol, ModelProtocol.comfyUI);
      expect(saved.baseUrl, 'http://127.0.0.1:8188');
      expect(saved.comfyWorkflow!.promptInput, '6.text');
      expect(saved.comfyWorkflow!.modelInput, '4.ckpt_name');
      expect(saved.comfyWorkflow!.outputNode, '9');
      expect(await services.connectionFor('writing'), isNull);
      expect((await services.connectionFor('image'))!.id, saved.id);
    },
  );
}
