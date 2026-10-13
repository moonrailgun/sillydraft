import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/presets/preset_screen.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft/features/resources/writing_profile.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';
import 'support/finders.dart';

const _preset = {
  'name': '雾港文风',
  'temperature': 1.0,
  'prompts': [
    {
      'identifier': 'main',
      'name': 'Main',
      'role': 'system',
      'content': '写悬疑小说。',
    },
    {'identifier': 'chatHistory', 'name': 'Chat History', 'marker': true},
  ],
  'prompt_order': [
    {
      'character_id': 100001,
      'order': [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
      ],
    },
  ],
};

void main() {
  testWidgets('preset edits autosave only to this branch and can be reset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    final branch = novel.activeBranchId;
    final original = await services.library.import(
      Uint8List.fromList(utf8.encode(jsonEncode(_preset))),
      filename: 'fog.json',
      kind: ResourceKind.preset,
    );
    await repo.setSetting('writing/$branch', {'presetId': original.id});
    final chapter = await repo.createChapter(branchId: branch);
    final other = await repo.forkBranch(
      branchId: branch,
      name: '另一条线',
      atChapterId: chapter.id,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(PresetScreen(branchId: branch)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('雾港文风'), findsWidgets);
    expect(find.text('1.00'), findsOneWidget, reason: 'temperature shown');
    expect(find.text('未设置'), findsWidgets, reason: 'absent samplers');
    expect(find.byKey(const Key('preset-save')), findsNothing);

    // Sampler: drag temperature to the far left (0).
    await tester.drag(
      find.byKey(const Key('sampler-temperature')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('0.00'), findsOneWidget);
    expect(find.byKey(const Key('preset-save')), findsNothing);
    expect(find.text('已自定义 · 已自动保存'), findsOneWidget);

    // Prompt manager: add an entry.
    await tester.ensureVisible(find.byKey(const Key('prompt-add')));
    await tester.tap(find.byKey(const Key('prompt-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('prompt-content')), '多写环境描写。');
    await tester.tap(find.text('添加条目'));
    await tester.pumpAndSettle();
    expect(find.textContaining('新条目'), findsOneWidget);

    final setting = (await repo.getSetting('writing/$branch'))!;
    expect(setting['presetId'], original.id);
    final saved = (setting['presetOverrides'] as Map)[original.id] as Map;
    expect(saved['temperature'], 0.0);
    final added = (saved['prompts'] as List).cast<Map>().singleWhere(
      (p) => p['content'] == '多写环境描写。',
    );
    final order =
        ((saved['prompt_order'] as List).single as Map)['order'] as List;
    expect(
      order.cast<Map>().any(
        (i) => i['identifier'] == added['identifier'] && i['enabled'] == true,
      ),
      isTrue,
    );
    expect(
      (await repo.getResource(original.id)).data['temperature'],
      1.0,
      reason: 'the original version is untouched',
    );

    // The assistant uses the preset by default and can be switched off.
    var context = await WritingContext.load(services, branch);
    expect(context.assistantPreset?.name, '雾港文风');
    expect(context.preset?.raw['temperature'], 0.0);
    expect(context.assistantPreset?.raw['temperature'], 0.0);
    expect(
      (await WritingContext.load(
        services,
        other.id,
      )).preset?.raw['temperature'],
      1.0,
    );
    expect(await repo.listResources(kind: ResourceKind.preset), hasLength(1));
    await tester.ensureVisible(find.byKey(const Key('assistant-uses-preset')));
    await tester.tap(find.byKey(const Key('assistant-uses-preset')));
    await tester.pumpAndSettle();
    context = await WritingContext.load(services, branch);
    expect(context.preset?.name, '雾港文风', reason: 'prose still uses it');
    expect(context.assistantPreset, isNull);

    await services.library.edit(original.id, {
      ...original.data,
      'name': '雾港文风 新版',
    });

    // Reopening preserves the branch copy; reset returns to the library data.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(WritingProfileScreen(branchId: branch)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-preset-panel')));
    await tester.pumpAndSettle();
    expect(find.text('0.00'), findsOneWidget);
    expect(find.text('已自定义 · 已自动保存'), findsOneWidget);
    await tester.tap(find.text('雾港文风 · 已自定义').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('不使用预设（SillyDraft 默认）').last);
    await tester.pumpAndSettle();
    expect((await WritingContext.load(services, branch)).preset, isNull);
    await tester.tap(find.text('不使用预设（SillyDraft 默认）').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('雾港文风 · 已自定义').last);
    await tester.pumpAndSettle();
    expect(find.text('0.00'), findsOneWidget);
    expect(find.text('已自定义 · 已自动保存'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preset-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复').last);
    await tester.pumpAndSettle();
    expect(find.text('1.00'), findsOneWidget);
    expect(find.text('已自定义 · 已自动保存'), findsNothing);
    expect(
      (await WritingContext.load(services, branch)).preset?.raw['temperature'],
      1.0,
    );

    // Returning to the profile and saving it must retain the autosaved override.
    await tester.drag(
      find.byKey(const Key('sampler-temperature')),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(findAction('返回'));
    await tester.pumpAndSettle();
    expect(find.text('已自定义 · 仅当前分支生效'), findsOneWidget);
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(
      (await WritingContext.load(services, branch)).preset?.raw['temperature'],
      0.0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a preset\'s detail page previews its samplers and prompts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final resource = await services.library.import(
      Uint8List.fromList(utf8.encode(jsonEncode(_preset))),
      filename: 'fog.json',
      kind: ResourceKind.preset,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(ResourceDetailScreen(resourceId: resource.id)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('采样参数'), findsOneWidget);
    expect(find.textContaining('temperature  1.0'), findsOneWidget);
    expect(find.textContaining('启用 2 / 2'), findsOneWidget);
    expect(find.byKey(const Key('preset-prompt-main')), findsOneWidget);
    expect(find.text('写悬疑小说。'), findsOneWidget);
    expect(find.text('动态标记 · 生成时填入'), findsOneWidget);
    expect(find.text('原始 JSON'), findsOneWidget);
    await tester.tap(find.byKey(const Key('preset-prompt-main')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a preset\'s continue_prefill is marked as not in effect', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final resource = await services.library.import(
      Uint8List.fromList(
        utf8.encode(jsonEncode({..._preset, 'continue_prefill': true})),
      ),
      filename: 'fog.json',
      kind: ResourceKind.preset,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(ResourceDetailScreen(resourceId: resource.id)),
      ),
    );
    await tester.pumpAndSettle();
    final mark = find.byKey(const Key('preset-ignored-continue_prefill'));
    expect(mark, findsOneWidget);
    expect(find.textContaining('不生效'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(mark));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.textContaining('不生效'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
