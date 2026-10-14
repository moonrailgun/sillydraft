import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/personas/persona_editor_screen.dart';
import 'package:sillydraft/features/personas/persona_picker.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft/features/resources/writing_profile.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

class _Reply implements ModelProvider {
  _Reply(this.config, this.text);
  @override
  final ModelConnection config;
  final String text;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    yield TextDelta(text);
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

Future<AppServices> _services(
  WidgetTester tester, {
  ProviderFactory? model,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
    modelProviderFactory: model,
  );
  addTearDown(services.close);
  return services;
}

/// Pushes [page] over a blank home, so a page that closes itself on save
/// returns there instead of popping the root route.
Future<void> _show(
  WidgetTester tester,
  AppServices services,
  Widget page,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(const SizedBox()),
    ),
  );
  unawaited(
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(MaterialPageRoute<void>(builder: (_) => page)),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('the writing profile binds {{user}} to the chosen persona', (
    tester,
  ) async {
    final services = await _services(tester);
    final repo = services.repository;
    await repo.savePersona(
      const Persona(id: 'linzhou', name: '林舟', appearance: '短发'),
    );
    final branch = (await repo.createNovel(title: '雾港')).activeBranchId;
    expect((await WritingContext.load(services, branch)).userName, '我');
    await _show(tester, services, WritingProfileScreen(branchId: branch));
    final picker = find.descendant(
      of: find.byType(PersonaPicker),
      matching: find.byWidgetPredicate((w) => w is FSelect<String>),
    );
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text('林舟').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect((await repo.getSetting('writing/$branch'))!['personaId'], 'linzhou');
    final context = await WritingContext.load(services, branch);
    expect((context.userName, context.persona), ('林舟', '外貌：短发'));
  });

  testWidgets(
    'a persona made from the library cannot be deleted while a novel uses it',
    (tester) async {
      final services = await _services(tester);
      final repo = services.repository;
      await _show(tester, services, const ResourceLibraryScreen());
      await tester.tap(find.text('人设'));
      await tester.pumpAndSettle();
      expect(find.text('我'), findsOneWidget);

      await tester.tap(find.text('新建人设'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText).at(0), '林舟');
      await tester.enterText(find.byType(EditableText).at(2), '短发');
      await tester.pumpAndSettle();
      expect(find.text('外貌：短发'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('保存人设'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('保存人设'));
      await tester.pumpAndSettle();
      final linzhou = (await repo.listPersonas())[1];
      expect((linzhou.name, linzhou.appearance), ('林舟', '短发'));

      final novel = await repo.createNovel(title: '雾港');
      await repo.setSetting('writing/${novel.activeBranchId}', {
        'personaId': linzhou.id,
      });
      await tester.tap(find.text('林舟'));
      await tester.pumpAndSettle();
      await tester.tap(findAction('删除人设'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('1 部作品'), findsOneWidget);
      expect(await repo.listPersonas(), hasLength(2));
    },
  );

  testWidgets('model help fills the form and one step back restores it', (
    tester,
  ) async {
    final services = await _services(
      tester,
      model: (c) async => _Reply(
        c,
        '{"name": "别名", "description": "二十三岁的插画师", "appearance": "黑色短发", "outfit": "灰色卫衣"}',
      ),
    );
    await services.saveConnection(
      ModelConnection(
        id: 'test',
        name: '测试模型',
        baseUrl: 'http://localhost:1/v1',
        model: 'test',
      ),
    );
    await _show(
      tester,
      services,
      const PersonaEditorScreen(personaId: Persona.meId),
    );
    String field(int i) => tester
        .widget<EditableText>(find.byType(EditableText).at(i))
        .controller
        .text;
    await tester.enterText(find.byType(EditableText).at(1), '插画师');
    await tester.ensureVisible(find.text('AI 补全润色'));
    await tester.tap(find.text('AI 补全润色'));
    await tester.pumpAndSettle();
    expect(
      [field(0), field(1), field(2), field(3)],
      ['我', '二十三岁的插画师', '黑色短发', '灰色卫衣'],
    );
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect([field(0), field(1), field(2), field(3)], ['我', '插画师', '', '']);
    expect(find.text('撤销'), findsNothing);
  });
}
