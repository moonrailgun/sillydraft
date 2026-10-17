import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  test(
    'editor tools freeze chapter scope and leave lore changes for review',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '按位置编辑');

      final first = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('门尚未打开'),
      );
      final later = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('门后是未来秘密'),
      );
      final lore = await repo.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.location,
        name: '旧宅',
        content: '锁住的大门',
        atChapterId: first.id,
      );
      await repo.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.world,
        name: '未来秘密',
        content: '未来秘密',
        atChapterId: later.id,
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
        throughChapterId: first.id,
      );
      final config = ModelConnection(
        id: 'test',
        name: 'test',
        baseUrl: 'http://localhost:1',
        model: 'test',
      );
      var round = 0;
      String? proposalTask;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          round++;
          if (round == 1) {
            expect(
              request.tools.map((t) => (t['function'] as Map)['name']),
              contains('propose_lore'),
            );
            yield ToolCallReady('l1', 'list_lore', {});
          } else if (round == 2) {
            expect(request.messages.last['content'], contains('旧宅'));
            expect(request.messages.last['content'], isNot(contains('未来秘密')));
            yield ToolCallReady('l2', 'read_lore', {'id': lore.id});
          } else if (round == 3) {
            expect(request.messages.last['content'], contains('锁住的大门'));
            yield ToolCallReady('l3', 'read_chapter', {'chapterId': later.id});
          } else if (round == 4) {
            expect(request.messages.last['content'], contains('error'));
            yield ToolCallReady('l4', 'propose_lore', {
              'kind': 'foreshadow',
              'name': '未开启的门',
              'content': '门后可能藏着线索',
              'certainty': 'inference',
              'sourceChapterId': first.id,
            });
          } else {
            final result =
                jsonDecode(request.messages.last['content'] as String) as Map;
            proposalTask = result['taskId'] as String;
            expect(result['accepted'], false);
            yield const TextDelta('已提出伏笔资料建议，等待审阅。');
            yield const GenerationFinished('stop');
            return;
          }
          yield const GenerationFinished('tool_calls');
        }),
      );
      addTearDown(runner.close);
      final task = await EditorAgent(
        repository: repo,
        runner: runner,
      ).send(conversationId: conversation, connection: config, message: '补充伏笔');
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      expect(proposalTask, isNotNull);
      expect((await repo.listLore(novel.activeBranchId)).length, 2);
      final accepted = await repo.acceptAnalysisEntry(
        taskId: proposalTask!,
        index: 0,
      );
      expect(accepted.certainty, LoreCertainty.inference);
      expect(accepted.atChapterId, first.id);
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: first.id,
        )).revisionId,
        first.revisionId,
      );
    },
  );
  test(
    'a chapter proposal tells of world book entries the budget left out',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '预算');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('故事正文'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      await repo.setSetting(
        WorldInfoBudget.settingKey,
        const WorldInfoBudget(cap: 1).toJson(),
      );
      Map? toolResult;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          if (request.tools.isEmpty) {
            // The chapter request the tool starts.
            yield const TextDelta('新段落');
          } else if (request.messages.last['role'] != 'tool') {
            yield ToolCallReady('w', 'propose_chapter', {
              'chapterId': chapter.id,
              'instructions': '续写',
              'append': true,
            });
            yield const GenerationFinished('tool_calls');
            return;
          } else {
            toolResult =
                jsonDecode(request.messages.last['content'] as String) as Map;
            yield const TextDelta('已写入正文。');
          }
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
        message: '续写一段',
        worldBooks: [
          ScopedWorldBook(
            WorldBook.fromJson({
              'entries': {
                '1': {'uid': 1, 'constant': true, 'content': '雾港旧事'},
              },
            }),
          ),
        ],
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      // The assistant's write goes straight into the chapter.
      expect(toolResult!['accepted'], true);
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text,
        contains('新段落'),
      );
      expect(
        toolResult!['worldBookBudget'],
        startsWith('世界书预算不够，1 个条目未放入。本次预算 1 token，受「预算上限」限制'),
      );
    },
  );

  test('editor completes a tool round within its branch without writing manuscript', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '编辑');

    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
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
          contains('read_chapter'),
        );
        if (rounds == 1) {
          yield ToolCallReady('c1', 'read_chapter', {'chapterId': chapter.id});
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
      (await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text,
      '故事正文\n',
    );
    expect(await repo.listProposals(novel.activeBranchId), isEmpty);
  });

  test('a replaced message drops itself and every later turn', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '重问');
    await repo.createChapter(
      branchId: novel.activeBranchId,
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
    final replies = ['答一', '答二', '答三'];
    final seen = <List<String>>[];
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        seen.add([
          for (final m in request.messages)
            if (m['role'] != 'system') '${m['content']}',
        ]);
        yield TextDelta(replies[seen.length - 1]);
        yield const GenerationFinished('stop');
      }),
    );
    addTearDown(runner.close);
    final agent = EditorAgent(repository: repo, runner: runner);
    Future<void> send(String message, {String? replace}) async {
      final task = await agent.send(
        conversationId: conversation,
        connection: connection,
        message: message,
        replaceMessageId: replace,
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
    }

    await send('问一');
    await send('问二');
    final second = (await repo.getAgentMessages(conversation))
        .firstWhere((m) => m.content == '问二');
    await send('问二改', replace: second.id);
    expect(seen.last, ['问一', '答一', '问二改']);
    expect(
      [for (final m in await repo.getAgentMessages(conversation)) m.content],
      ['问一', '答一', '问二改', '答三'],
    );
    final reply = (await repo.getAgentMessages(conversation)).last;
    expect(
      () => agent.send(
        conversationId: conversation,
        connection: connection,
        message: '不能替换回复',
        replaceMessageId: reply.id,
      ),
      throwsA(isA<StoryNotFound>()),
    );
  });

  test('a tool cannot read a chapter from a different project', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final first = await repo.createNovel(title: '当前');
    final second = await repo.createNovel(title: '另一个项目');

    final chapter = await repo.createChapter(
      branchId: second.activeBranchId,
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
          yield ToolCallReady('outside', 'read_chapter', {
            'chapterId': chapter.id,
          });
          yield const GenerationFinished('tool_calls');
        } else {
          expect(request.messages.last['content'], contains('error'));
          expect(request.messages.last['content'], isNot(contains('不能跨项目获取')));
          yield const TextDelta('当前分支没有这个章节。');
          yield const GenerationFinished('stop');
        }
      }),
    );
    addTearDown(runner.close);
    final task = await EditorAgent(repository: repo, runner: runner).send(
      conversationId: conversation,
      connection: connection,
      message: '查看章节',
    );
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
  });
}
