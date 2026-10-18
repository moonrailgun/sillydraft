import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

final class ScriptProvider implements ModelProvider {
  ScriptProvider(this.config, this.script, {this.titleScript});
  @override
  final ModelConnection config;
  final Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  final Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)?
  titleScript;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) {
    final cancel = cancellation ?? GenerationCancellation();
    // Keep auxiliary naming separate from the scripted conversation/tool rounds.
    if (request.executionId?.startsWith('conversation-title-') == true) {
      return titleScript?.call(request, cancel) ??
          Stream.fromIterable(const [
            TextDelta('测试会话'),
            GenerationFinished('stop'),
          ]);
    }
    return script(request, cancel);
  }

  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

/// Writes to task rows, and saves of streamed progress.
final class _TaskWrites extends QueryInterceptor {
  var rows = 0, progress = 0;
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.contains('UPDATE generation_tasks')) rows++;
    if (statement.contains('INSERT INTO task_progress')) progress++;
    return executor.runCustom(statement, args);
  }
}

void main() {
  late StoryRepository repository;
  late TaskRunner runner;
  late WritingService service;
  late ModelConnection connection;
  late Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  late Novel novel;
  late Chapter chapter;
  setUp(() async {
    repository = StoryRepository.memory();
    novel = await repository.createNovel(title: '生成测试');

    chapter = await repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('原文'),
    );
    connection = ModelConnection(
      id: 'local',
      name: 'Test',
      baseUrl: 'http://localhost:1234/v1',
      model: 'fiction-model',
    );
    script = (_, _) async* {
      yield const TextDelta('新正文');
      yield const GenerationFinished('stop');
    };
    runner = TaskRunner(
      repository: repository,
      providerFactory: (c) async => ScriptProvider(c, script),
    );
    service = WritingService(repository: repository, runner: runner);
  });
  tearDown(() async {
    await runner.close();
    await repository.close();
  });
  Future<GenerationTask> generate() => service.generate(
    branchId: novel.activeBranchId,
    chapterId: chapter.id,
    connection: connection,
    brief: '写下一段',
    append: true,
  );

  test('writing at an earlier chapter uses only lore and variables available there', () async {
    final later = await repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('未来的揭晓'),
    );
    await repository.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '早期人物',
      content: '身份未知',
      atChapterId: chapter.id,
    );
    await repository.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.world,
      name: '隐藏答案',
      content: '未来秘密答案',
      atChapterId: later.id,
    );
    await repository.setBranchVariables(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedVersion: 0,
      local: {'phase': '早期阶段'},
    );
    await repository.setBranchVariables(
      branchId: novel.activeBranchId,
      chapterId: later.id,
      expectedVersion: 1,
      local: {'phase': '未来秘密阶段'},
    );
    final draft = await service.prepare(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: connection,
      brief: '继续',
    );
    final request = draft.input['request'].toString();
    expect(request, contains('早期人物'));
    expect(request, isNot(contains('未来秘密答案')));
    expect((draft.input['variableResult'] as Map)['local'], {'phase': '早期阶段'});
    // The macro clock is kept as a UTC instant plus local time's offset.
    final clock = DateTime.parse(draft.input['clock'] as String);
    expect(clock.isUtc, isTrue);
    expect(draft.input['utcOffset'], clock.toLocal().timeZoneOffset.inMinutes);
  });

  test(
    'the world info budget setting reaches the prompt and the task',
    () async {
      final books = [
        ScopedWorldBook(
          WorldBook.fromJson({
            'entries': {
              '1': {'uid': 1, 'constant': true, 'content': '雾港的旧灯塔'},
            },
          }),
        ),
      ];
      Future<PreparedWriting> prepare() => service.prepare(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        brief: '继续',
        worldBooks: books,
      );
      List<Object?> codes(PreparedWriting draft) => [
        for (final d in draft.compiled['diagnostics'] as List) d['code'],
      ];
      final fresh = await prepare();
      expect(fresh.input['request'].toString(), contains('雾港的旧灯塔'));
      expect(fresh.input['worldInfoBudget'], {
        'world_info_budget': 25,
        'world_info_budget_cap': 0,
      });
      expect(codes(fresh), isNot(contains('world_book_budget_summary')));
      await repository.setSetting(
        WorldInfoBudget.settingKey,
        const WorldInfoBudget(cap: 1).toJson(),
      );
      final capped = await prepare();
      expect(capped.input['request'].toString(), isNot(contains('雾港的旧灯塔')));
      expect(capped.input['worldInfoBudget'], {
        'world_info_budget': 25,
        'world_info_budget_cap': 1,
      });
      expect(
        codes(capped),
        containsAll(['world_book_budget_summary', 'world_book_budget']),
      );
      expect(capped.canRun, isTrue, reason: 'a warning, not a blocker');
    },
  );

  test(
    'preview is frozen and selection rewrite preserves surrounding formatting',
    () async {
      chapter = await repository.saveChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: chapter.revisionId,
        content: ManuscriptContent.fromDelta([
          {
            'insert': '前文',
            'attributes': {'bold': true},
          },
          {'insert': '旧句。'},
          {
            'insert': '后文\n',
            'attributes': {'italic': true},
          },
        ]),
      );
      script = (request, _) async* {
        expect(request.messages.last['content'], contains('旧句。'));
        yield const TextDelta('新句。');
        yield const GenerationFinished('stop');
      };
      final prepared = await service.prepare(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        brief: '改写选中片段',
        rangeStart: 2,
        rangeEnd: 5,
        rewrite: true,
      );
      expect(
        await repository.listTasks(branchId: novel.activeBranchId),
        isEmpty,
      );
      final task = await service.startPrepared(prepared);
      expect(task.input['request'], prepared.input['request']);
      await runner.wait(task.id);
      final proposal = (await repository.listProposals(novel.activeBranchId))
          .single;
      expect(proposal.content.text, '前文新句。后文\n');
      expect(proposal.content.delta.first['attributes'], {'bold': true});
      expect(proposal.content.delta.last['attributes'], {'italic': true});
      expect(
        (await repository.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text,
        '前文旧句。后文\n',
      );
      await repository.acceptProposal(proposal.id);
      await expectLater(
        service.startPrepared(prepared),
        throwsA(isA<RevisionConflict>()),
      );
    },
  );

  test(
    'writing uses only accepted story and returns an append proposal',
    () async {
      script = (request, _) async* {
        expect(
          request.messages.any((m) => (m['content'] as String).contains('原文')),
          isTrue,
        );
        expect(
          request.messages.any(
            (m) => (m['content'] as String).contains('编辑闲聊'),
          ),
          isFalse,
        );
        yield const ReasoningDelta('不要放进正文');
        yield const TextDelta('新正文');
        yield const GenerationFinished('stop');
      };
      final conversation = await repository.createConversation(
        branchId: novel.activeBranchId,
      );
      await repository.appendAgentMessage(
        conversation,
        role: 'user',
        content: '编辑闲聊',
      );
      final task = await generate();
      final result = await runner.wait(task.id);
      expect(result.status, TaskStatus.completed);
      expect(result.reasoning, '不要放进正文');
      final proposal = (await repository.listProposals(novel.activeBranchId))
          .single;
      expect(proposal.content.text, '原文\n\n新正文\n');
      expect(
        (await repository.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text,
        '原文\n',
      );
    },
  );

  test('output regex reads the env the prompt was compiled with', () async {
    final card = CardImporter().decode(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v2',
            'data': {'name': '道渊', 'personality': ' 冷静{{user}} '},
          }),
        ),
      ),
      'card.json',
    );
    final task = await service.generate(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: connection,
      brief: '写下一段',
      append: true,
      card: card,
      userName: '阿雨',
      persona: '服饰：道袍',
      globalRegex: [
        {
          'findRegex': '/新正文/g',
          'replaceString': '{{persona}}|{{personality}}|{{char}}|{{model}}',
          'placement': [2],
        },
      ],
    );
    expect((task.input['macroEnv'] as Map)['persona'], '服饰：道袍');
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
    final proposal = (await repository.listProposals(novel.activeBranchId))
        .single;
    expect(proposal.content.text, '原文\n\n服饰：道袍|冷静阿雨|道渊|fiction-model\n');
  });

  test('output regex reads the chat the prompt was compiled with', () async {
    final task = await service.generate(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: connection,
      brief: '写下一段',
      append: true,
      globalRegex: [
        {
          'findRegex': '/新正文/g',
          'replaceString':
              '{{lastMessageId}}|{{allChatRange}}|{{lastCharMessage}}|'
              '{{lastSwipeId}}|{{firstIncludedMessageId}}|'
              '{{lastGenerationType}}',
          'placement': [2],
        },
      ],
    );
    // The chapter, then the brief; the reply is not in the chat yet, as in
    // ST's `cleanUpMessage`.
    expect((task.input['chatMacros'] as Map)['lastmessageid'], '1');
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
    final proposal = (await repository.listProposals(novel.activeBranchId))
        .single;
    expect(proposal.content.text, '原文\n\n1|0-1|原文\n||0|normal\n');
  });

  test('output regex reads the request\'s token limits and outlets', () async {
    final task = await service.generate(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: ModelConnection(
        id: 'local',
        name: 'Test',
        baseUrl: 'http://localhost:1234/v1',
        model: 'fiction-model',
        contextWindow: 16000,
        maxOutputTokens: 1000,
      ),
      brief: '写下一段',
      append: true,
      worldBooks: [
        ScopedWorldBook(
          WorldBook.fromJson({
            'entries': [
              {
                'constant': true,
                'content': '出口',
                'position': 7,
                'outletName': 'x',
              },
            ],
          }),
        ),
      ],
      globalRegex: [
        {
          'findRegex': '/新正文/g',
          'replaceString':
              '{{maxPrompt}}|{{maxContext}}|{{maxResponse}}|'
              '{{outlet::x}}|[{{input}}]',
          'placement': [2],
        },
      ],
    );
    expect((task.input['macroEnv'] as Map)['maxContext'], 16000);
    expect(task.input['outlets'], {'x': '出口'});
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
    final proposal = (await repository.listProposals(novel.activeBranchId))
        .single;
    expect(proposal.content.text, '原文\n\n15000|16000|1000|出口|[]\n');
  });

  test(
    'unknown and unclosed macros stay as written and the run proceeds',
    () async {
      script = (request, _) async* {
        expect(request.messages.first['content'], '{{NPC}}登场 {{char');
        yield const TextDelta('新正文');
        yield const GenerationFinished('stop');
      };
      final task = await service.generate(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        brief: '写下一段',
        append: true,
        preset: PresetImporter().decode({
          'name': 'npc',
          'prompts': [
            {
              'identifier': 'main',
              'role': 'system',
              'content': '{{NPC}}登场 {{char',
            },
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'main', 'enabled': true},
                {'identifier': 'chatHistory', 'enabled': true},
              ],
            },
          ],
        }),
        globalRegex: [
          {
            'findRegex': '/新正文/g',
            'replaceString': '{{NPC::x}} {{x',
            'placement': [2],
          },
        ],
      );
      final diagnostics =
          (task.input['compiled'] as Map)['diagnostics'] as List;
      for (final code in ['unknown_macro', 'unclosed_macro']) {
        expect(
          diagnostics.where((d) => d['code'] == code).single,
          containsPair('severity', 'warning'),
        );
      }
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      final proposal = (await repository.listProposals(novel.activeBranchId))
          .single;
      expect(proposal.content.text, '原文\n\n{{NPC::x}} {{x\n');
    },
  );

  test(
    'stream failure saves partial output and explicit retry uses a new task ID',
    () async {
      var calls = 0;
      script = (_, _) async* {
        calls++;
        yield const TextDelta('半段');
        if (calls == 1) throw const ProviderException('interrupted', '断开');
        yield const GenerationFinished('stop');
      };
      final first = await generate();
      final failed = await runner.wait(first.id);
      expect(failed.status, TaskStatus.interrupted);
      expect(failed.partialText, '半段');
      expect(calls, 1);
      expect(await repository.listProposals(novel.activeBranchId), isEmpty);
      final retried = await runner.resume(first.id);
      expect(retried.id, isNot(first.id));
      expect(retried.retryOf, first.id);
      expect((await runner.wait(retried.id)).status, TaskStatus.completed);
      expect(calls, 2);
    },
  );

  test('failed remote recovery retains durable output and full replay does not duplicate it', () async {
    connection = ModelConnection(
      id: 'remote',
      name: 'Runner',
      baseUrl: 'http://localhost:1234',
      model: 'fiction-model',
      protocol: ModelProtocol.sillyDraftRunner,
    );
    script = (_, _) async* {
      yield const TextDelta('已收到的正文');
      yield const ReasoningDelta('已收到的推理');
      throw const ProviderException('interrupted', '断线');
    };
    final task = await generate();
    await runner.wait(task.id);
    script = (request, _) async* {
      expect(request.retrieveOnly, isTrue);
      expect(request.executionId, task.id);
      throw const ProviderException('offline', '离线');
    };
    await runner.reconnectRemote(task.id);
    final failed = await runner.wait(task.id);
    expect(failed.partialText, '已收到的正文');
    expect(failed.reasoning, '已收到的推理');
    script = (_, _) async* {
      yield const TextDelta('已收到');
      yield const GenerationFinished('stop');
    };
    await runner.reconnectRemote(task.id);
    final shortReplay = await runner.wait(task.id);
    expect(shortReplay.status, TaskStatus.failed);
    expect(shortReplay.partialText, '已收到的正文');
    expect(shortReplay.reasoning, '已收到的推理');
    expect(await repository.listProposals(novel.activeBranchId), isEmpty);
    script = (request, _) async* {
      expect(request.retrieveOnly, isTrue);
      yield const ReasoningDelta('已收到的推理');
      yield const TextDelta('已收到的正文，继续完成。');
      yield const GenerationFinished('stop');
    };
    await runner.reconnectRemote(task.id);
    final completed = await runner.wait(task.id);
    expect(completed.status, TaskStatus.completed);
    expect(completed.partialText, '已收到的正文，继续完成。');
    expect(completed.reasoning, '已收到的推理');
    expect(
      (await repository.listProposals(novel.activeBranchId))
          .single
          .content
          .text,
      '原文\n\n已收到的正文，继续完成。\n',
    );
  });

  test(
    'user cancellation stops generation without accepting partial prose',
    () async {
      final firstChunk = Completer<void>();
      script = (_, cancel) async* {
        yield const TextDelta('部分');
        firstChunk.complete();
        final stopped = Completer<void>();
        final remove = cancel.onCancel(stopped.complete);
        await stopped.future;
        remove();
        cancel.check();
      };
      final task = await generate();
      await firstChunk.future;
      await runner.cancel(task.id);
      expect((await runner.wait(task.id)).status, TaskStatus.cancelled);
      expect(await repository.listProposals(novel.activeBranchId), isEmpty);
    },
  );

  test('length-limited responses remain failed partial tasks, never complete proposals', () async {
    script = (_, _) async* {
      yield const TextDelta('未完成');
      yield const GenerationFinished('length');
    };
    final task = await generate();
    final result = await runner.wait(task.id);
    expect(result.status, TaskStatus.failed);
    expect(result.partialText, '未完成');
    expect(await repository.listProposals(novel.activeBranchId), isEmpty);
  });

  test('branch candidates are structured side artifacts and never change facts or prose', () async {
    script = (_, _) async* {
      yield const TextDelta(
        '{"candidates":[{"title":"离港","summary":"去寻找父亲","opening":"船驶离港口。"},{"title":"留守","summary":"调查旧信","opening":"他回到灯塔。"}]}',
      );
      yield const GenerationFinished('stop');
    };
    final task = await service.suggestBranches(
      branchId: novel.activeBranchId,
      connection: connection,
      count: 2,
    );
    final result = await runner.wait(task.id);
    expect(result.status, TaskStatus.completed);
    expect(result.result['candidates'], hasLength(2));
    expect(await repository.listBranches(novel.id), hasLength(1));
    expect(await repository.listProposals(novel.activeBranchId), isEmpty);
  });

  test(
    'invalid model output keeps its text and reports a response format error',
    () async {
      script = (_, _) async* {
        yield const TextDelta('这不是 JSON');
        yield const GenerationFinished('stop');
      };
      final task = await service.suggestBranches(
        branchId: novel.activeBranchId,
        connection: connection,
        count: 2,
      );
      final result = await runner.wait(task.id);
      expect(result.status, TaskStatus.failed);
      expect(result.partialText, '这不是 JSON');
      expect(result.error, '返回结果未满足格式要求，原始输出已保留。');
      expect(await repository.listProposals(novel.activeBranchId), isEmpty);
    },
  );

  test('a chapter titled only by its number is named after its text', () async {
    final branchId = novel.activeBranchId;
    final bare = await repository.createChapter(
      branchId: branchId,
      content: ManuscriptContent.plainText('两只手在桌下交缠。'),
    );
    script = (_, _) async* {
      yield const TextDelta('<think>想想</think>\n章节名：《桌底下的契约》。');
      yield const GenerationFinished('stop');
    };
    expect(
      await service.nameChapter(
        branchId: branchId,
        chapterId: bare.id,
        connection: connection,
      ),
      '第二章 桌底下的契约',
    );
    // A chapter with a name keeps it.
    expect(
      await service.nameChapter(
        branchId: branchId,
        chapterId: bare.id,
        connection: connection,
      ),
      isNull,
    );
    final named = await repository.getChapter(
      branchId: branchId,
      chapterId: bare.id,
    );
    expect(named.title, '第二章 桌底下的契约');
    // A name the author gives meanwhile is kept.
    final other = await repository.createChapter(
      branchId: branchId,
      content: ManuscriptContent.plainText('雨停了。'),
    );
    script = (_, _) async* {
      await repository.renameChapter(
        branchId: branchId,
        chapterId: other.id,
        name: '作者起的名',
      );
      yield const TextDelta('雨后');
      yield const GenerationFinished('stop');
    };
    expect(
      await service.nameChapter(
        branchId: branchId,
        chapterId: other.id,
        connection: connection,
      ),
      isNull,
    );
    expect(
      (await repository.getChapter(
        branchId: branchId,
        chapterId: other.id,
      )).name,
      '作者起的名',
    );
  });

  test('task lists leave out request snapshots; the task keeps them', () async {
    final task = await repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {
        'brief': '写下一段',
        'preset': {'prompts': '大段预设'},
        'request': {'messages': <Object>[]},
      },
    );
    final listed = (await repository.listTasks(branchId: novel.activeBranchId))
        .single;
    expect(listed.input, {'brief': '写下一段'});
    expect((await repository.getTask(task.id, snapshots: false)).input, {
      'brief': '写下一段',
    });
    expect((await repository.getTask(task.id)).input['preset'], {
      'prompts': '大段预设',
    });
  });

  test(
    'a streamed chapter is saved a few times a second, not per delta',
    () async {
      script = (_, _) async* {
        for (var i = 0; i < 200; i++) {
          yield const TextDelta('字');
        }
        yield const GenerationFinished('stop');
      };
      var saves = 0;
      final counting = repository.changes.listen((_) => saves++);
      addTearDown(counting.cancel);
      final task = await generate();
      final done = await runner.wait(task.id);
      expect(done.partialText, '字' * 200);
      expect(saves, lessThan(20));
    },
  );

  for (final kind in [TaskKind.writing, TaskKind.sidecar]) {
    test('a streaming ${kind.name} run leaves its task row alone', () async {
      final spy = _TaskWrites();
      final repo = StoryRepository.connect(
        NativeDatabase.memory().interceptWith(spy),
      );
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '流式');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('原文'),
      );
      int? rowsWhileStreaming;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (_, _) async* {
          final before = spy.rows;
          for (var i = 0; i < 12; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
            yield const TextDelta('字');
          }
          rowsWhileStreaming = spy.rows - before;
          yield const GenerationFinished('stop');
        }),
      );
      addTearDown(runner.close);
      final task = kind == TaskKind.writing
          ? await WritingService(repository: repo, runner: runner).generate(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              connection: connection,
              brief: '写下一段',
              append: true,
            )
          : await runner.start(
              branchId: novel.activeBranchId,
              kind: kind,
              chapterId: chapter.id,
              baseRevisionId: chapter.revisionId,
              input: {
                'connection': connection.raw,
                'request': ProviderRequest(
                  messages: [
                    {'role': 'user', 'content': '整理资料'},
                  ],
                ).raw,
                'duties': [SidecarDuty.memory.name],
              },
            );
      final done = await runner.wait(task.id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(done.partialText, '字' * 12);
      expect(spy.progress, greaterThan(2));
      // SQLite rewrites a whole row whose size changes, and a task row
      // carries its run's frozen snapshots.
      expect(rowsWhileStreaming, 0);
    });
  }

  test('stopping keeps text the save throttle held back', () async {
    final reached = Completer<void>();
    script = (_, cancel) async* {
      yield const TextDelta('第一');
      yield const TextDelta('第二');
      yield const TextDelta('第三');
      reached.complete();
      final stopped = Completer<void>();
      cancel.onCancel(stopped.complete);
      await stopped.future;
      cancel.check();
    };
    final task = await generate();
    await reached.future;
    await runner.cancel(task.id);
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.cancelled);
    expect(done.partialText, '第一第二第三');
  });

  test('task progress is a change, but not a content change', () async {
    var all = 0, content = 0;
    final a = repository.changes.listen((_) => all++);
    final c = repository.contentChanges.listen((_) => content++);
    addTearDown(a.cancel);
    addTearDown(c.cancel);
    final task = await repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {'brief': '写下一段'},
    );
    await repository.updateTask(
      task.id,
      status: TaskStatus.running,
      partialText: '半句',
    );
    await repository.saveChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('改过的原文'),
    );
    await Future<void>.delayed(Duration.zero);
    expect((all, content), (3, 1));
  });
}
