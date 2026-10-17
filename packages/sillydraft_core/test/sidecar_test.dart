import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

final _model = ModelConnection(
  id: 'm',
  name: 'm',
  baseUrl: 'http://localhost:1',
  model: 'm',
);

typedef _Book = ({
  StoryRepository repo,
  TaskRunner runner,
  Novel novel,
  Chapter chapter,
  List<ProviderRequest> requests,
});

/// A one-chapter book whose model plays [script], one reply per request, and
/// answers plainly once it runs out. [gate] holds every reply until it opens;
/// [spy] sees every statement the book's database runs.
Future<_Book> _book(
  List<List<ProviderEvent>> script, {
  Completer<void>? gate,
  QueryInterceptor? spy,
}) async {
  final repo = spy == null
      ? StoryRepository.memory()
      : StoryRepository.connect(NativeDatabase.memory().interceptWith(spy));
  addTearDown(repo.close);
  final novel = await repo.createNovel(title: '雾港');
  final chapter = await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '第一章 渡口',
    content: ManuscriptContent.plainText('雨夜，林岚撑着红伞走过渡口。'),
  );
  final requests = <ProviderRequest>[];
  final runner = TaskRunner(
    repository: repo,
    providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
      requests.add(request);
      await gate?.future;
      final reply = script.isEmpty
          ? [const TextDelta('已整理'), const GenerationFinished('stop')]
          : script.removeAt(0);
      for (final event in reply) {
        yield event;
      }
    }),
  );
  addTearDown(runner.close);
  return (
    repo: repo,
    runner: runner,
    novel: novel,
    chapter: chapter,
    requests: requests,
  );
}

/// Starts a sidecar task on the book's chapter directly, as the agent would.
Future<GenerationTask> _start(_Book b, Set<SidecarDuty> duties) =>
    b.runner.start(
      branchId: b.chapter.branchId,
      kind: TaskKind.sidecar,
      chapterId: b.chapter.id,
      baseRevisionId: b.chapter.revisionId,
      input: {
        'connection': _model.raw,
        'request': ProviderRequest(
          messages: [
            {'role': 'system', 'content': '整理资料'},
            {'role': 'user', 'content': b.chapter.content.text},
          ],
        ).raw,
        'duties': [for (final duty in duties) duty.name],
      },
    );

Future<GenerationTask> _run(_Book b, Set<SidecarDuty> duties) async =>
    b.runner.wait((await _start(b, duties)).id);

/// Bytes of the values written to task rows. SQLite rewrites a whole row on
/// every update, so this is also what the rows' readers re-read.
final class _TaskWrites extends QueryInterceptor {
  var bytes = 0;
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('UPDATE generation_tasks')) {
      for (final value in args.whereType<String>()) {
        bytes += utf8.encode(value).length;
      }
    }
    return executor.runCustom(statement, args);
  }
}

/// Scans of a branch's lore versions, the read every listing of notes makes.
final class _LoreScans extends QueryInterceptor {
  var count = 0;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('FROM lore_versions WHERE branch_id')) count++;
    return executor.runSelect(statement, args);
  }
}

/// What each tool call answered, in order, from the task's transcript.
List<Map<String, dynamic>> _toolResults(GenerationTask task) => [
  for (final m in (task.result['transcript'] as List).cast<Map>())
    if (m['role'] == 'tool')
      jsonDecode(m['content'] as String) as Map<String, dynamic>,
];

