import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/personas/persona_picker.dart';
import 'package:sillydraft/features/resources/card_start_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  testWidgets(
    'alternate card opening maps the protagonist and creates separate lore',
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
      final repo = services.repository;
      await repo.storeResource(
        id: 'card',
        kind: ResourceKind.character,
        name: '苏雾',
        filename: 'card.json',
        sourceHash: 'fixture',
        encryptedSource: [],
        data: {
          'spec': 'chara_card_v2',
          'data': {
            'name': '苏雾',
            'description': '守塔人',
            'scenario': '雾港',
            'first_mes': '{{user}}听见钟声',
            'alternate_greetings': ['{{char}}给{{user}}一封信'],
          },
        },
      );
      await repo.savePersona(const Persona(id: 'linzhou', name: '林舟'));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(const CardStartScreen(resourceId: 'card')),
        ),
      );
      await tester.pumpAndSettle();
      final picker = find.descendant(
        of: find.byType(PersonaPicker),
        matching: find.byWidgetPredicate((w) => w is FSelect<String>),
      );
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('林舟').last);
      await tester.pumpAndSettle();
      final greeting = find.byWidgetPredicate((w) => w is FSelect<int>);
      await tester.ensureVisible(greeting);
      await tester.tap(greeting);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('备用开场 1').last);
      await tester.pumpAndSettle();
      final opening = tester
          .widgetList<EditableText>(find.byType(EditableText))
          .last
          .controller
          .text;
      expect(opening, '苏雾给林舟一封信');
      await tester.ensureVisible(find.text('创建小说与初始资料'));
      await tester.tap(find.text('创建小说与初始资料'));
      await tester.pumpAndSettle();
      final novel = (await repo.listNovels()).single;
      expect((await repo.getStory(novel.activeBranchId)).text.trim(), opening);
      expect(
        (await repo.getSetting(
          'writing/${novel.activeBranchId}',
        ))!['personaId'],
        'linzhou',
      );
      expect(
        (await repo.listLore(novel.activeBranchId)).map((e) => e.kind),
        containsAll([LoreKind.character, LoreKind.world]),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('editing the chosen persona updates the opening', (tester) async {
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
    await repo.storeResource(
      id: 'card',
      kind: ResourceKind.character,
      name: '苏雾',
      filename: 'card.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: {
        'spec': 'chara_card_v2',
        'data': {'name': '苏雾', 'first_mes': '{{user}}听见钟声'},
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const CardStartScreen(resourceId: 'card')),
      ),
    );
    await tester.pumpAndSettle();
    String opening() => tester
        .widgetList<EditableText>(find.byType(EditableText))
        .last
        .controller
        .text;
    expect(opening(), '我听见钟声');
    await tester.runAsync(
      () => repo.savePersona(Persona.me.copyWith(name: '阿我')),
    );
    await tester.pumpAndSettle();
    expect(opening(), '阿我听见钟声');
    await tester.pumpWidget(const SizedBox());
  });
}
