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
  late Chapter chapter;
  late LoreEntry hook;
  final requests = <ProviderRequest>[];
  var response = <String, dynamic>{};
  var finishReason = 'stop';
  Completer<void>? gate;
  final connection = ModelConnection(
    id: 'm',
    name: 'm',
    baseUrl: 'http://localhost:1',
    model: 'm',
  );
  setUp(() async {
    requests.clear();
    finishReason = 'stop';
    gate = null;
    repo = StoryRepository.memory();
    branch = (await repo.createNovel(title: '欠款')).activeBranchId;
    await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('租金原欠三千六百元，已经还了九百元。'),
    );
    chapter = await repo.createChapter(branchId: branch);
    hook = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.foreshadow,
      name: '蓝收据',
      content: '尚未核对的收据',
      data: {'status': 'planted'},
    );
    response = {
      'anchors': [
        {'quote': '租金原欠三千六百元，已经还了九百元。', 'constraint': '尚欠二千七百元'},
      ],
      'beats': [
        {'cause': '房东来核账', 'action': '拿出收据逐项核对', 'consequence': '确认欠款后协商延期'},
      ],
      'threads': [
        {'id': hook.id, 'action': 'advance', 'reason': '核对收据但尚未付款'},
      ],
    };
    runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        requests.add(request);
        if (request.usagePurpose == 'planning') {
          await gate?.future;
          yield TextDelta(jsonEncode(response));
          yield GenerationFinished(finishReason);
        } else if (request.usagePurpose == 'quality') {
          yield const TextDelta('{"issues":[]}');
          yield const GenerationFinished('stop');
        } else {
          yield const TextDelta('她拿出蓝收据，请房东坐下核账。');
          yield const GenerationFinished('stop');
        }
      }),
    );
    service = WritingService(repository: repo, runner: runner);
  });
  tearDown(() async {
    gate?.complete();
    await runner.close();
    await repo.close();
  });

  Future<PreparedWriting> prepare({
    ImportedPreset? preset,
    ModelConnection? model,
  }) async {
    final prepared = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: model ?? connection,
      preset: preset,
      brief: '让她与房东核对欠款，不要提前解决债务',
      autoAccept: true,
    );
    // Frozen V1 tasks retain the exact-quote protocol after an app upgrade.
    final input = prepared.input;
    (input['chapterPlanning'] as Map?)?.remove('protocolVersion');
    return PreparedWriting(
      branchId: prepared.branchId,
      chapterId: prepared.chapterId,
      baseRevisionId: prepared.baseRevisionId,
      kind: prepared.kind,
      input: input,
    );
  }

  test(
    'preview makes no calls; writing and review share a sourced advisory plan',
    () async {
      final draft = await prepare();
      final frozen = jsonEncode(draft.input['request']);
      expect(requests, isEmpty);
      final task = await service.startPrepared(draft);
      final done = await runner.wait(task.id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(requests.map((r) => r.usagePurpose), [
        'planning',
        'writing',
        'quality',
      ]);
      expect(jsonEncode(done.input['request']), frozen);
      expect((done.result['planning'] as Map)['status'], 'applied');
      expect(jsonEncode(done.result['effectiveRequest']), contains('尚欠二千七百元'));
      expect(jsonEncode(requests[1].messages), contains('尚欠二千七百元'));
      expect(jsonEncode(requests[2].messages), contains('尚欠二千七百元'));
      final saved = await repo.getChapter(
        branchId: branch,
        chapterId: chapter.id,
      );
      expect(saved.content.text.trim(), '她拿出蓝收据，请房东坐下核账。');
      expect((await repo.listLore(branch)).single.revisionId, hook.revisionId);
    },
  );

  for (final bad in ['quote', 'hook', 'incomplete', 'empty', 'oversized']) {
    test('invalid $bad plan falls back to frozen writing request', () async {
      switch (bad) {
        case 'quote':
          response['anchors'][0]['quote'] = '债务已经清偿';
        case 'hook':
          response['threads'][0]['id'] = 'invented';
        case 'incomplete':
          finishReason = 'length';
        case 'empty':
          response['beats'] = <Map<String, dynamic>>[];
        case 'oversized':
          response['beats'][0]['action'] = '动作' * 300;
      }
      final draft = await prepare();
      final done = await runner.wait((await service.startPrepared(draft)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect((done.result['planning'] as Map)['status'], 'unavailable');
      expect(requests[1].messages, (draft.input['request'] as Map)['messages']);
      expect(done.result['effectiveRequest'], isNull);
    });
  }

  for (final flag in [false, null]) {
    test('preset planning flag $flag preserves the compiled request', () async {
      final raw = Map<String, dynamic>.from(defaultWritingPreset().raw)
        ..remove('sillydraft_chapter_planning');
      if (flag != null) raw['sillydraft_chapter_planning'] = flag;
      final preset = PresetImporter().decode(raw);
      final draft = await prepare(preset: preset);
      final done = await runner.wait((await service.startPrepared(draft)).id);
      expect(done.status, TaskStatus.completed);
      expect(requests.map((r) => r.usagePurpose), ['writing', 'quality']);
      expect(
        requests.first.messages,
        (draft.input['request'] as Map)['messages'],
      );
    });
  }

  test(
    'planning budget overflow falls back without an auxiliary call',
    () async {
      final draft = await prepare(
        model: ModelConnection.fromJson({
          ...connection.raw,
          'contextWindow': 2100,
          'maxOutputTokens': 1500,
        }),
      );
      final done = await runner.wait((await service.startPrepared(draft)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect((done.result['planning'] as Map)['status'], 'unavailable');
      expect(requests.any((r) => r.usagePurpose == 'planning'), isFalse);
      expect(
        requests.first.messages,
        (draft.input['request'] as Map)['messages'],
      );
    },
  );

  test('range rewrites do not plan an entire chapter', () async {
    final saved = await repo.saveChapter(
      branchId: branch,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('她拿出收据。'),
    );
    final draft = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '改写动作',
      rewrite: true,
      rangeStart: 0,
      rangeEnd: 2,
      expectedRevisionId: saved.revisionId,
    );
    expect(draft.input['chapterPlanning'], isNull);
    final done = await runner.wait((await service.startPrepared(draft)).id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(requests.map((r) => r.usagePurpose), ['rewrite']);
  });

  test('cancellation during planning never writes a chapter', () async {
    gate = Completer<void>();
    final task = await service.startPrepared(await prepare());
    for (var i = 0; requests.isEmpty && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await runner.cancel(task.id);
    gate!.complete();
    gate = null;
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.cancelled);
    expect(requests.map((r) => r.usagePurpose), ['planning']);
    expect(
      (await repo.getChapter(
        branchId: branch,
        chapterId: chapter.id,
      )).revisionId,
      chapter.revisionId,
    );
  });
}
