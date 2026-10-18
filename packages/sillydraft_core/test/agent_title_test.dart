import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  late StoryRepository repository;
  late TaskRunner runner;
  late EditorAgent agent;
  late Novel novel;
  late String conversation;
  late ModelConnection connection;
  late Stream<ProviderEvent> Function() titleReply;
  late List<ProviderRequest> titleRequests;

  setUp(() async {
    repository = StoryRepository.memory();
    novel = await repository.createNovel(title: '标题测试');
    conversation = await repository.createConversation(
      branchId: novel.activeBranchId,
    );
    connection = ModelConnection(
      id: 'test',
      name: 'test',
      baseUrl: 'http://localhost:1',
      model: 'test',
    );
    titleRequests = [];
    titleReply = () async* {
      yield const TextDelta('<think>概括主题</think>\n标题：“旧宅伏笔设计”');
      yield const GenerationFinished('stop');
    };
    runner = TaskRunner(
      repository: repository,
      providerFactory: (c) async => ScriptProvider(
        c,
        (request, _) async* {
          yield const TextDelta('可以从旧宅的大门埋下伏笔。');
          yield const GenerationFinished('stop');
        },
        titleScript: (request, _) async* {
          titleRequests.add(request);
          yield* titleReply();
        },
      ),
    );
    agent = EditorAgent(repository: repository, runner: runner);
  });

  tearDown(() async {
    await runner.close();
    await repository.close();
  });

  Future<GenerationTask> send([String message = '帮我设计旧宅的伏笔']) async {
    final task = await agent.send(
      conversationId: conversation,
      connection: connection,
      message: message,
    );
    return runner.wait(task.id);
  }

  Future<String> title() async =>
      (await repository.listConversations(novel.activeBranchId))
              .singleWhere((row) => row['id'] == conversation)['title']
          as String;

  test(
    'first reply names the conversation without changing the transcript',
    () async {
      final task = await send();
      expect(task.status, TaskStatus.completed);
      expect(await title(), '旧宅伏笔设计');
      expect(task.partialText, '可以从旧宅的大门埋下伏笔。');
      expect(
        (await repository.getAgentMessages(conversation)).map((m) => m.content),
        ['帮我设计旧宅的伏笔', '可以从旧宅的大门埋下伏笔。'],
      );
      final request = titleRequests.single;
      expect(request.tools, isEmpty);
      expect(request.parameters, isEmpty);
      expect(request.messages.last['content'], contains('帮我设计旧宅的伏笔'));
      expect(request.messages.last['content'], contains('可以从旧宅的大门埋下伏笔。'));
      await send('继续讨论');
      expect(await title(), '旧宅伏笔设计');
      expect(titleRequests, hasLength(1));
    },
  );

  test('custom conversation titles are preserved', () async {
    conversation = await repository.createConversation(
      branchId: novel.activeBranchId,
      title: '我的伏笔笔记',
    );
    expect((await send()).status, TaskStatus.completed);
    expect(await title(), '我的伏笔笔记');
    expect(titleRequests, isEmpty);
  });

  test('a title saved during generation is not overwritten', () async {
    titleReply = () async* {
      await repository.nameConversation(conversation, '作者的命名');
      yield const TextDelta('旧宅伏笔设计');
      yield const GenerationFinished('stop');
    };
    expect((await send()).status, TaskStatus.completed);
    expect(titleRequests, hasLength(1));
    expect(await title(), '作者的命名');
  });

  for (final failure in [
    'error',
    'empty',
    'long',
    'interrupted',
    'incomplete',
  ]) {
    test('unusable title ($failure) preserves the completed reply', () async {
      titleReply = () async* {
        if (failure == 'error') {
          throw const ProviderException('test', '命名不可用');
        }
        yield TextDelta(switch (failure) {
          'empty' => ' ',
          'long' => '很长的标题' * 20,
          _ => '旧宅伏笔设计',
        });
        if (failure != 'interrupted') {
          yield GenerationFinished(failure == 'incomplete' ? 'length' : 'stop');
        }
      };
      final task = await send();
      expect(titleRequests, hasLength(1));
      expect(task.status, TaskStatus.completed);
      expect(task.partialText, '可以从旧宅的大门埋下伏笔。');
      expect(await title(), '创作会话');
      await send('继续讨论');
      expect(titleRequests, hasLength(1));
    });
  }
}
