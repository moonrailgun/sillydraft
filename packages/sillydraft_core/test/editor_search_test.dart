import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  test(
    'the editor finds words in the scenes it can see and knows the one in view',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '查找');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '一',
      );
      final dock = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '码头',
        content: ManuscriptContent.plainText('她把铜钥匙藏进袖口。'),
      );
      final tower = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '灯塔',
        content: ManuscriptContent.plainText('门锁生了锈，铜钥匙打不开。'),
      );
      await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '之后',
        content: ManuscriptContent.plainText('之后才出现的铜钥匙'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
        throughSceneId: tower.id,
      );
      Map? found;
      String? system;
      var round = 0;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          round++;
          if (round == 1) {
            system = request.messages.first['content'] as String;
            yield ToolCallReady('s1', 'search_story', {'query': '铜钥匙'});
            yield const GenerationFinished('tool_calls');
          } else {
            found =
                jsonDecode(request.messages.last['content'] as String) as Map;
            yield const TextDelta('铜钥匙出现在码头和灯塔。');
            yield const GenerationFinished('stop');
          }
        }),
      );
      addTearDown(runner.close);
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        ),
        message: '在正文中查找：铜钥匙',
        focusSceneId: dock.id,
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      expect(system, contains('作者正在看场景「码头」（sceneId: ${dock.id}）'));
      expect(found!['total'], 2);
      final matches = (found!['matches'] as List).cast<Map>();
      expect([for (final m in matches) m['title']], ['码头', '灯塔']);
      expect(matches.first['offset'], '她把'.length);
      expect(matches.last['snippet'], '门锁生了锈，铜钥匙打不开。\n');
    },
  );

  test(
    'a scene beyond the conversation position is never the one in view',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '范围');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '一',
      );
      final first = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '开端',
        content: ManuscriptContent.plainText('开端'),
      );
      final later = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '秘密',
        content: ManuscriptContent.plainText('秘密'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
        throughSceneId: first.id,
      );
      String? system;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          system = request.messages.first['content'] as String;
          yield const TextDelta('好的');
          yield const GenerationFinished('stop');
        }),
      );
      addTearDown(runner.close);
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        ),
        message: '看看这一幕',
        focusSceneId: later.id,
      );
      await runner.wait(task.id);
      expect(system, isNot(contains('作者正在看')));
      expect(system, isNot(contains(later.id)));
    },
  );
}
