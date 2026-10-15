import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/lore/sidecar.dart';
import 'package:sillydraft/features/reader/next_chapter.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

/// Writes a line for a chapter and answers the sidecar plainly, each held
/// by its gate when given.
class _Model implements ModelProvider {
  _Model(this.config, this.log, this.gates, this.sidecarFails);
  @override
  final ModelConnection config;
  final List<String> log;
  final ({Future<void>? writing, Future<void>? sidecar}) gates;
  final bool sidecarFails;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    if ('${request.messages.first['content']}'.startsWith(
      sidecarInstructions,
    )) {
      log.add('sidecar');
      await gates.sidecar;
      if (sidecarFails) {
        throw const ProviderException('http_500', '整理模型不可用');
      }
      yield const TextDelta('已整理');
    } else {
      log.add('writing');
      await gates.writing;
      yield const TextDelta('她推开门。');
    }
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

typedef _Desk = ({
  AppServices services,
  WidgetRef ref,
  String branchId,
  Chapter first,
});

Future<_Desk> _desk(
  WidgetTester tester, {
  List<String>? log,
  Future<void>? writingGate,
  Future<void>? sidecarGate,
  bool sidecarFails = false,
  Map<String, dynamic>? sidecar,
  ModelProtocol protocol = ModelProtocol.openAICompatible,
}) async {
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
    modelProviderFactory: (c) async => _Model(c, log ?? [], (
      writing: writingGate,
      sidecar: sidecarGate,
    ), sidecarFails),
  );
  addTearDown(services.close);
  await services.saveConnection(
    ModelConnection(
      id: 'm',
      name: '写作',
      baseUrl: 'http://localhost:1/v1',
      model: 'm',
      protocol: protocol,
    ),
  );
  if (sidecar != null) {
    await services.repository.setSetting(SidecarSettings.key, sidecar);
  }
  final novel = await services.repository.createNovel(title: '雾港');
  final first = await services.repository.createChapter(
    branchId: novel.activeBranchId,
    name: '渡口',
  );
  late WidgetRef ref;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(
        Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  return (
    services: services,
    ref: ref,
    branchId: novel.activeBranchId,
    first: first,
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<List<GenerationTask>> _tasks(_Desk d, TaskKind kind) async => [
  for (final t in await d.services.repository.listTasks(branchId: d.branchId))
    if (t.kind == kind) t,
];

void main() {
  testWidgets('a written chapter starts the sidecar on its text', (
    tester,
  ) async {
    final log = <String>[];
    final d = await _desk(tester, log: log);
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    final runs = await _tasks(d, TaskKind.sidecar);
    expect(runs.single.chapterId, d.first.id);
    expect(runs.single.status, TaskStatus.completed, reason: runs.single.error);
    expect(log, ['writing', 'sidecar']);
  });

  testWidgets('switched off, writing starts no sidecar', (tester) async {
    final d = await _desk(tester, sidecar: {'enabled': false});
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    expect(await _tasks(d, TaskKind.sidecar), isEmpty);
  });

  testWidgets('a remote runner, without tool calls, starts no sidecar', (
    tester,
  ) async {
    final d = await _desk(tester, protocol: ModelProtocol.sillyDraftRunner);
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    expect(
      (await _tasks(d, TaskKind.writing)).single.status,
      TaskStatus.completed,
    );
    expect(await _tasks(d, TaskKind.sidecar), isEmpty);
  });

  testWidgets('a result left for review starts no sidecar', (tester) async {
    final gate = Completer<void>();
    final d = await _desk(tester, writingGate: gate.future);
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    // The author edits the chapter while it is being written.
    await d.services.repository.saveChapter(
      branchId: d.branchId,
      chapterId: d.first.id,
      expectedRevisionId: d.first.revisionId,
      content: ManuscriptContent.plainText('作者先写了一句。'),
    );
    gate.complete();
    await _settle(tester);
    expect(await _tasks(d, TaskKind.sidecar), isEmpty);
  });

  testWidgets('the next chapter waits for the sidecar, then writes', (
    tester,
  ) async {
    final gate = Completer<void>();
    final d = await _desk(tester, sidecarGate: gate.future);
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    final second = await d.services.repository.createChapter(
      branchId: d.branchId,
      name: '夜航',
    );
    var waited = 0;
    final next = writeChapter(
      d.ref,
      second,
      brief: '写夜航',
      onWaitSidecar: () => waited++,
    );
    await _settle(tester);
    expect(waited, 1);
    expect(
      (await _tasks(
        d,
        TaskKind.writing,
      )).where((t) => t.chapterId == second.id),
      isEmpty,
    );
    gate.complete();
    await _settle(tester);
    await next;
    expect(
      (await _tasks(
        d,
        TaskKind.writing,
      )).where((t) => t.chapterId == second.id),
      hasLength(1),
    );
  });

  testWidgets('a failed sidecar does not hold the writing back', (
    tester,
  ) async {
    final d = await _desk(tester, sidecarFails: true);
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    expect(
      (await _tasks(d, TaskKind.sidecar)).single.status,
      TaskStatus.failed,
    );
    var waited = 0;
    await writeChapter(
      d.ref,
      await d.services.repository.createChapter(
        branchId: d.branchId,
        name: '夜航',
      ),
      brief: '写夜航',
      onWaitSidecar: () => waited++,
    );
    expect(waited, 0);
  });

  testWidgets('a sidecar that hangs stops holding the writing after a limit', (
    tester,
  ) async {
    final gate = Completer<void>();
    final d = await _desk(tester, sidecarGate: gate.future);
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await writeChapter(d.ref, d.first, brief: '写渡口');
    await _settle(tester);
    var done = false;
    unawaited(
      awaitSidecar(
        d.services,
        d.branchId,
        limit: const Duration(milliseconds: 100),
      ).then((_) => done = true),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(done, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(done, isTrue);
  });
}
