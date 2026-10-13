import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/presets/preset_screen.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft/features/resources/writing_profile.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

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
  testWidgets(
    'the preset panel tunes, extends and saves the novel\'s preset like ST',
    (tester) async {
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
      expect(find.byKey(const Key('preset-save')), findsOneWidget);

      // Prompt manager: add an entry.
      await tester.ensureVisible(find.byKey(const Key('prompt-add')));
      await tester.tap(find.byKey(const Key('prompt-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('prompt-content')),
        '多写环境描写。',
      );
      await tester.tap(find.text('添加条目'));
      await tester.pumpAndSettle();
      expect(find.textContaining('新条目'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('preset-save')));
      await tester.tap(find.byKey(const Key('preset-save')));
      await tester.pumpAndSettle();

      final bound =
          (await repo.getSetting('writing/$branch'))!['presetId'] as String;
      expect(bound, isNot(original.id), reason: 'saving makes a new version');
      final saved = await repo.getResource(bound);
      expect(saved.parentId, original.id);
      expect(saved.data['temperature'], 0.0);
      final added = (saved.data['prompts'] as List).cast<Map>().singleWhere(
        (p) => p['content'] == '多写环境描写。',
      );
      final order =
          ((saved.data['prompt_order'] as List).single as Map)['order'] as List;
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
      await tester.tap(find.byKey(const Key('assistant-uses-preset')));
      await tester.pumpAndSettle();
      context = await WritingContext.load(services, branch);
      expect(context.preset?.name, '雾港文风', reason: 'prose still uses it');
      expect(context.assistantPreset, isNull);
      expect(tester.takeException(), isNull);
    },
  );

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
}
