import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  test('agent reads its accepted snapshot and refuses a write after an external edit', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '写后读取');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('旧正文'),
    );
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    final connection = ModelConnection(
      id: 'test',
      name: 'test',
      baseUrl: 'http://localhost:1',
      model: 'test',
    );
    var rounds = 0, writes = 0;
    final results = <Map>[];
    final offered = <List<String>>[];
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        if (request.executionId?.startsWith('writing-quality-') == true) {
          yield const TextDelta('{"issues":[]}');
          yield const GenerationFinished('stop');
          return;
        }
        if (request.tools.isEmpty) {
          writes++;
          yield const TextDelta('新正文');
          yield const GenerationFinished('stop');
          return;
        }
        offered.add([
          for (final tool in request.tools) tool['function']['name'] as String,
        ]);
        results.addAll([
          for (final message
              in request.messages
                  .where((m) => m['role'] == 'tool')
                  .skip(results.length))
            jsonDecode(message['content'] as String) as Map,
        ]);
        switch (++rounds) {
          case 1:
            yield ToolCallReady('write', 'propose_chapter', {
              'chapterId': chapter.id,
              'instructions': '重写',
              'append': false,
            });
          case 2:
            final current = await repo.getChapter(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
            );
            await repo.saveChapter(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              expectedRevisionId: current.revisionId,
              content: ManuscriptContent.plainText('作者后续编辑'),
            );
            yield ToolCallReady('read', 'read_chapter', {
              'chapterId': chapter.id,
            });
            yield ToolCallReady('list', 'list_chapters', {});
            yield ToolCallReady('search', 'search_story', {'query': '新正文'});
          case 3:
            yield ToolCallReady('repeat', 'propose_chapter', {
              'chapterId': chapter.id,
              'instructions': '重写',
              'append': true,
            });
          default:
            yield const TextDelta('已写入。');
            yield const GenerationFinished('stop');
            return;
        }
        yield const GenerationFinished('tool_calls');
      }),
    );
    addTearDown(runner.close);
    final task = await EditorAgent(repository: repo, runner: runner).send(
      conversationId: conversation,
      connection: connection,
      message: '重写本章',
    );
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    final accepted = (await repo.listProposals(novel.activeBranchId)).single;
    expect(results[1]['text'], '新正文\n');
    expect(results[1]['revisionId'], accepted.acceptedRevisionId);
    expect(
      results[2]['chapters'][0]['revisionId'],
      accepted.acceptedRevisionId,
    );
    expect(results[2]['chapters'][0]['canEdit'], true);
    expect(results[3]['total'], 1);
    expect(results[4]['code'], 'source_changed');
    expect(results[4]['retryable'], false);
    expect(offered[1], contains('propose_chapter'));
    expect(writes, 1);
    expect(
      (await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text,
      '作者后续编辑\n',
    );
    expect(done.input['chapterSnapshot'][0]['text'], '旧正文\n');
    expect(done.input['sourceRevisions'][0]['revisionId'], chapter.revisionId);
  });

  test(
    'an external edit still blocks writing with a nonretryable reason',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '冲突');
      final chapter = await repo.createChapter(branchId: novel.activeBranchId);
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      var rounds = 0, writes = 0;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          if (request.tools.isEmpty) writes++;
          if (++rounds == 1) {
            await repo.saveChapter(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              expectedRevisionId: chapter.revisionId,
              content: ManuscriptContent.plainText('作者另行修改'),
            );
            yield ToolCallReady('write', 'propose_chapter', {
              'chapterId': chapter.id,
              'instructions': '续写',
              'append': true,
            });
            yield ToolCallReady('list', 'list_chapters', {});
            yield const GenerationFinished('tool_calls');
          } else {
            yield const TextDelta('正文已变化，请重新发起请求。');
            yield const GenerationFinished('stop');
          }
        }),
      );
      addTearDown(runner.close);
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: ModelConnection(
          id: 't',
          name: 't',
          baseUrl: 'http://localhost:1',
          model: 't',
        ),
        message: '续写',
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      final results = [
        for (final m in await repo.getAgentMessages(conversation))
          if (m.role == 'tool') jsonDecode(m.content) as Map,
      ];
      expect(results[0]['code'], 'source_changed');
      expect(results[0]['retryable'], false);
      expect(results[1]['chapters'][0]['canEdit'], false);
      expect(writes, 0);
      expect(await repo.listProposals(novel.activeBranchId), isEmpty);
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text,
        '作者另行修改\n',
      );
    },
  );
}
