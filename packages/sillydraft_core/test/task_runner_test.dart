import 'dart:async';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

final class ScriptProvider implements ModelProvider {
  ScriptProvider(this.config, this.script);
  @override
  final ModelConnection config;
  final Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => script(request, cancellation ?? GenerationCancellation());
  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

void main() {
  late StoryRepository repository;
  late TaskRunner runner;
  late WritingService service;
  late ModelConnection connection;
  late Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  late Novel novel;
  late Scene scene;
  setUp(() async {
    repository = StoryRepository.memory();
    novel = await repository.createNovel(title: '生成测试');
    final chapter = await repository.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    scene = await repository.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
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
    sceneId: scene.id,
    connection: connection,
    brief: '写下一段',
    append: true,
  );

  test(
    'writing at an earlier scene uses only lore and variables available there',
    () async {
      final later = await repository.createScene(
        branchId: novel.activeBranchId,
        chapterId: scene.chapterId,
        content: ManuscriptContent.plainText('未来的揭晓'),
      );
      await repository.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.character,
        name: '早期人物',
        content: '身份未知',
        atSceneId: scene.id,
      );
      await repository.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.world,
        name: '隐藏答案',
        content: '未来秘密答案',
        atSceneId: later.id,
      );
      await repository.setBranchVariables(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
        expectedVersion: 0,
        local: {'phase': '早期阶段'},
      );
      await repository.setBranchVariables(
        branchId: novel.activeBranchId,
        sceneId: later.id,
        expectedVersion: 1,
        local: {'phase': '未来秘密阶段'},
      );
      final draft = await service.prepare(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
        connection: connection,
        brief: '继续',
      );
      final request = draft.input['request'].toString();
      expect(request, contains('早期人物'));
      expect(request, isNot(contains('未来秘密答案')));
      expect((draft.input['variableResult'] as Map)['local'], {
        'phase': '早期阶段',
      });
    },
  );

  test(
    'preview is frozen and selection rewrite preserves surrounding formatting',
    () async {
      scene = await repository.saveScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
        expectedRevisionId: scene.revisionId,
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
        sceneId: scene.id,
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
        (await repository.getScene(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
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
        (await repository.getScene(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
        )).content.text,
        '原文\n',
      );
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
}
