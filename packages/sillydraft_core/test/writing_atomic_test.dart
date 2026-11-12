import 'dart:async';
import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

final class TrackedProvider implements ModelProvider {
  TrackedProvider(this.inner, this.onClose);
  final ScriptProvider inner;
  final void Function() onClose;
  @override
  ModelConnection get config => inner.config;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => inner.generate(request, cancellation: cancellation);
  @override
  Future<List<String>> listModels() => inner.listModels();
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      inner.validateParameters(request);
  @override
  void close() => onClose();
}

void main() {
  late StoryRepository repo;
  late TaskRunner runner;
  late WritingService service;
  late String branch;
  late Chapter chapter;
  final requests = <({String model, ProviderRequest request})>[];
  final closed = <String>[];
  const fact = '她已亲眼检查过木盒，盒底没有字迹。';
  const original = '她又打开木盒，盒底清楚写着交货日期。\n她指着清清楚楚的字迹，说自己终于找到了证明。';
  const revised = '她又打开木盒，盒底依然没有字迹。\n她把木盒放下，承认现有材料不能证明交货日期，只能继续核查。';
  final writer = ModelConnection(
    id: 'writer',
    name: 'writer',
    baseUrl: 'http://localhost:1',
    model: 'writer',
    maxOutputTokens: 16000,
  );
  final reviewer = ModelConnection(
    id: 'reviewer',
    name: 'reviewer',
    baseUrl: 'http://localhost:1',
    model: 'old',
    models: ['old', 'audit'],
    maxOutputTokens: 16000,
  );
  var scenario = '';
  Completer<void>? gate;
  Completer<void>? entered;
  Map<String, String> sources(Map data) => {
    for (final message in (data['写作素材'] ?? data['写作上下文']) as List)
      if (message['content'] is Map)
        ...Map<String, String>.from(message['content'] as Map),
  };
  setUp(() async {
    scenario = '';
    gate = null;
    entered = null;
    requests.clear();
    closed.clear();
    repo = StoryRepository.memory();
    branch = (await repo.createNovel(title: '木盒')).activeBranchId;
    await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText(fact),
    );
    chapter = await repo.createChapter(branchId: branch);
    await repo.setSetting('connections', {
      'items': [reviewer.raw, writer.raw],
    });
    await repo.setSetting('modelRoles', {
      'review': reviewer.id,
      'reviewModel': 'audit',
    });
    runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async {
        if (c.id == reviewer.id) {
          if (scenario == 'factory failure') throw StateError('unavailable');
          if (scenario == 'cancel factory') {
            entered!.complete();
            await gate!.future;
          }
        }
        return TrackedProvider(
          ScriptProvider(c, (request, cancel) async* {
            requests.add((model: c.model, request: request));
            Object output;
            if (request.usagePurpose == 'planning') {
              final data =
                  jsonDecode(request.messages.last['content'] as String) as Map;
              final id = sources(data).entries
                  .firstWhere((e) => e.value.contains(fact))
                  .key;
              output = {
                'anchors': [
                  {'sourceId': id, 'constraint': '盒底没有字迹'},
                ],
                'beats': [
                  {
                    'cause': '缺乏证据',
                    'action': '检查木盒',
                    'consequence': '继续查证',
                    'sourceIds': [id],
                    'establishes': '没有字迹',
                    'unresolved': '日期未知',
                  },
                ],
                'threads': <Object?>[],
              };
            } else if (request.usagePurpose != 'quality') {
              output = original;
            } else if (request.executionId!.endsWith('-revising')) {
              output = {'text': revised};
            } else {
              if (scenario == 'request failure') {
                throw StateError('unavailable');
              }
              if (scenario == 'cancel review') {
                entered!.complete();
                await gate!.future;
              }
              final data =
                  jsonDecode(request.messages.last['content'] as String) as Map;
              final passages = data['本次正文'] as Map;
              final id = sources(data).entries
                  .firstWhere((e) => e.value.contains(fact))
                  .key;
              final checking = request.executionId!.endsWith('-checking');
              final claim = <String, dynamic>{
                'kind': 'payoff',
                'claim': '盒底的字迹证明了日期',
                'passageIds': passages.keys.toList(),
                'sourceIds': [id],
                'verdict': checking ? 'supported' : 'contradicted',
                'reason': '前章明确无字迹，不能凭空用字迹作证。',
              };
              switch (scenario) {
                case 'bad kind':
                  claim['kind'] = 'style';
                case 'bad verdict':
                  claim['verdict'] = 'wrong';
                case 'bad passage':
                  claim['passageIds'] = ['missing'];
                case 'bad source':
                  claim['sourceIds'] = ['missing'];
                case 'duplicate source':
                  claim['sourceIds'] = [id, id];
                case 'empty passages':
                  claim['passageIds'] = <String>[];
                case 'long claim':
                  claim['claim'] = '字' * 241;
                case 'long reason':
                  claim['reason'] = '字' * 1201;
                case 'empty reason':
                  claim['reason'] = ' ';
                case 'uncertain':
                  claim['verdict'] = 'uncertain';
                case 'supported':
                  claim['verdict'] = 'supported';
                case 'unsupported':
                  if (!checking) claim['verdict'] = 'unsupported';
                case 'remaining':
                  claim['verdict'] = 'contradicted';
              }
              output = {
                'claims': scenario == 'empty claims'
                    ? <Object?>[]
                    : scenario == 'too many claims'
                    ? List.filled(9, claim)
                    : scenario == 'eight claims'
                    ? List.filled(8, claim)
                    : [
                        claim,
                        {...claim, 'verdict': 'uncertain', 'claim': '交货日期尚待查证'},
                      ],
              };
            }
            yield TextDelta(output is String ? output : jsonEncode(output));
            yield const GenerationFinished('stop');
          }),
          () => closed.add(c.model),
        );
      },
    );
    service = WritingService(repository: repo, runner: runner);
  });
  tearDown(() async {
    if (gate != null && !gate!.isCompleted) gate!.complete();
    await runner.close();
    await repo.close();
  });
  Future<PreparedWriting> prepare() => service.prepare(
    branchId: branch,
    chapterId: chapter.id,
    connection: writer,
    brief: '核查木盒',
    autoAccept: true,
  );
  Future<GenerationTask> run() async =>
      runner.wait((await service.startPrepared(await prepare())).id);
  Future<String> saved() async => (await repo.getChapter(
    branchId: branch,
    chapterId: chapter.id,
  )).content.text.trim();

  test('frozen reviewer audits while the writer plans and repairs', () async {
    final prepared = await prepare();
    await repo.setSetting('modelRoles', {'review': writer.id});
    final done = await runner.wait((await service.startPrepared(prepared)).id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(await saved(), revised);
    expect(requests.map((r) => r.model), [
      'writer',
      'writer',
      'audit',
      'writer',
      'audit',
    ]);
    expect(closed, unorderedEquals(['writer', 'audit']));
    final quality = done.result['quality'] as Map;
    expect(quality['status'], 'revised');
    expect(quality['reviewingClaims'], hasLength(2));
    expect(quality['issues'], hasLength(1));
    expect(quality['reviewingClaims'][0]['quotes'].join(), original);
    expect(
      quality['reviewingClaims'][0]['sourceQuotes'].join(),
      contains(fact),
    );
    expect(quality['checkingClaims'], hasLength(2));
  });
  for (final value in ['uncertain', 'supported']) {
    test('$value claims preserve the draft without repair', () async {
      scenario = value;
      final done = await run();
      expect((done.result['quality'] as Map)['status'], 'passed');
      expect(await saved(), original);
      expect(requests.map((r) => r.model), ['writer', 'writer', 'audit']);
      expect((done.result['quality'] as Map)['reviewingClaims'], hasLength(2));
    });
  }
  for (final value in ['unsupported', 'eight claims']) {
    test('$value reaches repair and independent check', () async {
      scenario = value;
      final done = await run();
      expect((done.result['quality'] as Map)['status'], 'revised');
      expect(await saved(), revised);
      expect(requests, hasLength(5));
    });
  }
  for (final failure in [
    'bad kind',
    'bad verdict',
    'bad passage',
    'bad source',
    'duplicate source',
    'empty passages',
    'long claim',
    'long reason',
    'empty reason',
    'empty claims',
    'too many claims',
    'factory failure',
    'request failure',
    'remaining',
  ]) {
    test('$failure preserves the accepted original', () async {
      scenario = failure;
      final done = await run();
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(
        (done.result['quality'] as Map)['status'],
        failure == 'remaining' ? 'kept_original' : 'unavailable',
      );
      expect(await saved(), original);
      expect(closed, contains('writer'));
      if (failure != 'factory failure') expect(closed, contains('audit'));
    });
  }
  for (final value in ['unassigned', 'deleted', 'cli', 'remote', 'image']) {
    test(
      '$value reviewer uses the selected writer, not the first connection',
      () async {
        final incompatible = ModelConnection(
          id: 'incompatible',
          name: 'incompatible',
          baseUrl: 'http://localhost:1',
          model: 'incompatible',
          protocol: value == 'cli'
              ? ModelProtocol.codexCli
              : value == 'remote'
              ? ModelProtocol.sillyDraftRunner
              : ModelProtocol.openAICompatible,
          kind: value == 'image' ? ModelKind.image : ModelKind.text,
        );
        await repo.setSetting('connections', {
          'items': [reviewer.raw, writer.raw, incompatible.raw],
        });
        await repo.setSetting(
          'modelRoles',
          value == 'unassigned'
              ? {}
              : {'review': value == 'deleted' ? 'missing' : incompatible.id},
        );
        scenario = 'supported';
        final done = await run();
        expect((done.result['quality'] as Map)['status'], 'passed');
        expect(requests.map((r) => r.model), ['writer', 'writer', 'writer']);
        expect(closed, ['writer']);
      },
    );
  }
  for (final value in ['cancel factory', 'cancel review']) {
    test('$value propagates cancellation and closes providers', () async {
      scenario = value;
      gate = Completer<void>();
      entered = Completer<void>();
      final task = await service.startPrepared(await prepare());
      await entered!.future.timeout(const Duration(seconds: 3));
      await runner.cancel(task.id);
      gate!.complete();
      expect((await runner.wait(task.id)).status, TaskStatus.cancelled);
      expect(
        (await repo.getChapter(
          branchId: branch,
          chapterId: chapter.id,
        )).revisionId,
        chapter.revisionId,
      );
      expect(closed, unorderedEquals(['writer', 'audit']));
    });
  }
}
