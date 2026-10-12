import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  test('editor completes a tool round within its branch without writing manuscript', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '编辑');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    final scene = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      content: ManuscriptContent.plainText('故事正文'),
    );
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    final connection = ModelConnection(
      id: 'test',
      name: 'Test',
      baseUrl: 'http://localhost:1234',
      model: 'test',
    );
    var rounds = 0;
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        rounds++;
        expect(
          request.tools.map((t) => (t['function'] as Map)['name']),
          contains('read_scene'),
        );
        if (rounds == 1) {
          yield ToolCallReady('c1', 'read_scene', {'sceneId': scene.id});
          yield const GenerationFinished('tool_calls');
        } else {
          expect(request.messages.last['role'], 'tool');
          expect(request.messages.last['content'], contains('故事正文'));
          yield const TextDelta('这段可以加强环境描写。');
          yield const GenerationFinished('stop');
        }
      }),
    );
    addTearDown(runner.close);
    final agent = EditorAgent(repository: repo, runner: runner);
    final task = await agent.send(
      conversationId: conversation,
      connection: connection,
      message: '帮我看这段',
    );
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
    expect(rounds, 2);
    expect(
      (await repo.getAgentMessages(conversation)).last.content,
      '这段可以加强环境描写。',
    );
    expect(
      (await repo.getScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
      )).content.text,
      '故事正文\n',
    );
    expect(await repo.listProposals(novel.activeBranchId), isEmpty);
  });

  test('a tool cannot read a scene from a different project', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final first = await repo.createNovel(title: '当前');
    final second = await repo.createNovel(title: '另一个项目');
    final chapter = await repo.createChapter(
      branchId: second.activeBranchId,
      title: '一',
    );
    final scene = await repo.createScene(
      branchId: second.activeBranchId,
      chapterId: chapter.id,
      content: ManuscriptContent.plainText('不能跨项目获取'),
    );
    final conversation = await repo.createConversation(
      branchId: first.activeBranchId,
    );
    final connection = ModelConnection(
      id: 'test',
      name: 'Test',
      baseUrl: 'http://localhost:1234',
      model: 'test',
    );
    var rounds = 0;
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        if (++rounds == 1) {
          yield ToolCallReady('outside', 'read_scene', {'sceneId': scene.id});
          yield const GenerationFinished('tool_calls');
        } else {
          expect(request.messages.last['content'], contains('error'));
          expect(request.messages.last['content'], isNot(contains('不能跨项目获取')));
          yield const TextDelta('当前分支没有这个场景。');
          yield const GenerationFinished('stop');
        }
      }),
    );
    addTearDown(runner.close);
    final task = await EditorAgent(repository: repo, runner: runner).send(
      conversationId: conversation,
      connection: connection,
      message: '查看场景',
    );
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
  });
}
