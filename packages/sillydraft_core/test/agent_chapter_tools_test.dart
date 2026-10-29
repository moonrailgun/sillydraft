import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

Future<GenerationTask> runTools(
  StoryRepository repo,
  String conversation,
  List<ToolCallReady> calls, {
  Future<void> Function(int)? beforeCall,
  Future<String> Function(int)? write,
  List<ProviderRequest>? writingRequests,
}) async {
  var round = 0, writes = 0;
  final runner = TaskRunner(
    repository: repo,
    providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
      if (request.executionId?.startsWith('writing-quality-') == true) {
        yield const TextDelta('{"issues":[]}');
      } else if (request.tools.isEmpty) {
        writes++;
        writingRequests?.add(request);
        yield TextDelta(await write?.call(writes) ?? '新正文$writes');
      } else if (round < calls.length) {
        await beforeCall?.call(round);
        yield calls[round++];
        yield const GenerationFinished('tool_calls');
        return;
      } else {
        yield const TextDelta('已处理');
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
    message: '按要求管理章节并写作',
  );
  final done = await runner.wait(task.id);
  expect(done.status, TaskStatus.completed, reason: done.error);
  return done;
}

Future<List<Map>> resultsOf(StoryRepository repo, String conversation) async =>
    [
      for (final m in await repo.getAgentMessages(conversation))
        if (m.role == 'tool') jsonDecode(m.content) as Map,
    ];

void main() {
  for (final scoped in [false, true]) {
    test(
      'chapter operations compose and preserve empty chapters (scoped=$scoped)',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '章节管理');
        final branch = novel.activeBranchId;
        final first = await repo.createChapter(branchId: branch, name: '启程');
        final conversation = await repo.createConversation(
          branchId: branch,
          title: '测试',
          throughChapterId: scoped ? first.id : null,
        );
        final done = await runTools(repo, conversation, [
          ToolCallReady('create', 'create_chapter', {'name': '未命名'}),
          ToolCallReady('rename', 'rename_chapter', {
            'chapterName': '未命名',
            'name': '归途',
          }),
          ToolCallReady('write', 'propose_chapter', {
            'chapterName': '归途',
            'instructions': '写一章',
            'append': false,
          }),
          ToolCallReady('append', 'propose_chapter', {
            'chapterName': '第一章 启程',
            'instructions': '续写',
            'append': true,
          }),
          ToolCallReady('create2', 'create_chapter', {'name': '待删'}),
          ToolCallReady('delete', 'delete_chapter', {'chapterName': '待删'}),
          ToolCallReady('read', 'read_chapter', {'chapterName': '归途'}),
          ToolCallReady('list', 'list_chapters', {}),
        ]);
        final results = await resultsOf(repo, conversation);
        expect(results.where((r) => r.containsKey('error')), isEmpty);
        final story = await repo.getStory(branch);
        expect(story.chapters.map((c) => c.name), ['启程', '归途']);
        expect(story.chapters.map((c) => c.content.text), ['新正文2\n', '新正文1\n']);
        expect(results[2]['accepted'], true);
        expect(results[3]['accepted'], true);
        expect(done.result['writtenChapters'], {
          for (final c in story.chapters) c.id: c.revisionId,
        });
        expect(results[6]['text'], '新正文1\n');
        expect(results[7]['chapters'].length, 2);
        expect(results[7]['chapters'][1]['canEdit'], true);
        expect(
          await repo.conversationChapter(conversation),
          scoped ? story.chapters.last.id : null,
        );
        expect(done.input['chapterSnapshot'].length, 1);
        expect(
          done.input['sourceRevisions'][0]['revisionId'],
          first.revisionId,
        );
      },
    );
  }

  test('successive chapters use accepted text and lore suggestions use current sources', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '连续写作');
    final branch = novel.activeBranchId;
    final first = await repo.createChapter(branchId: branch, name: '开篇');
    final conversation = await repo.createConversation(
      branchId: branch,
      title: '测试',
      throughChapterId: first.id,
    );
    final requests = <ProviderRequest>[];
    await runTools(repo, conversation, [
      for (final name in ['相遇', '归途']) ...[
        ToolCallReady('create-$name', 'create_chapter', {'name': name}),
        ToolCallReady('write-$name', 'propose_chapter', {
          'chapterName': name,
          'instructions': '写本章',
          'append': false,
        }),
      ],
      ToolCallReady('lore', 'propose_lore', {
        'kind': 'world',
        'name': '城镇',
        'content': '旅途中的城镇',
        'certainty': 'plan',
        'sourceChapterId': first.id,
      }),
    ], writingRequests: requests);
    final results = await resultsOf(repo, conversation);
    expect(results.where((r) => r.containsKey('error')), isEmpty);
    final story = await repo.getStory(branch);
    expect(story.chapters.map((c) => c.content.text), [
      '\n',
      '新正文1\n',
      '新正文2\n',
    ]);
    expect(requests, hasLength(2));
    expect(jsonEncode(requests[1].messages), contains('新正文1'));
    expect(results[1]['accepted'], true);
    expect(results[3]['accepted'], true);
    final suggestion = await repo.getTask(results.last['taskId'] as String);
    expect(await repo.taskSourcesCurrent(suggestion.id), true);
    expect(suggestion.input['throughChapterId'], story.chapters.last.id);
    expect(suggestion.input['sourceRevisions'].length, 3);
  });

  for (final change in ['edit', 'rename', 'append', 'failed', 'conflict']) {
    test(
      'chapter operations stop on $change without overwriting concurrent work',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '冲突');
        final branch = novel.activeBranchId;
        final first = await repo.createChapter(branchId: branch, name: '开篇');
        final conversation = await repo.createConversation(
          branchId: branch,
          title: '测试',
        );
        var writes = 0;
        await runTools(
          repo,
          conversation,
          [
            ToolCallReady('create', 'create_chapter', {'name': '后续'}),
            ToolCallReady('write', 'propose_chapter', {
              'chapterName': '后续',
              'instructions': '写正文',
              'append': false,
            }),
            ToolCallReady('create2', 'create_chapter', {'name': '不应创建'}),
          ],
          beforeCall: (round) async {
            if (round != 2) return;
            if (change == 'edit') {
              await repo.saveChapter(
                branchId: branch,
                chapterId: first.id,
                expectedRevisionId: first.revisionId,
                content: ManuscriptContent.plainText('作者修改'),
              );
            } else if (change == 'rename') {
              await repo.renameChapter(
                branchId: branch,
                chapterId: first.id,
                name: '作者改名',
              );
            } else if (change == 'append') {
              await repo.createChapter(branchId: branch, name: '作者新章');
            }
          },
          write: (_) async {
            writes++;
            if (change == 'failed') {
              throw const ProviderException('test', '测试失败');
            }
            if (change == 'conflict') {
              final chapter = (await repo.getStory(branch)).chapters.last;
              await repo.saveChapter(
                branchId: branch,
                chapterId: chapter.id,
                expectedRevisionId: chapter.revisionId,
                content: ManuscriptContent.plainText('作者修改'),
              );
            }
            return '助手正文';
          },
        );
        final results = await resultsOf(repo, conversation);
        expect(writes, 1);
        expect(
          results[2]['code'],
          ['failed', 'conflict'].contains(change)
              ? 'writing_stopped'
              : 'source_changed',
        );
        final story = await repo.getStory(branch);
        expect(story.chapters.length, change == 'append' ? 3 : 2);
        expect(story.chapters.any((c) => c.name == '不应创建'), false);
        if (change == 'conflict') {
          expect(story.chapters.last.content.text, '作者修改\n');
        }
      },
    );
  }

  test(
    'duplicate names require an ID and missing targets never write',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '重名');
      final first = await repo.createChapter(
        branchId: novel.activeBranchId,
        name: '重名',
      );
      await repo.createChapter(branchId: novel.activeBranchId, name: '重名');
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
        title: '测试',
      );
      await runTools(repo, conversation, [
        ToolCallReady('ambiguous', 'propose_chapter', {
          'chapterName': '重名',
          'instructions': '重写',
          'append': false,
        }),
        ToolCallReady('missing', 'delete_chapter', {'chapterName': '不存在'}),
        ToolCallReady('both', 'rename_chapter', {
          'chapterId': first.id,
          'chapterName': '重名',
          'name': '错误',
        }),
        ToolCallReady('id', 'rename_chapter', {
          'chapterId': first.id,
          'name': '唯一',
        }),
      ]);
      final results = await resultsOf(repo, conversation);
      expect(results[0]['code'], 'ambiguous_chapter');
      expect(results[0]['chapters'].length, 2);
      expect(results[1]['code'], 'out_of_scope');
      expect(results[2]['error'], isNotNull);
      expect(results[3]['name'], '唯一');
      expect(await repo.listProposals(novel.activeBranchId), isEmpty);
    },
  );

  for (final scenario in ['boundary', 'only', 'hidden', 'active']) {
    test(
      'deleting scoped chapter preserves conversation and scope: $scenario',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '删除');
        final branch = novel.activeBranchId;
        final first = await repo.createChapter(branchId: branch, name: '前章');
        final target = scenario == 'boundary'
            ? await repo.createChapter(branchId: branch, name: '目标')
            : first;
        if (scenario == 'hidden') {
          await repo.createChapter(branchId: branch, name: '隐藏后文');
        }
        if (scenario == 'active') {
          await repo.createTask(
            branchId: branch,
            kind: TaskKind.writing,
            chapterId: target.id,
            input: {},
          );
        }
        final conversation = await repo.createConversation(
          branchId: branch,
          title: '测试',
          throughChapterId: target.id,
        );
        await runTools(repo, conversation, [
          ToolCallReady('delete', 'delete_chapter', {'chapterId': target.id}),
          ToolCallReady('list', 'list_chapters', {}),
        ]);
        final results = await resultsOf(repo, conversation);
        final blocked = ['hidden', 'active'].contains(scenario);
        expect(results.first.containsKey('error'), blocked);
        expect(results.last['chapters'].length, scenario == 'only' ? 0 : 1);
        expect(jsonEncode(results), isNot(contains('隐藏后文')));
        expect(
          await repo.conversationChapter(conversation),
          blocked
              ? target.id
              : scenario == 'only'
              ? null
              : first.id,
        );
        expect(await repo.getRevision(target.revisionId), isNotNull);
      },
    );
  }

  test(
    'historical scope cannot create past or write into unseen chapters',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '范围');
      final branch = novel.activeBranchId;
      final first = await repo.createChapter(branchId: branch, name: '可见');
      final hidden = await repo.createChapter(branchId: branch, name: '隐藏');
      final conversation = await repo.createConversation(
        branchId: branch,
        title: '测试',
        throughChapterId: first.id,
      );
      await runTools(repo, conversation, [
        ToolCallReady('create', 'create_chapter', {'name': '新章'}),
        ToolCallReady('write', 'propose_chapter', {
          'chapterId': hidden.id,
          'instructions': '写正文',
          'append': false,
        }),
        ToolCallReady('list', 'list_chapters', {}),
      ]);
      final results = await resultsOf(repo, conversation);
      expect(results[0]['error'], isNotNull);
      expect(results[1]['code'], 'out_of_scope');
      expect(results[2]['chapters'].length, 1);
      expect((await repo.getStory(branch)).chapters.length, 2);
      expect(await repo.listProposals(branch), isEmpty);
    },
  );
}
