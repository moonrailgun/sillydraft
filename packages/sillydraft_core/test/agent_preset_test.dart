import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

ImportedPreset _chatPreset() => PresetImporter().decode({
  'name': '雾港文风',
  'temperature': 0.9,
  'top_p': 0.8,
  'assistant_prefill': '好的，',
  'prompts': [
    {
      'identifier': 'main',
      'name': 'Main',
      'role': 'system',
      'content': '你是{{char}}的文风顾问，回答要简短。',
    },
    {'identifier': 'chatHistory', 'name': 'Chat History', 'marker': true},
    {
      'identifier': 'jailbreak',
      'name': 'Post-History',
      'role': 'system',
      'content': '记住：只用中文。',
    },
    {
      'identifier': 'unused',
      'name': 'Disabled',
      'role': 'system',
      'content': '不应出现',
    },
  ],
  'prompt_order': [
    {
      'character_id': 100001,
      'order': [
        {'identifier': 'main', 'enabled': true},
        {'identifier': 'chatHistory', 'enabled': true},
        {'identifier': 'jailbreak', 'enabled': true},
        {'identifier': 'unused', 'enabled': false},
      ],
    },
  ],
});

void main() {
  for (final invalid in [false, true]) {
    test(
      'assistant preset markers do not block; preparation failure: $invalid',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '预设兼容');
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        var called = false;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async {
            called = true;
            return ScriptProvider(c, (_, _) async* {
              yield const TextDelta('收到');
              yield const GenerationFinished('stop');
            });
          },
        );
        addTearDown(runner.close);
        final raw = _chatPreset().exportJson();
        final prompts = raw['prompts'] as List;
        final order = (raw['prompt_order'] as List).single['order'] as List;
        for (final id in ['agentTask', 'agentSystemPrompt', 'agentResults']) {
          prompts.add({
            'identifier': id,
            'marker': true,
            'system_prompt': true,
            'content': '',
          });
          order.add({'identifier': id, 'enabled': true});
        }
        if (invalid) {
          (prompts.first as Map)['injection_position'] = 99;
        }
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: ModelConnection(
            id: 't',
            name: 't',
            baseUrl: 'http://localhost:1',
            model: 't',
          ),
          message: '请继续',
          chatPreset: PresetImporter().decode(raw),
        );
        await runner.wait(task.id);
        final stored = await repo.getTask(task.id);
        expect(called, !invalid);
        expect(
          stored.status,
          invalid ? TaskStatus.failed : TaskStatus.completed,
        );
        if (invalid) {
          expect(stored.error, contains('发送前准备失败'));
          expect(stored.error, contains('不支持的注入位置：99'));
          expect(stored.error, contains('尚未请求模型'));
          expect(stored.error, isNot(contains('原始输出已保留')));
          expect(stored.partialText, isEmpty);
          expect(stored.input['agentMessage'], '请继续');
          expect(await repo.getAgentMessages(conversation), isEmpty);
        }
      },
    );
  }

  test(
    'a chat preset assembles the editing conversation, rules stay first',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '雾港');

      await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('雾从港口升起'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '先前的问题',
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: '先前的回答',
      );
      ProviderRequest? seen;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
          seen = request;
          yield const TextDelta('收到');
          yield const GenerationFinished('stop');
        }),
      );
      addTearDown(runner.close);
      // The world info budget setting applies here too.
      await repo.setSetting(
        WorldInfoBudget.settingKey,
        const WorldInfoBudget(cap: 1).toJson(),
      );
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: ModelConnection(
          id: 't',
          name: 't',
          baseUrl: 'http://localhost:1',
          model: 't',
        ),
        message: '这一章的节奏如何？',
        card: const CardImporter().decode(
          Uint8List.fromList(utf8.encode('{"name":"沈砚","description":"看守人"}')),
          'card.json',
        ),
        chatPreset: _chatPreset(),
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
      await runner.wait(task.id);
      final messages = seen!.messages;
      final contents = messages.map((m) => m['content'] as String).toList();

      expect(messages.first['role'], 'system');
      expect(contents.first, startsWith(editorInstructions));
      expect(contents[1], '你是沈砚的文风顾问，回答要简短。', reason: 'macros rendered');
      expect(contents.sublist(2, 5), ['先前的问题', '先前的回答', '这一章的节奏如何？']);
      expect(contents[5], '记住：只用中文。', reason: 'post-history after chat');
      expect(contents.last, contains('继续处理作者本轮的请求'));
      expect(contents.first, isNot(contains('不能自行采纳')));
      expect(contents, isNot(contains('不应出现')));
      expect(seen!.tools, isNotEmpty, reason: 'editing tools are kept');
      expect(seen!.parameters['temperature'], 0.9);
      expect(seen!.parameters['top_p'], 0.8);
      expect(seen!.parameters.containsKey('assistant_prefill'), isFalse);

      final stored = await repo.getTask(task.id);
      expect(stored.status, TaskStatus.completed);
      final record = stored.input['agentPreset'] as Map<String, dynamic>;
      expect(record['name'], '雾港文风');
      expect(record['droppedParameters'], ['assistant_prefill']);
      expect([
        for (final d in record['diagnostics'] as List) d['code'],
      ], contains('world_book_budget_summary'));
    },
  );

  test('text-completion templates are refused for the assistant', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '雾港');
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {}),
    );
    addTearDown(runner.close);
    await expectLater(
      EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: ModelConnection(
          id: 't',
          name: 't',
          baseUrl: 'http://localhost:1',
          model: 't',
        ),
        message: '你好',
        chatPreset: PresetImporter().decode({
          'name': 'ChatML',
          'input_sequence': '<|im_start|>user',
          'output_sequence': '<|im_start|>assistant',
        }),
      ),
      throwsFormatException,
    );
  });
}
