import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  for (final limited in [false, true]) {
    test(
      'image context keeps scoped visual facts and budget diagnostics (limited: $limited)',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '雨夜');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('林岚在渡口撑起红伞。'),
        );
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
          throughChapterId: chapter.id,
        );
        await repo.appendAgentMessage(
          conversation,
          role: 'user',
          content: '旧的续写指令',
        );
        final character = await repo.saveLoreEntry(
          branchId: novel.activeBranchId,
          kind: LoreKind.character,
          name: '林岚',
          content: '过去经历不必完整复制',
          data: {'appearance': '银色短发', 'outfit': '蓝色雨衣', 'state': '左手包扎'},
        );
        final future = await repo.createChapter(branchId: novel.activeBranchId);
        await repo.saveLoreEntry(
          branchId: novel.activeBranchId,
          id: character.id,
          expectedRevisionId: character.revisionId,
          atChapterId: future.id,
          kind: LoreKind.character,
          name: '林岚',
          content: '未来造型',
          data: {'appearance': '紫色长发'},
        );
        if (limited) {
          await repo.setSetting(
            WorldInfoBudget.settingKey,
            const WorldInfoBudget(cap: 1).toJson(),
          );
        }
        final card = CardImporter().decode(
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'name': '林岚',
                'description': '{{char}}有绿眼睛',
                'system_prompt': '角色卡续写命令',
                'post_history_instructions': '角色卡后置命令',
                'first_mes': '开场白不应混入',
              }),
            ),
          ),
          'card.json',
        );
        ScopedWorldBook book(
          String content, {
          int position = 0,
          String? branch,
        }) => ScopedWorldBook(
          WorldBook.fromJson({
            'entries': [
              {
                'key': ['渡口'],
                'content': content,
              },
            ],
          }),
          branchId: branch,
          availableFromPosition: position,
        );
        final connection = ModelConnection(
          id: 'text',
          name: 'text',
          baseUrl: 'http://localhost:1',
          model: 'text',
        );
        final painter = ModelConnection(
          id: 'nai',
          name: 'NovelAI',
          baseUrl: 'http://localhost:1',
          model: 'nai-diffusion-4-5-full',
          protocol: ModelProtocol.novelAI,
        );
        ProviderRequest? seen;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            seen ??= request;
            yield const TextDelta('没有提交图片');
            yield const GenerationFinished('stop');
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          message: '画林岚在渡口撑伞',
          attachChapterId: chapter.id,
          illustrationOnly: true,
          illustrationBatch: limited,
          imageConnection: painter,
          card: card,
          userName: '舟',
          persona: '舟戴圆框眼镜',
          worldBooks: [
            book('{{char}}身后的渡口有青石阶'),
            book('未来的机械城', position: 1),
            book('另一分支的沙漠', branch: 'other'),
          ],
        );
        final done = await runner.wait(task.id);
        final messages = seen!.messages;
        final material = jsonEncode(
          messages.where((m) => m['role'] == 'user').toList(),
        );
        for (final fact in [
          '林岚有绿眼睛',
          '舟戴圆框眼镜',
          if (!limited) '林岚身后的渡口有青石阶',
          '银色短发',
          '蓝色雨衣',
          '左手包扎',
        ]) {
          expect(material, contains(fact));
        }
        for (final excluded in [
          '旧的续写指令',
          '角色卡续写命令',
          '角色卡后置命令',
          '开场白不应混入',
          '未来的机械城',
          '另一分支的沙漠',
          '紫色长发',
          if (limited) '青石阶',
        ]) {
          expect(jsonEncode(messages), isNot(contains(excluded)));
        }
        expect(messages.first['content'], contains('单一瞬间'));
        expect(messages.first['content'], contains('画面可见'));
        expect(messages.first['content'], contains('Danbooru'));
        final imageTool = seen!.tools.firstWhere(
          (t) =>
              t['function']['name'] ==
              (limited ? 'generate_images' : 'generate_image'),
        );
        expect(imageTool['function']['description'], contains('read_lore'));
        expect(
          imageTool['function']['parameters']['properties'],
          isNot(contains('references')),
        );
        final diagnostics =
            done.input['illustrationContext']['diagnostics'] as List;
        if (limited) {
          expect(
            diagnostics.any((d) => d['code'] == 'world_book_budget'),
            isTrue,
          );
          expect(material, contains('世界书预算'));
        } else {
          expect(diagnostics, isEmpty);
        }
      },
    );
  }
}
