import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
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
        await tester.tap(find.byKey(const Key('prompt-up-style')));
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
