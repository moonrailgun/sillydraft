import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/resources/preset_prompt_editor.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  testWidgets('phone rows collapse and reorder only with arrows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? changed;
    await tester.pumpWidget(
      testHost(
        Scaffold(
          body: PresetPromptEditor(
            value: {
              'prompts': [
                for (final id in ['main', 'style'])
                  {
                    'identifier': id,
                    'name': id,
                    'role': 'system',
                    'content': '$id 的内容',
                  },
              ],
            },
            onChanged: (value) => changed = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableDragStartListener), findsNothing);
    expect(find.byKey(const Key('prompt-edit-style')), findsNothing);
    expect(find.text('style 的内容'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('prompt-style'))).height,
      lessThan(60),
    );
    await tester.tap(find.byKey(const Key('prompt-expand-style')));
    await tester.pumpAndSettle();
    expect(find.text('style 的内容'), findsOneWidget);
    expect(find.byKey(const Key('prompt-edit-main')), findsNothing);
    await tester.tap(find.byKey(const Key('prompt-up-style')));
    await tester.pumpAndSettle();
    expect(
      [
        for (final item
            in (changed!['prompt_order'] as List).single['order'] as List)
          item['identifier'],
      ],
      ['style', 'main'],
    );
    // The moved entry stays open so the arrows can be tapped again.
    expect(find.byKey(const Key('prompt-up-style')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1)); // tooltip hide timer
  });

  testWidgets('prompt order skips missing entries and appends unplaced ones', (
    tester,
  ) async {
    Map<String, dynamic>? changed;
    await tester.pumpWidget(
      testHost(
        Scaffold(
          body: PresetPromptEditor(
            value: {
              'prompts': [
                for (final id in ['main', 'style', 'unplaced'])
                  {'identifier': id, 'name': id, 'role': 'system'},
              ],
              'prompt_order': [
                {
                  'character_id': 100001,
                  'order': [
                    {'identifier': 'style', 'enabled': true},
                    {'identifier': 'missing', 'enabled': false},
                    {'identifier': 'main', 'enabled': true},
                  ],
                },
              ],
            },
            onChanged: (value) => changed = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final style = find.byKey(const Key('prompt-enabled-style'));
    final main = find.byKey(const Key('prompt-enabled-main'));
    final unplaced = find.byKey(const Key('prompt-enabled-unplaced'));
    expect(tester.getTopLeft(style).dy, lessThan(tester.getTopLeft(main).dy));
    expect(
      tester.getTopLeft(main).dy,
      lessThan(tester.getTopLeft(unplaced).dy),
    );
    expect(
      tester
          .widget<FSwitch>(
            find.descendant(of: unplaced, matching: find.byType(FSwitch)),
          )
          .value,
      isFalse,
    );
    await tester.tap(unplaced);
    await tester.pumpAndSettle();
    expect((changed!['prompt_order'] as List).single['order'], [
      {'identifier': 'style', 'enabled': true},
      {'identifier': 'missing', 'enabled': false},
      {'identifier': 'main', 'enabled': true},
      {'identifier': 'unplaced', 'enabled': true},
    ]);
    final handle = find.descendant(
      of: find.byKey(const ValueKey('prompt-style')),
      matching: find.byType(ReorderableDragStartListener),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    await gesture.moveTo(
      tester.getBottomLeft(find.byKey(const ValueKey('prompt-unplaced'))) +
          const Offset(30, 4),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect((changed!['prompt_order'] as List).single['order'], [
      {'identifier': 'main', 'enabled': true},
      {'identifier': 'style', 'enabled': true},
      {'identifier': 'unplaced', 'enabled': true},
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final pack in [false, true]) {
    testWidgets(
      'phone edits ${pack ? "prompt pack" : "chat preset"} order, switches and depth without losing extensions',
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
        final order = [
          {'identifier': 'main', 'enabled': true},
          {'identifier': 'style', 'enabled': false},
        ];
        final body = <String, dynamic>{
          'prompts': [
            {
              'identifier': 'main',
              'name': '主提示词',
              'content': '写作',
              'role': 'system',
              'custom_unknown': {'preserved': true},
            },
            {
              'identifier': 'style',
              'name': '文风',
              'content': '克制',
              'role': 'system',
            },
          ],
          'prompt_order': pack
              ? order
              : [
                  {
                    'character_id': 100000,
                    'order': [
                      {'identifier': 'main', 'enabled': false},
                    ],
                  },
                  {'character_id': 100001, 'order': order},
                ],
        };
        final data = pack
            ? {
                'version': 1,
                'type': 'full',
                'data': body,
                'unknown_extension': 7,
              }
            : {...body, 'name': '写作预设', 'unknown_extension': 7};
        final resource = await services.repository.storeResource(
          id: 'preset',
          kind: ResourceKind.preset,
          name: '写作预设',
          filename: 'preset.json',
          sourceHash: 'fixture-source-hash',
          encryptedSource: [],
          data: data,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(ResourceEditScreen(resource: resource)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('prompt-enabled-style')));
        await tester.tap(find.byKey(const Key('prompt-expand-style')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('prompt-up-style')));
        await tester.tap(find.byKey(const Key('prompt-expand-main')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('prompt-edit-main')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('prompt-content')),
          '只输出小说正文',
        );
        await tester.enterText(find.byKey(const Key('prompt-depth')), '2');
        await tester.tap(find.text('应用条目修改'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存新版本'));
        await tester.pumpAndSettle();
        final versions = await services.repository.listResources();
        expect(versions.length, 2);
        final edited = versions.firstWhere((r) => r.id != resource.id);
        final parsed = PresetImporter().decode(edited.data);
        expect(parsed.selectOrder().map((e) => e.identifier), [
          'style',
          'main',
        ]);
        expect(parsed.selectOrder().first.enabled, isTrue);
        expect(
          parsed.prompts.firstWhere((p) => p.identifier == 'main').content,
          '只输出小说正文',
        );
        expect(
          parsed.prompts.firstWhere((p) => p.identifier == 'main').depth,
          2,
        );
        expect(
          parsed.prompts
              .firstWhere((p) => p.identifier == 'main')
              .raw['custom_unknown'],
          {'preserved': true},
        );
        expect(edited.data['unknown_extension'], 7);
        expect((await services.repository.getResource(resource.id)).data, data);
        if (!pack) {
          expect(
            parsed.selectOrder(characterId: 100000).single.enabled,
            isFalse,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
