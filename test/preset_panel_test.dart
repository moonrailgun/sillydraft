import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/presets/preset_screen.dart';
import 'package:sillydraft/features/resources/preset_prompt_editor.dart';
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
  testWidgets('preset tabs keep long prompt lists lazy and edits saved', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final repo = services.repository;
    final novel = await repo.createNovel(title: '长预设');
    final data = {
      ..._preset,
      'prompts': [
        for (var i = 0; i < 400; i++)
          {
            'identifier': 'entry-$i',
            'name': '条目 $i',
            'role': 'system',
            'content': '提示词内容 $i',
          },
      ],
      'prompt_order': [
        {
          'character_id': 100001,
          'order': [
            for (var i = 0; i < 400; i++)
              {'identifier': 'entry-$i', 'enabled': true},
          ],
        },
      ],
    };
    final original = await services.library.import(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
      filename: 'long.json',
      kind: ResourceKind.preset,
    );
    await repo.setSetting('writing/${novel.activeBranchId}', {
      'presetId': original.id,
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(PresetScreen(branchId: novel.activeBranchId)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FTabs), findsOneWidget);
    expect(find.byType(PresetPromptEditor), findsNothing);
    await tester.tap(find.text('提示词管理'));
    await tester.pumpAndSettle();
    final editor = find.byType(PresetPromptEditor);
    void expectLazy() => expect(
      find
          .descendant(of: editor, matching: find.byType(FSwitch))
          .evaluate()
          .length,
      inExclusiveRange(0, 20),
      reason: 'only viewport and cache rows should be built',
    );
    expectLazy();
    expect(find.byKey(const Key('prompt-enabled-entry-399')), findsNothing);
    final row = find.byKey(const Key('prompt-enabled-entry-35'));
    await tester.scrollUntilVisible(
      row,
      600,
      scrollable: find.descendant(
        of: editor,
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(row);
    await tester.tap(find.byKey(const Key('prompt-expand-entry-35')));
    await tester.pumpAndSettle();
    final up = find.byKey(const Key('prompt-up-entry-35'));
    await tester.ensureVisible(up);
    await tester.tap(up);
    await tester.pumpAndSettle();
    expectLazy();
    final setting = (await repo.getSetting('writing/${novel.activeBranchId}'))!;
    final saved = (setting['presetOverrides'] as Map)[original.id] as Map;
    final order = (saved['prompt_order'] as List).single['order'] as List;
    expect(order[34], {'identifier': 'entry-35', 'enabled': false});
    expect(order[35]['identifier'], 'entry-34');
    expect(order, hasLength(400));
    await tester.tap(find.text('采样参数'));
    await tester.pumpAndSettle();
    expect(find.text('1.00'), findsOneWidget);
    await tester.tap(find.text('提示词管理'));
    await tester.pumpAndSettle();
    tester
        .state<ScrollableState>(
          find.descendant(of: editor, matching: find.byType(Scrollable)),
        )
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(
      row,
      600,
      scrollable: find.descendant(
        of: editor,
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      tester
          .widget<FSwitch>(
            find.descendant(of: row, matching: find.byType(FSwitch)),
          )
          .value,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('preset regex toggles persist only in this branch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
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
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final longHtml = List.generate(
      80,
      (i) => '<div data-line="$i">\$1</div>',
    ).join('\n');
    final data = {
      ..._preset,
      'extensions': {
        'unknown': {'keep': true},
        'regex_scripts': [
          {
            'id': 'status',
            'scriptName': '顶部状态栏美化',
            'disabled': true,
            'markdownOnly': true,
            'findRegex': r'/\[STATUS\](.*?)\[\/STATUS\]/gs',
            'replaceString': '<b>\$1</b>',
            'placement': [2],
            'unknown': 'keep',
          },
          {
            'id': 'prompt',
            'promptOnly': true,
            'findRegex': '/雾/g',
            'replaceString': longHtml,
            'placement': [1],
          },
        ],
      },
    };
    final original = await services.library.import(
      Uint8List.fromList(utf8.encode(jsonEncode(data))),
      filename: 'fog.json',
      kind: ResourceKind.preset,
    );
    await repo.setSetting('writing/$branch', {'presetId': original.id});
    final other = await repo.forkBranch(branchId: branch, name: '另一条线');
    // Prime the display cache before changing the profile.
    expect((await repo.displayContext(branch)).rules.first['disabled'], true);

    Widget panel() => ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(PresetScreen(branchId: branch)),
    );
    final status = find.byKey(const Key('preset-regex-0'));
    final prompt = find.byKey(const Key('preset-regex-1'));
    bool enabled(Finder row) => tester
        .widget<FSwitch>(
          find.descendant(of: row, matching: find.byType(FSwitch)),
        )
        .value;
    double opacity(Finder row) => tester
        .widgetList<Opacity>(
          find.ancestor(of: row, matching: find.byType(Opacity)),
        )
        .fold(1, (value, widget) => value * widget.opacity);

    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    expect(find.text('预设正则'), findsOneWidget);
    await tester.tap(find.text('预设正则'));
    await tester.pumpAndSettle();
    expect(find.text('启用 1 / 2'), findsOneWidget);
    expect(find.text('顶部状态栏美化'), findsOneWidget);
    expect(find.text('正则 2'), findsOneWidget);
    expect(enabled(status), isFalse);
    expect(enabled(prompt), isTrue, reason: 'missing disabled defaults to on');
    final disabledOpacity = tester.element(status).theme.colors.disabledOpacity;
    expect(opacity(status), disabledOpacity);
    expect(opacity(prompt), 1);
    final expression = find.descendant(
      of: status,
      matching: find.text(r'/\[STATUS\](.*?)\[\/STATUS\]/gs'),
    );
    expect(expression, findsOneWidget);
    expect(
      find.descendant(of: prompt, matching: find.text('/雾/g')),
      findsOneWidget,
    );

    await tester.tap(find.text('顶部状态栏美化'));
    await tester.pumpAndSettle();
    expect(enabled(status), isFalse, reason: 'the title must not toggle');
    await tester.tap(status);
    await tester.pumpAndSettle();
    expect(enabled(status), isFalse, reason: 'the row must not toggle');
    await tester.tap(prompt);
    await tester.pumpAndSettle();
    expect(enabled(prompt), isTrue, reason: 'the row must not toggle');
    await tester.tap(expression);
    await tester.pumpAndSettle();
    expect(enabled(status), isFalse, reason: 'the expression must not toggle');
    expect(await repo.getSetting('writing/$branch'), {'presetId': original.id});

    await tester.tap(find.byKey(const Key('preset-regex-details-0')));
    await tester.pumpAndSettle();
    final rule = DisplayContext.regexRulesOf(data['extensions']).first;
    expect(find.text('查找表达式'), findsOneWidget);
    expect(
      find.widgetWithText(SelectableText, rule['findRegex'] as String),
      findsOneWidget,
    );
    expect(find.text(rule['replaceString'] as String), findsOneWidget);
    expect(find.text('执行条件与其他字段'), findsOneWidget);
    await tester.tap(find.text('复制完整规则'));
    await tester.pumpAndSettle();
    expect(jsonDecode(copied!), rule);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(enabled(status), isFalse, reason: 'viewing must not toggle a rule');
    await tester.tap(find.byKey(const Key('preset-regex-details-1')));
    await tester.pumpAndSettle();
    expect(find.text(longHtml), findsOneWidget);
    await tester.ensureVisible(find.text('执行条件与其他字段'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.textContaining('立即刷新已有章节'), findsOneWidget);

    await tester.ensureVisible(status);
    await tester.tap(
      find.descendant(of: status, matching: find.byType(FSwitch)),
    );
    await tester.pumpAndSettle();
    expect(enabled(status), isTrue);
    expect(opacity(status), 1);
    final expected = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
    DisplayContext.regexRulesOf(expected['extensions']).first['disabled'] =
        false;
    final setting = (await repo.getSetting('writing/$branch'))!;
    expect(
      (setting['presetOverrides'] as Map)[original.id],
      expected,
      reason:
          'only the disabled flag changes; order and unknown fields survive',
    );
    expect((await repo.getResource(original.id)).data, data);
    expect(await repo.getSetting('writing/${other.id}'), {
      'presetId': original.id,
    });
    final writing = await WritingContext.load(services, branch);
    expect(
      writing.preset?.raw,
      expected,
      reason: 'subsequent generation uses it',
    );
    final shown = ManuscriptPresentation.fromRules(
      ManuscriptContent.plainText('[STATUS]晴天[/STATUS]'),
      rules: (await repo.displayContext(branch)).rules,
      macros: MacroEngine(values: {}, clock: DateTime.utc(2026), seed: 0),
    );
    expect(shown.content.text.trim(), '<b>晴天</b>');

    // Reopening keeps the saved state; the switch itself can turn it off.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    await tester.tap(find.text('预设正则'));
    await tester.pumpAndSettle();
    expect(enabled(status), isTrue);
    await tester.ensureVisible(status);
    await tester.tap(
      find.descendant(of: status, matching: find.byType(FSwitch)),
    );
    await tester.pumpAndSettle();
    expect(enabled(status), isFalse);
    expect(opacity(status), disabledOpacity);
    expect(
      (await repo.getSetting('writing/$branch'))!['presetOverrides'],
      isNull,
    );
    await tester.tap(
      find.descendant(of: status, matching: find.byType(FSwitch)),
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('preset-reset'))),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('preset-reset')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复').last);
    await tester.pumpAndSettle();
    expect(enabled(status), isFalse);
    expect((await repo.displayContext(branch)).rules.first['disabled'], true);
    expect(tester.takeException(), isNull);
  });

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
    await tester.tap(find.text('提示词管理'));
    await tester.pumpAndSettle();
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

  testWidgets('a text preset edits genamt as its response length', (
    tester,
  ) async {
    // ST saves a text preset's response length as `genamt` and its context
    // size as `max_length` (preset-manager.js L744-747).
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
    final branch = (await repo.createNovel(title: '雾港')).activeBranchId;
    final original = await services.library.import(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'temp': 0.8,
            'top_p': 0.9,
            'top_k': 40,
            'rep_pen': 1.1,
            'genamt': 350,
            'max_length': 8192,
          }),
        ),
      ),
      filename: 'text.json',
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
    Finder field(String label) => find.byWidgetPredicate(
      (w) => w is FTextFormField && (w.label as Text?)?.data == label,
    );
    expect(
      find.descendant(of: field('上下文长度（token）'), matching: find.text('8192')),
      findsOneWidget,
    );
    await tester.enterText(
      find.descendant(
        of: field('最大回复长度（token）'),
        matching: find.byType(EditableText),
      ),
      '500',
    );
    await tester.pumpAndSettle();
    final setting = (await repo.getSetting('writing/$branch'))!;
    final saved = (setting['presetOverrides'] as Map)[original.id] as Map;
    expect(saved['genamt'], 500);
    expect(saved['max_length'], 8192);
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
