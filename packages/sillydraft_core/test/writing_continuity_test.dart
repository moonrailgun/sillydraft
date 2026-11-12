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
  final requests = <ProviderRequest>[];
  const fact = '她已亲眼检查过木盒，盒底没有字迹。';
  final longFact = '${'𠀀' * 260}\n\n$fact\n\n单\n\n';
  const original = '她又打开木盒，盒底清楚写着交货日期。\n她指着清清楚楚的字迹，说自己终于找到了证明。';
  const repaired = '她又打开木盒，盒底依然没有字迹。\n她把木盒放下，承认现有材料不能证明交货日期，只能继续核查。';
  var scenario = '';
  var protocolVersion = 2;
  Completer<void>? gate;
  final connection = ModelConnection(
    id: 'm',
    name: 'm',
    baseUrl: 'http://localhost:1',
    model: 'm',
    maxOutputTokens: 16000,
  );

  Map<String, String> sources(Map data) => {
    for (final message in (data['写作素材'] ?? data['写作上下文']) as List)
      if (message['content'] is Map)
        ...Map<String, String>.from(message['content'] as Map),
  };

  setUp(() async {
    requests.clear();
    scenario = '';
    protocolVersion = 2;
    gate = null;
    repo = StoryRepository.memory();
    branch = (await repo.createNovel(title: '木盒')).activeBranchId;
    await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText(longFact),
    );
    chapter = await repo.createChapter(branchId: branch);
    runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        requests.add(request);
        Object output;
        if (request.usagePurpose == 'planning') {
          final data =
              jsonDecode(request.messages.last['content'] as String) as Map;
          final found = sources(data);
          if (found.isEmpty) {
            output = {
              'anchors': <Object?>[],
              'beats': <Object?>[],
              'threads': <Object?>[],
            };
          } else {
            final id = found.entries
                .firstWhere((e) => e.value.contains(fact))
                .key;
            output = {
              'anchors': [
                {
                  'sourceId': scenario == 'bad plan' ? 'missing' : id,
                  'constraint': '盒底没有字迹，不能凭空出现证据',
                },
              ],
              'beats': [
                {
                  'cause': '材料不足',
                  'action': '再次核查木盒',
                  'consequence': '承认证据不足',
                  if (protocolVersion == 3) ...{
                    'sourceIds': scenario == 'bad beat source'
                        ? ['missing']
                        : [id],
                    'establishes': '只能确定盒底没有字迹',
                    if (scenario != 'missing limit') 'unresolved': '交货日期仍不明',
                  },
                },
              ],
              'threads': <Object?>[],
            };
          }
        } else if (request.usagePurpose != 'quality') {
          output = original;
        } else if (request.executionId!.endsWith('-revising')) {
          await gate?.future;
          output = {
            'text': switch (scenario) {
              'empty repair' => '',
              'short repair' => '结束。',
              'large repair' => repaired * 3,
              'control repair' => '$repaired<script>',
              _ => repaired,
            },
          };
        } else {
          final data =
              jsonDecode(request.messages.last['content'] as String) as Map;
          final passages = data['本次正文'];
          if (passages is! Map) {
            output = <String, dynamic>{'issues': <Object?>[]};
          } else if (request.executionId!.endsWith('-checking') &&
              scenario != 'remaining') {
            output = <String, dynamic>{'issues': <Object?>[]};
          } else {
            final id = sources(data).entries
                .firstWhere((e) => e.value.contains(fact))
                .key;
            output = <String, dynamic>{
              'issues': [
                {
                  'passageIds': scenario == 'bad draft id'
                      ? ['missing']
                      : passages.keys.toList(),
                  'sourceIds': scenario == 'bad source id' ? ['missing'] : [id],
                  'reason': '前章木盒没有字迹，本章多段以字迹为证，须一并改正，不能补造新证据。',
                },
              ],
            };
          }
          if (protocolVersion == 3 && scenario != 'missing checks') {
            final id = sources(data).entries
                .firstWhere((e) => e.value.contains(fact))
                .key;
            (output as Map)['checks'] = {
              for (final key in [
                'chronology',
                'quantities',
                'knowledge',
                'payoff',
              ])
                key: {
                  'passageIds': (passages as Map).keys.take(1).toList(),
                  'sourceIds':
                      (scenario == 'bad check source' ||
                          (scenario == 'bad checking source' &&
                              request.executionId!.endsWith('-checking')))
                      ? ['missing']
                      : [id],
                  'finding': key == 'payoff' ? '盒底无字不能证明交货日期' : '没有发现明确冲突',
                },
            };
          }
        }
        yield TextDelta(output is String ? output : jsonEncode(output));
        yield GenerationFinished(
          scenario == 'incomplete repair' &&
                  request.executionId?.endsWith('-revising') == true
              ? 'length'
              : 'stop',
        );
      }),
    );
    service = WritingService(repository: repo, runner: runner);
  });
  tearDown(() async {
    gate?.complete();
    await runner.close();
    await repo.close();
  });

  Future<PreparedWriting> prepare() async {
    final prepared = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '核查木盒，证据不足时承认不足',
      autoAccept: true,
    );
    final input = prepared.input
      ..remove('continuityReview')
      ..remove('reviewConnection');
    (input['chapterPlanning'] as Map)['protocolVersion'] = protocolVersion;
    return PreparedWriting(
      branchId: prepared.branchId,
      chapterId: prepared.chapterId,
      baseRevisionId: prepared.baseRevisionId,
      kind: prepared.kind,
      input: input,
    );
  }

  Future<GenerationTask> run() async =>
      runner.wait((await service.startPrepared(await prepare())).id);
  Future<String> saved() async => (await repo.getChapter(
    branchId: branch,
    chapterId: chapter.id,
  )).content.text.trim();

  test('numbered evidence preserves Unicode and repairs related paragraphs before acceptance', () async {
    final prepared = await prepare();
    expect((prepared.input['chapterPlanning'] as Map)['protocolVersion'], 2);
    final frozen = jsonEncode(prepared.input);
    final done = await runner.wait((await service.startPrepared(prepared)).id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(jsonEncode(done.input), frozen);
    expect((done.result['planning'] as Map)['status'], 'applied');
    final data =
        jsonDecode(requests.first.messages.last['content'] as String) as Map;
    final source = sources(data);
    expect(source.values.every((p) => p.runes.length <= 240), isTrue);
    expect(source.values.join(), contains(longFact.trim()));
    final numbered = data['写作素材'] as List;
    final raw = (prepared.input['request'] as Map)['messages'] as List;
    for (var i = 0; i < raw.length; i++) {
      expect((numbered[i]['content'] as Map).values.join(), raw[i]['content']);
    }
    final plan = (done.result['planning'] as Map)['plan'] as Map;
    expect(plan['anchors'][0]['quote'], contains(fact));
    expect(requests.map((r) => r.usagePurpose), [
      'planning',
      'writing',
      'quality',
      'quality',
      'quality',
    ]);
    expect((done.result['quality'] as Map)['status'], 'revised');
    expect(
      (done.result['quality'] as Map)['issues'][0]['quotes'].length,
      greaterThan(1),
    );
    expect(requests[3].parameters['max_tokens'], 16000);
    expect(await saved(), repaired);
    expect(done.partialText, original);
  });

  test(
    'invalid numbered plan falls back while continuity review remains active',
    () async {
      scenario = 'bad plan';
      final done = await run();
      expect((done.result['planning'] as Map)['status'], 'unavailable');
      expect(done.result['effectiveRequest'], isNull);
      expect((done.result['quality'] as Map)['status'], 'revised');
      expect(await saved(), repaired);
    },
  );

  for (final failure in [
    'bad draft id',
    'bad source id',
    'empty repair',
    'short repair',
    'large repair',
    'control repair',
    'incomplete repair',
    'remaining',
  ]) {
    test('$failure keeps the original accepted text', () async {
      scenario = failure;
      final done = await run();
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(
        (done.result['quality'] as Map)['status'],
        failure == 'remaining' ? 'kept_original' : 'unavailable',
      );
      expect(await saved(), original);
      expect(requests.length, lessThanOrEqualTo(5));
      if (failure == 'remaining') {
        expect((done.result['quality'] as Map)['revision'], repaired);
      }
    });
  }

  test('cancelled continuity repair cannot accept either draft', () async {
    gate = Completer<void>();
    final task = await service.startPrepared(await prepare());
    for (
      var i = 0;
      i < 200 &&
          !requests.any((r) => r.executionId?.endsWith('-revising') == true);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      requests.any((r) => r.executionId?.endsWith('-revising') == true),
      isTrue,
    );
    await runner.cancel(task.id);
    gate!.complete();
    gate = null;
    expect((await runner.wait(task.id)).status, TaskStatus.cancelled);
    expect(
      (await repo.getChapter(
        branchId: branch,
        chapterId: chapter.id,
      )).revisionId,
      chapter.revisionId,
    );
  });

  test(
    'new plans carry evidence limits into writing and both review audits',
    () async {
      protocolVersion = 3;
      final prepared = await prepare();
      expect((prepared.input['chapterPlanning'] as Map)['protocolVersion'], 3);
      final done = await runner.wait(
        (await service.startPrepared(prepared)).id,
      );
      expect(done.status, TaskStatus.completed, reason: done.error);
      final plan = (done.result['planning'] as Map)['plan'] as Map;
      final beat = plan['beats'][0] as Map;
      expect(beat['sourceQuotes'], [contains(fact)]);
      expect(beat['establishes'], '只能确定盒底没有字迹');
      expect(beat['unresolved'], '交货日期仍不明');
      final writing = requests.singleWhere((r) => r.usagePurpose == 'writing');
      expect(writing.messages.last['content'], contains(jsonEncode(plan)));
      final quality = done.result['quality'] as Map;
      expect(quality['status'], 'revised', reason: jsonEncode(quality));
      for (final stage in ['reviewingChecks', 'checkingChecks']) {
        expect(quality[stage]['payoff']['sourceQuotes'], [contains(fact)]);
      }
      final revision = requests.singleWhere(
        (r) => r.executionId?.endsWith('-revising') == true,
      );
      final data =
          jsonDecode(revision.messages.last['content'] as String) as Map;
      expect(data['核查记录'], quality['reviewingChecks']);
      expect(quality['status'], 'revised');
      expect(await saved(), repaired);
      expect(requests.length, 5);
    },
  );

  test(
    'new source IDs never select blank fragments and preserve all source text',
    () async {
      protocolVersion = 3;
      final prepared = await prepare();
      await runner.wait((await service.startPrepared(prepared)).id);
      final data =
          jsonDecode(requests.first.messages.last['content'] as String) as Map;
      expect(
        sources(data).values.every((p) => p.trim().runes.length >= 2),
        isTrue,
      );
      final numbered = data['写作素材'] as List;
      final raw = (prepared.input['request'] as Map)['messages'] as List;
      for (var i = 0; i < raw.length; i++) {
        final content = numbered[i]['content'];
        expect(
          content is Map ? content.values.join() : content,
          raw[i]['content'],
        );
      }
    },
  );

  for (final failure in ['bad beat source', 'missing limit']) {
    test(
      '$failure falls back to frozen request without dropping review',
      () async {
        protocolVersion = 3;
        scenario = failure;
        final done = await run();
        expect((done.result['planning'] as Map)['status'], 'unavailable');
        expect(done.result['effectiveRequest'], isNull);
        expect((done.result['quality'] as Map)['status'], 'revised');
        expect(await saved(), repaired);
      },
    );
  }

  for (final failure in ['missing checks', 'bad check source']) {
    test('$failure cannot silently pass a continuity audit', () async {
      protocolVersion = 3;
      scenario = failure;
      final done = await run();
      expect((done.result['quality'] as Map)['status'], 'unavailable');
      expect(await saved(), original);
    });
  }

  test(
    'invalid independent audit retains both the original and attempted repair',
    () async {
      protocolVersion = 3;
      scenario = 'bad checking source';
      final done = await run();
      final quality = done.result['quality'] as Map;
      expect(quality['status'], 'unavailable');
      expect(quality['reviewingChecks'], isNotNull);
      expect(quality['checkingChecks'], isNull);
      expect(quality['revision'], repaired);
      expect(await saved(), original);
      expect(requests.length, 5);
    },
  );
}
