import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft/features/skills/skills_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

class _Recorder implements ModelProvider {
  _Recorder(this.config, this.seen);
  @override
  final ModelConnection config;
  final List<ProviderRequest> seen;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    seen.add(request);
    yield const TextDelta('好的，按技能来。');
    yield const GenerationFinished('stop');
  }

  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
}

Widget _app(AppServices services, Widget home) => ProviderScope(
  overrides: [servicesProvider.overrideWithValue(services)],
  child: testHost(home),
);

void main() {
  testWidgets('skills can be switched off and written by the author', (
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
    await tester.pumpWidget(_app(services, const SkillsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('人物一致性检查'), findsOneWidget);
    expect(find.textContaining('/dialogue-polish · 内置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('skill-enabled-dialogue-polish')));
    await tester.pumpAndSettle();
    expect(
      (await services.skills.enabled()).map((s) => s.name),
      isNot(contains('dialogue-polish')),
    );

    await tester.tap(find.byKey(const Key('skill-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('skill-name')), 'Bad Name');
    await tester.tap(find.byKey(const Key('skill-save')));
    await tester.pumpAndSettle();
    expect(find.text('只能包含小写字母、数字和单个连字符'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('skill-name')),
      'villain-voice',
    );
    await tester.enterText(
      find.byKey(const Key('skill-description')),
      '让反派说话更有压迫感。写反派对白时使用。',
    );
    await tester.enterText(find.byKey(const Key('skill-body')), '少用感叹号。');
    await tester.tap(find.byKey(const Key('skill-save')));
    await tester.pumpAndSettle();
    final mine = (await services.skills.installed()).single;
    expect(mine.name, 'villain-voice');
    expect(mine.toSkillMd(), startsWith('---\nname: villain-voice\n'));
    expect(find.textContaining('/villain-voice'), findsOneWidget);
  });

  testWidgets(
    'typing / suggests skills; the chosen skill rides with the chat',
    (tester) async {
      final seen = <ProviderRequest>[];
      final repo = StoryRepository.memory();
      final services = AppServices(
        repository: repo,
        secrets: MemorySecrets(),
        modelProviderFactory: (c) async => _Recorder(c, seen),
      );
      addTearDown(services.close);
      await services.saveConnection(
        ModelConnection(
          id: 'test',
          name: '测试模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'test',
        ),
      );
      final novel = await repo.createNovel(title: '雾港');
      await tester.pumpWidget(
        _app(
          services,
          AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('技能 · 6'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('agent-input')), '/fore');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('skill-suggestion-foreshadowing-audit')),
      );
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('agent-input')),
                matching: find.byType(EditableText),
              ),
            )
            .controller
            .text,
        '/foreshadowing-audit ',
      );
      expect(
        find.byKey(const Key('skill-suggestion-foreshadowing-audit')),
        findsNothing,
        reason: 'suggestions close once a skill is chosen',
      );
      await tester.enterText(
        find.byKey(const Key('agent-input')),
        '/foreshadowing-audit 看看第一章',
      );
      await tester.tap(findAction('发送给编辑助手'));
      await tester.pumpAndSettle();

      final request = seen.single;
      final contents = request.messages.map((m) => '${m['content']}').toList();
      expect(contents.first, contains('<available_skills>'));
      expect(
        contents.where(
          (c) => c.contains('<skill_content name="foreshadowing-audit">'),
        ),
        hasLength(1),
      );
      expect(contents.last, '看看第一章');
      expect(
        request.tools.map((t) => (t['function'] as Map)['name']),
        contains('activate_skill'),
      );
      expect(find.text('你启用了技能：伏笔与暗线梳理'), findsOneWidget);
      expect(find.text('好的，按技能来。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
