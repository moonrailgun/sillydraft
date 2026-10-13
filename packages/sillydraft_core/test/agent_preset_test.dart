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
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: ModelConnection(
          id: 't',
          name: 't',
          baseUrl: 'http://localhost:1',
          model: 't',
        ),
        message: '这一分组奏如何？',
        card: const CardImporter().decode(
          Uint8List.fromList(utf8.encode('{"name":"沈砚","description":"看守人"}')),
          'card.json',
        ),
        chatPreset: _chatPreset(),
      );
      await runner.wait(task.id);
      final messages = seen!.messages;
      final contents = messages.map((m) => m['content'] as String).toList();

      expect(messages.first['role'], 'system');
      expect(contents.first, startsWith(editorInstructions));
      expect(contents[1], '你是沈砚的文风顾问，回答要简短。', reason: 'macros rendered');
      expect(contents.sublist(2, 5), ['先前的问题', '先前的回答', '这一分组奏如何？']);
      expect(contents[5], '记住：只用中文。', reason: 'post-history after chat');
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
