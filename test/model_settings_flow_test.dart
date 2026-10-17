import 'dart:convert';
import 'dart:io';

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
  testWidgets('a connection moved outside this device keeps its key back', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await services.close();
    });
    ModelConnection at(String baseUrl) =>
        ModelConnection(id: 'c1', name: '我的模型', baseUrl: baseUrl, model: 'm');
    await services.saveConnection(
      at('https://api.example.com/v1'),
      apiKey: 'sk-test',
    );
    // What a paired phone can do over the shared database.
    await services.repository.setSetting('connections', {
      'items': [at('https://attacker.example/v1').raw],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAction('编辑连接'));
    await tester.pumpAndSettle();
    expect(
      find.text('此连接的地址或命令在本机之外被改动过，可能来自已配对的手机。请核对后重新输入密钥并保存。'),
      findsOneWidget,
    );
    await tester.tap(find.text('检查连接并获取模型'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接地址已在本机之外改动，请重新输入密钥'), findsOneWidget);
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(await services.secrets.read('endpoint/c1'), contains('api.example'));
  });

  testWidgets('a trust check that fails still warns', (tester) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: _Unreadable(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await services.close();
    });
    await services.repository.setSetting('connections', {
      'items': [
        ModelConnection(
          id: 'c1',
          name: '我的模型',
          baseUrl: 'https://api.example.com/v1',
          model: 'm',
        ).raw,
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAction('编辑连接'));
    await tester.pumpAndSettle();
    expect(
      find.text('此连接的地址或命令在本机之外被改动过，可能来自已配对的手机。请核对后重新输入密钥并保存。'),
      findsOneWidget,
    );
  });

  testWidgets('a local command moved outside this device runs only once '
      'confirmed', (tester) async {
    tester.view.physicalSize = const Size(1000, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await services.close();
    });
    ModelConnection cli(String command) => ModelConnection(
      id: 'cli',
      name: 'Claude Code',
      baseUrl: '',
      model: 'sonnet',
      protocol: ModelProtocol.claudeCode,
      command: command,
    );
    await services.saveConnection(cli('/usr/local/bin/claude'));
    // What a paired phone can do over the shared database; never run here.
    await services.repository.setSetting('connections', {
      'items': [cli('/nonexistent/sd-test/claude').raw],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAction('编辑连接'));
    await tester.pumpAndSettle();
    expect(find.text('此连接的命令在本机之外被改动过，可能来自已配对的手机。请核对命令后保存。'), findsOneWidget);
    await tester.tap(find.text('检查安装与登录'));
    await tester.pumpAndSettle();
    expect(find.text('命令在本机之外被改动过，请核对后保存'), findsOneWidget);
    await tester.tap(find.byKey(const Key('connection-test')));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('connection-test-result')),
        matching: find.text('命令在本机之外被改动过，请核对后保存'),
      ),
      findsOneWidget,
    );
    Future<void> save() async {
      await tester.ensureVisible(find.text('保存连接'));
      await tester.tap(find.text('保存连接'));
      await tester.pumpAndSettle();
      expect(find.text('确认使用此命令？'), findsOneWidget);
      expect(
        find.text('保存后，本机的生成任务会运行这个命令：\n/nonexistent/sd-test/claude'),
        findsOneWidget,
      );
    }

    await save();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(await services.secrets.read('endpoint/cli'), contains('/usr/local'));
    await save();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(await services.secrets.read('endpoint/cli'), contains('sd-test'));
  });

  testWidgets('NovelAI connection saves image models and its access token', (
    tester,
  ) async {
    final services = await openSettings(tester);
    await tester.tap(find.text('OpenAI 兼容接口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NovelAI（生图）').last);
    await tester.pumpAndSettle();
    expect(find.text('上下文 token 上限'), findsNothing);
    expect(find.byKey(const Key('connection-test')), findsNothing);
    await tester.enterText(
      find.widgetWithText(FTextFormField, 'API Key'),
      'novelai-test-token',
    );
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    final saved = (await services.connections()).single;
    expect(saved.protocol.name, 'novelAI');
    expect(saved.baseUrl, 'https://image.novelai.net');
    expect(saved.model, 'nai-diffusion-4-5-full');
    expect(
      await services.secrets.read('model/${saved.id}'),
      'novelai-test-token',
    );
    expect(await services.connectionFor('writing'), isNull);
    expect((await services.connectionFor('image'))!.id, saved.id);
    final provider = await services.imageProvider(saved);
    addTearDown(provider.close);
    await tester.tap(findAction('编辑连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    expect(
      await services.secrets.read('model/${saved.id}'),
      'novelai-test-token',
    );
  });

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

  testWidgets('a role with no saved choice can choose the model it falls '
      'back to', (tester) async {
    final services = await openSettings(tester);
    await tester.enterText(
      find.widgetWithText(FTextFormField, '模型名称'),
      'first',
    );
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    final id = (await services.connections()).single.id;
    final analysis = find.byKey(const Key('role-analysis'));
    await tester.ensureVisible(analysis);
    expect(
      find.descendant(
        of: analysis,
        matching: find.text('未指定（使用 我的模型 · first）'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('默认关闭'), findsOneWidget);
    await tester.tap(analysis);
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的模型 · first').last);
    await tester.pumpAndSettle();
    final roles = await services.repository.getSetting('modelRoles');
    expect(roles?['analysis'], id);
    expect(roles?['analysisModel'], 'first');
    expect(
      find.descendant(of: analysis, matching: find.text('我的模型 · first')),
      findsOneWidget,
    );
    expect(find.text('默认开启：已选资料整理模型「我的模型 · first」，整理用它。'), findsOneWidget);
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
      expect(find.text('开始生成'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('writing-model')));
      await tester.tap(find.byKey(const Key('writing-model')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的模型 · first').last);
      await tester.pumpAndSettle();
      expect(find.text('开始生成'), findsNothing);
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
      expect(find.text('模型名称'), findsNothing);
      expect(
        find.byKey(const Key('comfy-workflow-json')).hitTestable(),
        findsNothing,
      );
      await tester.ensureVisible(find.text('高级设置'));
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      for (final blank in ['', '  \n  ']) {
        await tester.enterText(
          find.byKey(const Key('comfy-workflow-json')),
          blank,
        );
        await tester.ensureVisible(find.text('解析 JSON'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('解析 JSON'));
        await tester.pumpAndSettle();
        expect(find.text('请先导入工作流文件，或粘贴 API 格式的 JSON'), findsOneWidget);
        expect(find.byKey(const Key('comfy-prompt-input')), findsNothing);
        expect(await services.connections(), isEmpty);
      }
      await tester.enterText(
        find.byKey(const Key('comfy-workflow-json')),
        jsonEncode(workflow['nodes']),
      );
      await tester.ensureVisible(find.text('解析 JSON'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('解析 JSON'));
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
      expect(saved.comfyWorkflow!.modelInput, isEmpty);
      expect(saved.model, 'workflow');
      expect(saved.comfyWorkflow!.outputNode, '9');
      expect(await services.connectionFor('writing'), isNull);
      expect((await services.connectionFor('image'))!.id, saved.id);
    },
  );
}

/// Refuses every read, as a locked secrets file would.
final class _Unreadable implements SecretStore {
  @override
  Future<String?> read(String key) async =>
      throw const FileSystemException('密钥文件暂时无法读取');
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}
