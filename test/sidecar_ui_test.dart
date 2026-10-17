import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/lore/lore_screen.dart';
import 'package:sillydraft/features/lore/sidecar.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

class _Echo implements ModelProvider {
  _Echo(this.config);
  @override
  final ModelConnection config;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    yield const TextDelta('已整理');
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => ['m'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

void main() {
  Future<AppServices> switches(
    WidgetTester tester, {
    List<ModelConnection> connections = const [],
    Map<String, dynamic>? roles,
  }) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    for (final c in connections) {
      await services.saveConnection(c);
    }
    if (roles != null) {
      await services.repository.setSetting('modelRoles', roles);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(const SingleChildScrollView(child: SidecarSwitches())),
      ),
    );
    await tester.pumpAndSettle();
    return services;
  }

  Finder sidecarSwitch(String key) =>
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(FSwitch));
  bool switchedOn(WidgetTester tester) =>
      tester.widget<FSwitch>(sidecarSwitch('sidecar-enabled')).value;
  ModelConnection model(String id, String name) => ModelConnection(
    id: id,
    name: name,
    baseUrl: 'http://localhost:1/v1',
    model: 'm',
  );

  testWidgets('the sidecar switches save the author\'s choice', (tester) async {
    final services = await switches(tester);
    Future<SidecarSettings> stored() async => SidecarSettings.fromJson(
      await services.repository.getSetting(SidecarSettings.key),
    );
    Future<void> flip(String key) async {
      await tester.tap(sidecarSwitch(key));
      await tester.pumpAndSettle();
    }

    expect(switchedOn(tester), isFalse);
    await flip('sidecar-projection');
    expect((await stored()).duties, {
      SidecarDuty.characters,
      SidecarDuty.memory,
    });
    expect((await stored()).enabled, isNull);
    await flip('sidecar-enabled');
    expect((await stored()).enabled, isTrue);
    expect(switchedOn(tester), isTrue);
    await flip('sidecar-enabled');
    expect((await stored()).enabled, isFalse);
  });

  testWidgets('a chosen analysis model turns the sidecar on and is named', (
    tester,
  ) async {
    await switches(
      tester,
      connections: [model('w', '写作'), model('a', '整理')],
      roles: {'writing': 'w', 'analysis': 'a'},
    );
    expect(switchedOn(tester), isTrue);
    expect(find.text('默认开启：已选资料整理模型「整理 · m」，整理用它。'), findsOneWidget);
  });

  testWidgets('without an analysis model the sidecar is off and says what it '
      'would use', (tester) async {
    await switches(
      tester,
      connections: [model('a', '整理'), model('w', '写作')],
      roles: {'writing': 'w'},
    );
    expect(switchedOn(tester), isFalse);
    expect(
      find.text('默认关闭：未选能调用工具的资料整理模型，开启或手动整理时改用写作模型「写作 · m」。'),
      findsOneWidget,
    );
  });

  testWidgets('the lore page labels sidecar notes and runs the sidecar', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      modelProviderFactory: (c) async => _Echo(c),
    );
    addTearDown(services.close);
    await services.saveConnection(
      ModelConnection(
        id: 'm',
        name: '整理',
        baseUrl: 'http://localhost:1/v1',
        model: 'm',
      ),
    );
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      name: '渡口',
      content: ManuscriptContent.plainText('雨夜。'),
    );
    await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林岚',
      content: '摆渡人',
      atChapterId: chapter.id,
      provenance: {
        'type': 'sidecar',
        'taskId': 't',
        'chapterId': chapter.id,
        'revisionId': chapter.revisionId,
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(LoreScreen(branchId: novel.activeBranchId)),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpAndSettle();
    expect(find.textContaining('旁路整理'), findsOneWidget);
    await tester.tap(findAction('重新整理本章'));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    final runs = [
      for (final t in await repo.listTasks(branchId: novel.activeBranchId))
        if (t.kind == TaskKind.sidecar) t,
    ];
    expect(runs.single.chapterId, chapter.id);
    expect(find.textContaining('旁路整理 · '), findsOneWidget);
    expect(find.text('已整理'), findsWidgets);
  });

  testWidgets('the lore page says a remote runner cannot run the sidecar', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      modelProviderFactory: (c) async => _Echo(c),
    );
    addTearDown(services.close);
    await services.saveConnection(
      ModelConnection(
        id: 'r',
        name: '个人执行器',
        baseUrl: 'https://runner.example',
        model: 'writer',
        protocol: ModelProtocol.sillyDraftRunner,
      ),
    );
    final novel = await services.repository.createNovel(title: '雾港');
    await services.repository.createChapter(
      branchId: novel.activeBranchId,
      name: '渡口',
      content: ManuscriptContent.plainText('雨夜。'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(LoreScreen(branchId: novel.activeBranchId)),
      ),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpAndSettle();
    await tester.tap(findAction('重新整理本章'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('远程执行器暂不支持'), findsOneWidget);
    expect(
      await services.repository.listTasks(branchId: novel.activeBranchId),
      isEmpty,
    );
  });
}
