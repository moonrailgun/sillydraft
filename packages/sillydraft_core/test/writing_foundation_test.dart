import 'dart:async';
import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  late StoryRepository repo;
  late TaskRunner runner;
  late WritingService service;
  late String branch;
  late Chapter first;
  final requests = <ProviderRequest>[];
  final connection = ModelConnection(
    id: 'm',
    name: 'm',
    baseUrl: 'http://localhost:1',
    model: 'm',
  );
  var fault = '';
  Completer<void>? gate;
  late Completer<void> entered;

  setUp(() async {
    requests.clear();
    fault = '';
    gate = null;
    entered = Completer<void>();
    repo = StoryRepository.memory();
    branch = (await repo.createNovel(title: '排练')).activeBranchId;
    first = await repo.createChapter(branchId: branch);
    runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        requests.add(request);
        if (request.usagePurpose == 'foundation' ||
            request.usagePurpose == 'planning') {
          final material =
              jsonDecode(request.messages.last['content'] as String) as Map;
          final sources = <String, String>{
            for (final message in material['写作素材'] as List)
              if (message['content'] is Map)
                ...Map<String, String>.from(message['content'] as Map),
          };
          final sourceId = sources.entries
              .firstWhere((e) => e.value.contains('第七灯号'))
              .key;
          if (request.usagePurpose == 'foundation') {
            entered.complete();
            await gate?.future;
            if (fault == 'provider') {
              throw const ProviderException('offline', 'offline');
            }
            yield TextDelta(
              jsonEncode({
                'constraints': [
                  {
                    'sourceId': fault == 'id' ? 'missing' : sourceId,
                    'constraint': '第七灯号的删改尚待核实',
                  },
                ],
                'threads': [
                  {
                    'sourceIds': [sourceId],
                    'setup': fault == 'oversize'
                        ? '字' * 241
                        : '首场排练看见旧谱第七灯号被划掉',
                    'custody': '旧谱由舞监保管',
                    'discovery': '当事人同意后对照两份记录',
                    'payoff': '若核对吻合，承认当年的沉默并更正署名',
                    'limit': '划痕不能证明是谁删改',
                  },
                ],
                'causalChain': ['若发现灯号差异，先询问保管者，再争取当事人同意核对'],
              }),
            );
            yield GenerationFinished(fault == 'incomplete' ? 'length' : 'stop');
          } else {
            yield TextDelta(
              jsonEncode({
                'anchors': [
                  {'sourceId': sourceId, 'constraint': '先呈现差异，不提前解释'},
                ],
                'beats': [
                  {
                    'sourceIds': [sourceId],
                    'establishes': '存在差异',
                    'unresolved': '删改人未知',
                    'cause': '排练不顺',
                    'action': '核对灯号',
                    'consequence': '决定询问保管人',
                  },
                ],
                'threads': <dynamic>[],
              }),
            );
            yield const GenerationFinished('stop');
          }
        } else if (request.usagePurpose == 'quality') {
          yield const TextDelta('{"issues":[]}');
          yield const GenerationFinished('stop');
        } else {
          yield const TextDelta('她翻开旧谱，在被划掉的第七灯号旁停住。');
          yield const GenerationFinished('stop');
        }
      }),
    );
    service = WritingService(repository: repo, runner: runner);
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await runner.close();
    await repo.close();
  });

  Future<PreparedWriting> prepare({
    Chapter? chapter,
    ModelConnection? model,
    bool autoAccept = true,
    bool append = false,
    bool rewrite = false,
    bool regenerate = false,
    ImportedPreset? preset,
  }) => service.prepare(
    branchId: branch,
    chapterId: (chapter ?? first).id,
    connection: model ?? connection,
    brief: '第七灯号被删，先发现差异，后续核对记录并承认沉默的责任。',
    autoAccept: autoAccept,
    append: append,
    rewrite: rewrite,
    regenerate: regenerate,
    preset: preset,
  );
  Future<GenerationTask> run(PreparedWriting draft) async =>
      runner.wait((await service.startPrepared(draft)).id);

  test('fresh preview is free; accepted foundation reaches planning writing and review', () async {
    final draft = await prepare();
    expect(draft.input['bookFoundation'], {'protocolVersion': 1});
    expect(requests, isEmpty);
    final frozen = jsonEncode(draft.input['request']);
    final done = await run(draft);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(requests.map((r) => r.usagePurpose), [
      'foundation',
      'planning',
      'writing',
      'quality',
    ]);
    for (final request in requests.skip(1)) {
      expect(jsonEncode(request.messages), contains('划痕不能证明是谁删改'));
    }
    expect(jsonEncode(done.input['request']), frozen);
    final lore = (await repo.listLore(branch)).single;
    expect(lore.kind, LoreKind.world);
    expect(lore.certainty, LoreCertainty.plan);
    expect(lore.data['writingFoundation'], 1);
    expect(
      lore.provenance['revisionId'],
      (await repo.getChapter(branchId: branch, chapterId: first.id)).revisionId,
    );
    final next = await repo.createChapter(branchId: branch);
    final continuation = await prepare(chapter: next);
    expect(continuation.input['bookFoundation'], isNull);
    expect(jsonEncode(continuation.input['request']), contains('划痕不能证明是谁删改'));
  });

  test(
    'pending proposal publishes nothing; accepting once publishes one plan',
    () async {
      final done = await run(await prepare(autoAccept: false));
      expect(done.result['foundation'], isA<Map>());
      expect(await repo.listLore(branch), isEmpty);
      final proposal = (await repo.listProposals(branch)).single;
      await repo.acceptProposal(proposal.id);
      await repo.acceptProposal(proposal.id);
      expect(await repo.listLore(branch), hasLength(1));
    },
  );

  for (final failure in ['id', 'oversize', 'incomplete', 'provider']) {
    test(
      '$failure foundation falls back without publishing untrusted advice',
      () async {
        fault = failure;
        final done = await run(await prepare());
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect((done.result['foundation'] as Map?)?['status'], 'unavailable');
        expect(await repo.listLore(branch), isEmpty);
        expect(
          (await repo.getChapter(
            branchId: branch,
            chapterId: first.id,
          )).content.text,
          contains('她翻开旧谱'),
        );
        expect(
          requests.where((r) => r.usagePurpose == 'foundation'),
          hasLength(1),
        );
        expect(
          jsonEncode(requests.last.messages),
          isNot(contains('划痕不能证明是谁删改')),
        );
      },
    );
  }

  test(
    'foundation budget overflow falls back without an auxiliary call',
    () async {
      final draft = await prepare(
        model: ModelConnection.fromJson({
          ...connection.raw,
          'contextWindow': 2100,
          'maxOutputTokens': 1500,
        }),
      );
      final done = await run(draft);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect((done.result['foundation'] as Map)['status'], 'unavailable');
      expect(requests.any((r) => r.usagePurpose == 'foundation'), isFalse);
      expect(
        requests.first.messages,
        (draft.input['request'] as Map)['messages'],
      );
      expect(await repo.listLore(branch), isEmpty);
    },
  );

  test('cancelled foundation writes neither prose nor lore', () async {
    gate = Completer<void>();
    final draft = await prepare();
    expect(draft.input['bookFoundation'], isA<Map>());
    final task = await service.startPrepared(draft);
    await entered.future;
    await runner.cancel(task.id);
    gate!.complete();
    expect((await runner.wait(task.id)).status, TaskStatus.cancelled);
    expect(await repo.listLore(branch), isEmpty);
    expect(
      (await repo.getChapter(branchId: branch, chapterId: first.id)).revisionId,
      first.revisionId,
    );
  });

  for (final otherChapter in [false, true]) {
    test(
      'concurrent ${otherChapter ? 'later prose' : 'revision conflict'} prevents foundation publication',
      () async {
        final done = await run(await prepare(autoAccept: false));
        expect((done.result['foundation'] as Map?)?['status'], 'applied');
        if (otherChapter) {
          await repo.createChapter(
            branchId: branch,
            content: ManuscriptContent.plainText('作者已另写后续。'),
          );
          await repo.acceptProposal(
            (await repo.listProposals(branch)).single.id,
          );
        } else {
          await repo.saveChapter(
            branchId: branch,
            chapterId: first.id,
            expectedRevisionId: first.revisionId,
            content: ManuscriptContent.plainText('作者改了首章。'),
          );
          await expectLater(
            repo.acceptProposal((await repo.listProposals(branch)).single.id),
            throwsA(isA<RevisionConflict>()),
          );
        }
        expect(await repo.listLore(branch), isEmpty);
      },
    );
  }

  test(
    'foundation follows branch history and becomes stale after source editing',
    () async {
      await run(await prepare());
      expect(await repo.listLore(branch), hasLength(1));
      final fork = await repo.forkBranch(
        branchId: branch,
        name: '另一条路',
        atChapterId: first.id,
      );
      expect(
        await repo.listLore(fork.id, skipStaleVersions: true),
        hasLength(1),
      );
      final current = await repo.getChapter(
        branchId: branch,
        chapterId: first.id,
      );
      await repo.saveChapter(
        branchId: branch,
        chapterId: first.id,
        expectedRevisionId: current.revisionId,
        content: ManuscriptContent.plainText('新的开场。'),
      );
      expect(await repo.listLore(branch, skipStaleVersions: true), isEmpty);
      expect(
        await repo.listLore(fork.id, skipStaleVersions: true),
        hasLength(1),
      );
      await repo.deleteChapter(branchId: fork.id, chapterId: first.id);
      expect(await repo.listLore(fork.id, skipStaleVersions: true), isEmpty);
    },
  );

  test('existing prose, non-first chapters and explicit editing modes skip foundation', () async {
    expect((await prepare(append: true)).input['bookFoundation'], isNull);
    expect((await prepare(rewrite: true)).input['bookFoundation'], isNull);
    expect((await prepare(regenerate: true)).input['bookFoundation'], isNull);
    expect(
      (await prepare(preset: PresetImporter().decode({'prompts': <dynamic>[]})))
          .input['bookFoundation'],
      isNull,
    );
    final next = await repo.createChapter(branchId: branch);
    expect((await prepare(chapter: next)).input['bookFoundation'], isNull);
    await repo.saveChapter(
      branchId: branch,
      chapterId: next.id,
      expectedRevisionId: next.revisionId,
      content: ManuscriptContent.plainText('后章已有正文。'),
    );
    expect((await prepare()).input['bookFoundation'], isNull);
  });

  test('old frozen tasks do not acquire a new foundation request', () async {
    final draft = await prepare();
    final input = draft.input..remove('bookFoundation');
    final old = PreparedWriting(
      branchId: draft.branchId,
      chapterId: draft.chapterId,
      baseRevisionId: draft.baseRevisionId,
      kind: draft.kind,
      input: input,
    );
    expect((await run(old)).status, TaskStatus.completed);
    expect(requests.any((r) => r.usagePurpose == 'foundation'), isFalse);
    expect(await repo.listLore(branch), isEmpty);
  });
}
