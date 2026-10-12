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
