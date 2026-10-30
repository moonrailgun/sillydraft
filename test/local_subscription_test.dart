import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/illustrations/illustration_request.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

Future<AppServices> _openDialog(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
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
  return services;
}

void main() {
  testWidgets('Codex subscriptions can serve text and illustration tasks', (
    tester,
  ) async {
    final services = await _openDialog(tester);
    await tester.tap(find.text('OpenAI 兼容接口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codex（本地订阅）').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();

    final saved = (await services.connections()).single;
    expect(saved.supportsText, isTrue);
    expect(saved.supportsImages, isTrue);
    expect((await services.connectionFor('image'))?.id, saved.id);
    expect(find.text('普通生图引擎'), findsOneWidget);
    expect(find.text('NSFW 生图引擎'), findsOneWidget);
    final provider = await services.imageProvider(saved);
    provider.close();

    final novel = await services.repository.createNovel(title: 'Codex 插画');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          IllustrationRequestScreen(branchId: novel.activeBranchId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('使用 Codex 订阅额度'), findsOneWidget);
    expect(find.text('参考图片 · 0/16'), findsOneWidget);
    await tester.ensureVisible(find.text('高级参数'));
    await tester.tap(find.text('高级参数'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不支持 seed 和采样步数'), findsOneWidget);
    expect(find.text('图片下载域名（可选）'), findsNothing);
  });

  testWidgets('a Claude Code subscription needs no endpoint or key', (
    tester,
  ) async {
    final services = await _openDialog(tester);
    await tester.tap(find.text('OpenAI 兼容接口'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code（本地订阅）').last);
    await tester.pumpAndSettle();

    expect(find.text('API Key'), findsNothing);
    expect(find.text('API 基础地址'), findsNothing);
    expect(find.text('高级参数'), findsNothing);
    expect(find.text('命令路径（可选）'), findsOneWidget);
    expect(find.text('检查安装与登录'), findsOneWidget);

    await tester.tap(find.text('保存连接'));
    await tester.pumpAndSettle();
    final saved = (await services.connections()).single;
    expect(saved.protocol, ModelProtocol.claudeCode);
    expect(saved.name, 'Claude Code');
    expect(saved.model, 'default');
    expect(saved.command, isEmpty);
    expect(saved.contextWindow, 200000);
    expect(find.textContaining('Claude Code（本地订阅） · 默认模型'), findsOneWidget);

    // Usable for the editing assistant (tools are emulated), never for images.
    expect((await services.connectionFor('editor'))?.id, saved.id);
    expect(await services.connectionFor('image'), isNull);
    expect(find.text('普通生图引擎'), findsNothing);
    expect(find.text('NSFW 生图引擎'), findsNothing);
    expect(find.text('编辑 Agent'), findsOneWidget);
  });

  testWidgets('advanced parameters show their labels unclipped', (
    tester,
  ) async {
    await _openDialog(tester);
    await tester.ensureVisible(find.text('高级参数'));
    await tester.tap(find.text('高级参数'));
    await tester.pumpAndSettle();
    final label = find.text('输出长度参数');
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    final header = tester.getRect(
      find
          .ancestor(
            of: find.text('高级参数'),
            matching: find.byWidgetPredicate((w) => w is FTappable),
          )
          .first,
    );
    // The floating label sits above its field; it must start below the tile
    // header, where the expansion clip begins.
    expect(tester.getRect(label).top, greaterThanOrEqualTo(header.bottom));
    expect(tester.takeException(), isNull);
  });
}