void main() {
  test('sidecar switches round-trip; the main one stays unset until set', () {
    final fresh = SidecarSettings.fromJson(null);
    expect(fresh.enabled, isNull);
    expect(fresh.duties, SidecarDuty.values.toSet());
    // Switching a duty does not set the main switch for the author.
    expect(
      SidecarSettings.fromJson(
        fresh.copyWith(duties: {SidecarDuty.memory}).toJson(),
      ).enabled,
      isNull,
    );
    final back = SidecarSettings.fromJson(
      SidecarSettings(enabled: false, duties: {SidecarDuty.memory}).toJson(),
    );
    expect(back.enabled, isFalse);
    expect(back.duties, {SidecarDuty.memory});
    expect(
      SidecarSettings.fromJson({
        'duties': {'memory': false},
      }).duties,
      {SidecarDuty.characters, SidecarDuty.projection},
    );
    expect(fresh.copyWith(enabled: false).duties, fresh.duties);
  });

  group('sidecar setup', () {
    ModelConnection connection(
      String id, [
      ModelProtocol protocol = ModelProtocol.openAICompatible,
    ]) => ModelConnection(
      id: id,
      name: id,
      baseUrl: protocol.isLocalCli ? '' : 'http://localhost:1/v1',
      model: 'm',
      protocol: protocol,
    );

    Future<SidecarSetup> setup(
      List<ModelConnection> connections, {
      Map<String, dynamic>? roles,
      Map<String, dynamic>? sidecar,
      bool localCli = true,
    }) async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      await repo.setSetting('connections', {
        'items': [for (final c in connections) c.raw],
      });
      if (roles != null) await repo.setSetting('modelRoles', roles);
      if (sidecar != null) await repo.setSetting(SidecarSettings.key, sidecar);
      return SidecarSetup.read(repo, localCli: localCli);
    }

    test(
      'it is on by default only with an analysis model the author chose',
      () async {
        // The analysis role falls back to the first connection; that is not a
        // choice.
        final unset = await setup([connection('a'), connection('w')]);
        expect(unset.analysis, isNull);
        expect(unset.enabled, isFalse);
        final chosen = await setup(
          [connection('w'), connection('a')],
          roles: {'writing': 'w', 'analysis': 'a'},
        );
        expect(chosen.enabled, isTrue);
        expect(chosen.connection?.id, 'a');
        final gone = await setup([connection('w')], roles: {'analysis': 'x'});
        expect(gone.enabled, isFalse);
      },
    );

    test('an analysis model that cannot call tools does not count', () async {
      for (final s in [
        await setup(
          [connection('w'), connection('a', ModelProtocol.anthropic)],
          roles: {'analysis': 'a'},
        ),
        await setup(
          [connection('w'), connection('r', ModelProtocol.sillyDraftRunner)],
          roles: {'analysis': 'r'},
        ),
        // A phone cannot run the desktop's command-line tools.
        await setup(
          [connection('w'), connection('c', ModelProtocol.claudeCode)],
          roles: {'analysis': 'c'},
          localCli: false,
        ),
      ]) {
        expect(s.analysis, isNull);
        expect(s.enabled, isFalse);
        expect(s.connection?.id, 'w');
      }
      final cli = await setup(
        [connection('w'), connection('c', ModelProtocol.claudeCode)],
        roles: {'analysis': 'c'},
      );
      expect(cli.enabled, isTrue);
      expect(cli.connection?.id, 'c');
    });

    test('the author\'s switch wins over the default', () async {
      final off = await setup(
        [connection('a')],
        roles: {'analysis': 'a'},
        sidecar: {'enabled': false},
      );
      expect(off.enabled, isFalse);
      final on = await setup([connection('w')], sidecar: {'enabled': true});
      expect(on.enabled, isTrue);
      expect(on.connection?.id, 'w');
    });

    test('the writing model stands in only when the author asks', () async {
      // Off by default, so after a chapter nothing runs; a manual run, or
      // switching it on, uses the writing model rather than the first one.
      final s = await setup(
        [connection('a'), connection('w')],
        roles: {'writing': 'w'},
      );
      expect(s.enabled, isFalse);
      expect(s.connection?.id, 'w');
      final none = await setup(
        [connection('w', ModelProtocol.anthropic)],
        sidecar: {'enabled': true},
      );
      expect(none.enabled, isTrue);
      expect(none.connection, isNull);
    });
  });

  test('a sidecar run keeps its messages on the task', () async {
    final b = await _book([
      [const TextDelta('本章没有需要整理的资料'), const GenerationFinished('stop')],
    ]);
    final task = await _run(b, {SidecarDuty.memory});
    expect(task.status, TaskStatus.completed, reason: task.error);
    expect(task.result['transcript'], [
      {'role': 'assistant', 'content': '本章没有需要整理的资料'},
    ]);
    expect(task.result['text'], '本章没有需要整理的资料');
    expect(_toolResults(task), isEmpty);
  });

  List<ProviderEvent> save(List<Map<String, dynamic>> entries) => [
    ToolCallReady('save', 'save_lore', {'entries': entries}),
    const GenerationFinished('tool_calls'),
  ];
  List<Map> results(GenerationTask task) =>
      (_toolResults(task).single['results'] as List).cast<Map>();

  test(
    'save_lore writes at the chapter and keeps the author\'s images',
    () async {
      final script = <List<ProviderEvent>>[];
      final b = await _book(script);
      final portrait = await b.repo.storeAsset(
        branchId: b.novel.activeBranchId,
        name: '林岚',
        prepared: PreparedAsset(
          hash: 'a' * 64,
          thumbnailHash: 'b' * 64,
          width: 1,
          height: 1,
          byteLength: 1,
        ),
        purpose: AssetPurpose.reference,
      );
      final lin = await b.repo.saveLoreEntry(
        branchId: b.novel.activeBranchId,
        kind: LoreKind.character,
        name: '林岚',
        content: '渡口的摆渡人',
        data: {
          'appearance': '短发',
          'images': [portrait.id],
        },
      );
      script.add(
        save([
          {
            'id': lin.id,
            'expectedRevisionId': lin.revisionId,
            'kind': 'character',
            'name': '林岚',
            'content': '渡口的摆渡人，雨夜救下落水者',
            'certainty': 'fact',
            'outfit': '蓑衣',
            'state': '右手擦伤',
          },
          {
            'kind': 'character',
            'name': '落水者',
            'content': '被林岚救起的陌生人',
            'certainty': 'fact',
            'appearance': '湿透的长衫',
          },
        ]),
      );
      final task = await _run(b, {SidecarDuty.characters});
      expect(task.status, TaskStatus.completed, reason: task.error);
      expect(results(task).map((r) => r['error']), [null, null]);
      final tools = {
        for (final t in b.requests.first.tools)
          (t['function'] as Map)['name']: t['function'] as Map,
      };
      expect(tools.keys, [
        'list_lore',
        'read_lore',
        'save_lore',
        'delete_lore',
      ]);
      final kinds =
          (((tools['save_lore']!['parameters'] as Map)['properties']
                      as Map)['entries']
                  as Map)['items']['properties']['kind']['enum']
              as List;
      expect(kinds, ['character', 'relationship']);
      final updated = await b.repo.getLoreEntry(
        branchId: b.novel.activeBranchId,
        id: lin.id,
      );
      expect(updated.content, '渡口的摆渡人，雨夜救下落水者');
      expect(updated.data['outfit'], '蓑衣');
      expect(updated.data['appearance'], '短发');
      expect(updated.data['images'], [portrait.id]);
      expect(updated.atChapterId, b.chapter.id);
      expect(updated.provenance, {
        'type': 'sidecar',
        'taskId': task.id,
        'chapterId': b.chapter.id,
        'revisionId': b.chapter.revisionId,
      });
      final index = await b.repo.listLore(b.novel.activeBranchId);
      expect(index.map((e) => e.name), ['林岚', '落水者']);
      expect(sidecarIndexEntry(updated, b.chapter.id), {
        'id': lin.id,
        'kind': 'character',
        'name': '林岚',
        'certainty': 'fact',
        'fromThisChapter': true,
      });
    },
  );

  test('a duty switched off cannot write its kinds', () async {
    final b = await _book([
      save([
        {
          'kind': 'event',
          'name': '渡口夜雨',
          'content': '林岚救人',
          'certainty': 'fact',
        },
        {
          'kind': 'character',
          'name': '林岚',
          'content': '摆渡人',
          'certainty': 'fact',
        },
      ]),
    ]);
    final task = await _run(b, {SidecarDuty.characters});
    expect(results(task)[0]['error'], contains('职责'));
    expect(results(task)[1]['error'], isNull);
    expect((await b.repo.listLore(b.novel.activeBranchId)).map((e) => e.name), [
      '林岚',
    ]);
  });

  test('a stale revision fails only its own entry', () async {
    final script = <List<ProviderEvent>>[];
    final b = await _book(script);
    final lin = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      kind: LoreKind.character,
      name: '林岚',
      content: '摆渡人',
    );
    final edited = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      id: lin.id,
      expectedRevisionId: lin.revisionId,
      kind: LoreKind.character,
      name: '林岚',
      content: '作者改过的介绍',
    );
    script.add(
      save([
        {
          'id': lin.id,
          'expectedRevisionId': lin.revisionId,
          'kind': 'character',
          'name': '林岚',
          'content': '旧版本上的改动',
          'certainty': 'fact',
        },
        {
          'kind': 'character',
          'name': '落水者',
          'content': '陌生人',
          'certainty': 'fact',
        },
      ]),
    );
    final task = await _run(b, {SidecarDuty.characters});
    expect(results(task)[0]['error'], contains('版本冲突'));
    expect(results(task)[0]['revisionId'], edited.revisionId);
    expect(results(task)[1]['error'], isNull);
    expect(
      (await b.repo.getLoreEntry(
        branchId: b.novel.activeBranchId,
        id: lin.id,
      )).content,
      '作者改过的介绍',
    );
  });

  test(
    'projection writes guesses and confirms its own, never new facts',
    () async {
      final script = <List<ProviderEvent>>[];
      final b = await _book(script);
      final guess = await b.repo.saveLoreEntry(
        branchId: b.novel.activeBranchId,
        kind: LoreKind.event,
        name: '船帮来人',
        content: '船帮会来渡口找人',
        certainty: LoreCertainty.plan,
      );
      final wrong = await b.repo.saveLoreEntry(
        branchId: b.novel.activeBranchId,
        kind: LoreKind.event,
        name: '林岚离开渡口',
        content: '林岚会连夜离开',
        certainty: LoreCertainty.plan,
      );
      script
        ..add(
          save([
            {
              'kind': 'event',
              'name': '镜头外：船帮集结',
              'content': '船帮在下游集结',
              'certainty': 'inference',
            },
            {
              'kind': 'event',
              'name': '新事实',
              'content': '不该写入',
              'certainty': 'fact',
            },
            {
              'id': guess.id,
              'expectedRevisionId': guess.revisionId,
              'kind': 'event',
              'name': '船帮来人',
              'content': '船帮果然来到渡口',
              'certainty': 'fact',
            },
          ]),
        )
        ..add([
          ToolCallReady('del', 'delete_lore', {
            'id': wrong.id,
            'expectedRevisionId': wrong.revisionId,
          }),
          const GenerationFinished('tool_calls'),
        ]);
      final task = await _run(b, {SidecarDuty.projection});
      expect(task.status, TaskStatus.completed, reason: task.error);
      final saved = (_toolResults(task).first['results'] as List).cast<Map>();
      expect(saved[0]['error'], isNull);
      expect(saved[1]['error'], contains('职责'));
      expect(saved[2]['error'], isNull);
      expect(_toolResults(task).last, {'deleted': wrong.id});
      final lore = await b.repo.listLore(b.novel.activeBranchId);
      expect(lore.map((e) => e.name), ['船帮来人', '镜头外：船帮集结']);
      expect(lore.first.certainty, LoreCertainty.fact);
    },
  );

  test('notes from a chapter changed mid-run are marked stale', () async {
    final gate = Completer<void>();
    final b = await _book([
      save([
        {
          'kind': 'character',
          'name': '林岚',
          'content': '摆渡人',
          'certainty': 'fact',
        },
      ]),
    ], gate: gate);
    final task = await _start(b, {SidecarDuty.characters});
    await b.repo.saveChapter(
      branchId: b.chapter.branchId,
      chapterId: b.chapter.id,
      expectedRevisionId: b.chapter.revisionId,
      content: ManuscriptContent.plainText('改写后：渡口空无一人。'),
    );
    gate.complete();
    final done = await b.runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    final lin = (await b.repo.listLore(b.novel.activeBranchId)).single;
    expect(lin.sourceStale, isTrue);
  });

  test('projection cannot demote or delete a fact', () async {
    final script = <List<ProviderEvent>>[];
    final b = await _book(script);
    final fact = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      kind: LoreKind.event,
      name: '渡口夜雨',
      content: '林岚救人',
    );
    script
      ..add(
        save([
          {
            'id': fact.id,
            'expectedRevisionId': fact.revisionId,
            'kind': 'event',
            'name': '渡口夜雨',
            'content': '改成计划',
            'certainty': 'plan',
          },
        ]),
      )
      ..add([
        ToolCallReady('del', 'delete_lore', {
          'id': fact.id,
          'expectedRevisionId': fact.revisionId,
        }),
        const GenerationFinished('tool_calls'),
      ]);
    final task = await _run(b, {SidecarDuty.projection});
    expect(task.status, TaskStatus.completed, reason: task.error);
    expect(
      ((_toolResults(task).first['results'] as List).single as Map)['error'],
      contains('职责'),
    );
    expect(_toolResults(task).last['error'], contains('职责'));
    final kept = await b.repo.getLoreEntry(
      branchId: b.novel.activeBranchId,
      id: fact.id,
    );
    expect(kept.content, '林岚救人');
    expect(kept.certainty, LoreCertainty.fact);
    expect(await b.repo.listLore(b.novel.activeBranchId), hasLength(1));
  });

  test('the sidecar cannot write a character\'s images', () async {
    final b = await _book([
      save([
        {
          'kind': 'character',
          'name': '林岚',
          'content': '摆渡人',
          'certainty': 'fact',
          'images': ['x'],
        },
      ]),
    ]);
    final task = await _run(b, {SidecarDuty.characters});
    expect(results(task).single['error'], isNotNull);
    expect(await b.repo.listLore(b.novel.activeBranchId), isEmpty);
  });

  test(
    'the sidecar sees the chapter, the protagonist and a lore index',
    () async {
      final b = await _book([]);
      await b.repo.savePersona(
        const Persona(id: 'p', name: '林岚', appearance: '短发', outfit: '蓑衣'),
      );
      await b.repo.setSetting('writing/${b.novel.activeBranchId}', {
        'personaId': 'p',
      });
      await b.repo.saveLoreEntry(
        branchId: b.novel.activeBranchId,
        kind: LoreKind.world,
        name: '渡口',
        content: '这一段全文不应出现在上下文里',
      );
      final agent = SidecarAgent(repository: b.repo, runner: b.runner);
      final task = await agent.start(
        branchId: b.novel.activeBranchId,
        chapterId: b.chapter.id,
        connection: _model,
        duties: {SidecarDuty.characters, SidecarDuty.memory},
      );
      expect(task.kind, TaskKind.sidecar);
      expect(task.chapterId, b.chapter.id);
      expect(task.baseRevisionId, b.chapter.revisionId);
      await b.runner.wait(task.id);
      final request = b.requests.single;
      final system = request.messages.first['content'] as String;
      expect(system, startsWith(sidecarInstructions));
      expect(system, contains(SidecarDuty.characters.instructions));
      expect(system, contains(SidecarDuty.memory.instructions));
      expect(system, isNot(contains(SidecarDuty.projection.instructions)));
      expect(system, contains('"appearance":"短发"'));
      expect(system, contains('"name":"渡口"'));
      expect(system, isNot(contains('这一段全文不应出现在上下文里')));
      expect(request.messages.last['content'], contains('雨夜，林岚撑着红伞走过渡口。'));
      await expectLater(
        agent.start(
          branchId: b.novel.activeBranchId,
          chapterId: b.chapter.id,
          connection: _model,
          duties: {},
        ),
        throwsFormatException,
      );
    },
  );

  test('starting again on a chapter replaces the run still going', () async {
    final gate = Completer<void>();
    final b = await _book([], gate: gate);
    final agent = SidecarAgent(repository: b.repo, runner: b.runner);
    Future<GenerationTask> start() => agent.start(
      branchId: b.novel.activeBranchId,
      chapterId: b.chapter.id,
      connection: _model,
      duties: {SidecarDuty.memory},
    );
    final first = await start();
    // The replacement waits for the old run to stop, so its writes land
    // before the new run reads the lore.
    var replaced = false;
    final second = start()..then((_) => replaced = true);
    await pumpEventQueue();
    expect(replaced, isFalse);
    gate.complete();
    expect((await b.runner.wait(first.id)).status, TaskStatus.cancelled);
    expect(
      (await b.runner.wait((await second).id)).status,
      TaskStatus.completed,
    );
  });

  test('a sidecar run\'s errors name the sidecar', () async {
    final b = await _book([
      [const TextDelta('整理到一半')],
    ]);
    final task = await _run(b, {SidecarDuty.memory});
    expect(task.status, TaskStatus.interrupted);
    expect(task.error, contains('旁路整理会话流中断'));
  });

  test('task lists leave out a sidecar\'s transcript', () async {
    final b = await _book([]);
    final task = await _run(b, {SidecarDuty.memory});
    final listed = (await b.repo.listTasks(branchId: b.novel.activeBranchId))
        .single;
    expect(listed.result.containsKey('transcript'), isFalse);
    expect(listed.result['text'], '已整理');
    for (final whole in [
      await b.repo.getTask(task.id, snapshots: false),
      await b.repo.getTask(task.id),
    ]) {
      expect(whole.result['transcript'], [
        {'role': 'assistant', 'content': '已整理'},
      ]);
    }
  });

  test('a sidecar run writes its transcript once, not as it grows', () async {
    final spy = _TaskWrites();
    final script = <List<ProviderEvent>>[];
    final b = await _book(script, spy: spy);
    final note = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      kind: LoreKind.location,
      name: '渡口',
      content: '渡' * 2000,
    );
    for (var round = 0; round < 6; round++) {
      script.add([
        for (var i = 0; i < 4; i++)
          ToolCallReady('r$round$i', 'read_lore', {'id': note.id}),
        const GenerationFinished('tool_calls'),
      ]);
    }
    final task = await _run(b, {SidecarDuty.memory});
    expect(task.status, TaskStatus.completed, reason: task.error);
    expect(_toolResults(task), hasLength(24));
    final transcript = utf8.encode(jsonEncode(task.result['transcript']));
    // Saved with each of its 31 messages and every progress save, it wrote
    // 24 times its size.
    expect(spy.bytes, lessThan(2 * transcript.length));
  });

  test('a cancelled sidecar run keeps the messages it had', () async {
    final b = await _book([]);
    final asked = Completer<void>();
    var replies = 0;
    final runner = TaskRunner(
      repository: b.repo,
      providerFactory: (c) async => ScriptProvider(c, (_, cancel) async* {
        if (replies++ == 0) {
          yield ToolCallReady('l', 'list_lore', {});
          yield const GenerationFinished('tool_calls');
          return;
        }
        asked.complete();
        final stop = Completer<void>();
        cancel.onCancel(stop.complete);
        await stop.future;
        cancel.check();
      }),
    );
    addTearDown(runner.close);
    final task = await _start(
      (
        repo: b.repo,
        runner: runner,
        novel: b.novel,
        chapter: b.chapter,
        requests: b.requests,
      ),
      {SidecarDuty.memory},
    );
    await asked.future;
    // Cancelling marks the task before its run stops.
    await runner.cancel(task.id);
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.cancelled);
    expect(
      [
        for (final m in (done.result['transcript'] as List).cast<Map>())
          m['role'],
      ],
      ['assistant', 'tool'],
    );
  });

  test('a sidecar run on a remote runner is never requeued', () async {
    final b = await _book([]);
    final task = await b.repo.createTask(
      branchId: b.novel.activeBranchId,
      kind: TaskKind.sidecar,
      chapterId: b.chapter.id,
      input: {
        'connection': ModelConnection(
          id: 'r',
          name: '个人执行器',
          baseUrl: 'https://runner.example',
          model: 'writer',
          protocol: ModelProtocol.sillyDraftRunner,
        ).raw,
      },
    );
    await b.repo.updateTask(task.id, status: TaskStatus.failed, error: '中断');
    await expectLater(b.repo.requeueRemoteTask(task.id), throwsStateError);
  });

  /// The lore revisions a write on [chapterId] puts in its prompt, the
  /// prompt itself and its diagnostics' codes.
  Future<({List<Object?> revisions, String prompt, List<Object?> notes})>
  written(
    _Book b,
    String chapterId, {
    bool append = false,
    bool rewrite = false,
    int? rangeStart,
    int? rangeEnd,
  }) async {
    final draft = await WritingService(repository: b.repo, runner: b.runner)
        .prepare(
          branchId: b.novel.activeBranchId,
          chapterId: chapterId,
          connection: _model,
          brief: '写',
          append: append,
          rewrite: rewrite,
          rangeStart: rangeStart,
          rangeEnd: rangeEnd,
        );
    return (
      revisions: [
        for (final e in draft.input['loreRevisions'] as List)
          (e as Map)['revisionId'],
      ],
      prompt: jsonEncode(draft.input['request']),
      notes: [
        for (final d in draft.compiled['diagnostics'] as List)
          (d as Map)['code'],
      ],
    );
  }

  /// 林岚 as the author wrote her, then as the sidecar updated her at the
  /// book's chapter.
  Future<(LoreEntry, LoreEntry)> sidecarOver(_Book b) async {
    final v1 = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      kind: LoreKind.character,
      name: '林岚',
      content: '渡口的摆渡人',
    );
    final v2 = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      id: v1.id,
      expectedRevisionId: v1.revisionId,
      kind: LoreKind.character,
      name: '林岚',
      content: '雨夜救下落水者',
      atChapterId: b.chapter.id,
      provenance: {
        'type': 'sidecar',
        'taskId': 't',
        'chapterId': b.chapter.id,
        'revisionId': b.chapter.revisionId,
      },
    );
    return (v1, v2);
  }

  test(
    'rewriting a chapter whole leaves out the sidecar\'s notes on it',
    () async {
      final b = await _book([]);
      final (v1, v2) = await sidecarOver(b);
      final next = await b.repo.createChapter(
        branchId: b.novel.activeBranchId,
        title: '第二章 夜航',
      );
      final rewrite = await written(b, b.chapter.id, rewrite: true);
      expect(rewrite.revisions, [v1.revisionId]);
      expect(rewrite.prompt, contains('渡口的摆渡人'));
      expect(rewrite.prompt, isNot(contains('雨夜救下落水者')));
      for (final kept in [
        await written(b, b.chapter.id, append: true),
        await written(
          b,
          b.chapter.id,
          rewrite: true,
          rangeStart: 0,
          rangeEnd: 2,
        ),
        await written(b, next.id),
      ]) {
        expect(kept.revisions, [v2.revisionId]);
        expect(kept.prompt, contains('雨夜救下落水者'));
      }
    },
  );

  test('a sidecar note the author reviewed is theirs to keep', () async {
    final b = await _book([]);
    final (_, v2) = await sidecarOver(b);
    final edited = await b.repo.saveChapter(
      branchId: b.chapter.branchId,
      chapterId: b.chapter.id,
      expectedRevisionId: b.chapter.revisionId,
      content: ManuscriptContent.plainText('雨夜，林岚在渡口救下落水者。'),
    );
    // The lore page's "已对照最新正文复核": the same source, now reviewed.
    final reviewed = await b.repo.saveLoreEntry(
      branchId: b.novel.activeBranchId,
      id: v2.id,
      expectedRevisionId: v2.revisionId,
      kind: LoreKind.character,
      name: '林岚',
      content: '雨夜救下落水者',
      atChapterId: b.chapter.id,
      provenance: {
        ...v2.provenance,
        'revisionId': edited.revisionId,
        'reviewedAt': '2026-10-18T00:00:00.000Z',
      },
    );
    final rewrite = await written(b, b.chapter.id, rewrite: true);
    expect(rewrite.revisions, [reviewed.revisionId]);
    expect(rewrite.prompt, contains('雨夜救下落水者'));
    await b.repo.saveChapter(
      branchId: b.chapter.branchId,
      chapterId: b.chapter.id,
      expectedRevisionId: edited.revisionId,
      content: ManuscriptContent.plainText('改写后：渡口空无一人。'),
    );
    // Still tied to its chapter for review, but not the sidecar's to redo.
    final listed = (await b.repo.listLore(b.novel.activeBranchId)).single;
    expect(sidecarIndexEntry(listed, b.chapter.id), {
      'id': v2.id,
      'kind': 'character',
      'name': '林岚',
      'certainty': 'fact',
      'sourceStale': true,
    });
  });

  test('notes gone stale give way to the version before them', () async {
    final b = await _book([]);
    final (v1, _) = await sidecarOver(b);
    await b.repo.saveChapter(
      branchId: b.chapter.branchId,
      chapterId: b.chapter.id,
      expectedRevisionId: b.chapter.revisionId,
      content: ManuscriptContent.plainText('改写后：渡口空无一人。'),
    );
    final next = await b.repo.createChapter(
      branchId: b.novel.activeBranchId,
      title: '第二章 夜航',
    );
    final write = await written(b, next.id);
    expect(write.revisions, [v1.revisionId]);
    expect(write.prompt, contains('渡口的摆渡人'));
    expect(write.prompt, isNot(contains('雨夜救下落水者')));
    expect(write.notes, contains('stale_lore'));
    // The lore page still shows the stale note for review.
    final listed = (await b.repo.listLore(b.novel.activeBranchId)).single;
    expect(listed.content, '雨夜救下落水者');
    expect(listed.sourceStale, isTrue);
  });

  test('a write reads its notes and their staleness in one scan', () async {
    final scans = _LoreScans();
    final b = await _book([], spy: scans);
    final branchId = b.novel.activeBranchId, first = b.chapter.id;
    final next = await b.repo.createChapter(
      branchId: branchId,
      title: '第二章 夜航',
      content: ManuscriptContent.plainText('夜航船驶出渡口。'),
    );
    var head = b.chapter.revisionId;
    Future<void> edit(String text) async => head = (await b.repo.saveChapter(
      branchId: branchId,
      chapterId: first,
      expectedRevisionId: head,
      content: ManuscriptContent.plainText(text),
    )).revisionId;
    Future<LoreEntry> note(
      String name,
      String content, {
      LoreEntry? over,
      String? at,
      Map<String, dynamic>? provenance,
    }) => b.repo.saveLoreEntry(
      branchId: branchId,
      id: over?.id,
      expectedRevisionId: over?.revisionId,
      kind: LoreKind.character,
      name: name,
      content: content,
      atChapterId: at ?? first,
      provenance:
          provenance ??
          {
            'type': 'sidecar',
            'taskId': 't',
            'chapterId': first,
            'revisionId': head,
          },
    );
    // Each write must match what prepare gave when it listed the notes for
    // the prompt, then listed them again, plainly, for the stale warning.
    Future<bool> warned(
      String chapterId, {
      bool rewrite = false,
      int? rangeStart,
      int? rangeEnd,
    }) async {
      scans.count = 0;
      final got = await written(
        b,
        chapterId,
        rewrite: rewrite,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
      );
      expect(scans.count, 1);
      final lore = await b.repo.listLore(
        branchId,
        throughChapterId: chapterId,
        ignoreSidecarOf: rewrite && rangeStart == null ? chapterId : null,
        skipStaleVersions: true,
      );
      final stale = (await b.repo.listLore(
        branchId,
        throughChapterId: chapterId,
      )).any((e) => e.sourceStale);
      expect(got.revisions, [for (final e in lore) e.revisionId]);
      expect(got.notes.contains('stale_lore'), stale);
      return stale;
    }

    Future<List<bool>> writes() async => [
      for (final chapterId in [first, next.id]) ...[
        await warned(chapterId),
        await warned(chapterId, rewrite: true),
        await warned(chapterId, rewrite: true, rangeStart: 0, rangeEnd: 2),
      ],
    ];

    // A deleted note gone stale warns of nothing.
    final boat = await note('旧渡船', '沉在渡口');
    await b.repo.deleteLoreEntry(
      branchId: branchId,
      id: boat.id,
      expectedRevisionId: boat.revisionId,
      atChapterId: first,
    );
    await edit('雨夜，林岚撑着红伞走过渡口，船已不见。');
    expect(await writes(), List.filled(6, false));
    // A rewrite sets aside the sidecar's note; a reviewed one (written at
    // the next chapter) is the author's.
    final lin = await note(
      '林岚',
      '雨夜救下落水者',
      over: await note('林岚', '渡口的摆渡人', provenance: {'type': 'manual'}),
    );
    final umbrella = {
      'type': 'sidecar',
      'taskId': 't',
      'chapterId': first,
      'revisionId': head,
      'reviewedAt': '2026-10-18T00:00:00.000Z',
    };
    await note('红伞', '林岚的伞', at: next.id, provenance: umbrella);
    expect(await writes(), List.filled(6, false));
    await edit('改写后：渡口空无一人。');
    expect(await writes(), List.filled(6, true));
    // Reviewed again, 林岚 is current; only the next chapter's note is stale.
    await note(
      '林岚',
      '渡口空无一人',
      over: lin,
      provenance: {'type': 'manual', 'chapterId': first, 'revisionId': head},
    );
    expect(await writes(), [false, false, false, true, true, true]);
  });
}
