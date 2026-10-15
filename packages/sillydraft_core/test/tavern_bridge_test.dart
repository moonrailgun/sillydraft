import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

const _opening =
    '```html\n<html><body><button onclick="go()">开启仙途</button></body></html>\n```';
const _creationPage =
    '```html\n<html><body><form>重塑仙缘</form></body></html>\n```';

final class _Actions implements TavernHostActions {
  final toasts = <(String, String)>[];
  final requests = <TavernWritingRequest>[];
  final events = <(String, List<Object?>)>[];
  final logs = <String>[];
  @override
  void toast(String severity, String message, {String title = ''}) =>
      toasts.add((severity, message));
  @override
  Future<void> requestWriting(TavernWritingRequest request) async =>
      requests.add(request);
  @override
  void broadcast(String event, List<Object?> args, {Object? source}) =>
      events.add((event, args));
  @override
  void log(String level, String message) => logs.add('$level: $message');
}

Future<({StoryRepository repo, Novel novel})> _cardNovel() async {
  final repo = StoryRepository.memory();
  await repo.storeResource(
    id: 'card',
    kind: ResourceKind.character,
    name: '道渊',
    filename: 'card.json',
    sourceHash: 'fixture',
    encryptedSource: [],
    data: {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '道渊',
        'description': '修仙世界',
        'scenario': '玄天界',
        'first_mes': _opening,
        'alternate_greetings': ['[重塑仙缘]'],
        'extensions': {
          'regex_scripts': [
            {
              'id': 'r1',
              'scriptName': '开局创造人物',
              'findRegex': r'\[重塑仙缘\]',
              'replaceString': _creationPage,
              'placement': [2],
              'markdownOnly': true,
              'disabled': false,
            },
          ],
          'tavern_helper': {
            'scripts': [
              {'name': 'MVU', 'enabled': true, 'content': 'import x'},
            ],
          },
        },
      },
    },
  );
  await repo.savePersona(const Persona(id: 'jiushen', name: '玖神'));
  final novel = await repo.createNovelFromCard(
    resourceId: 'card',
    title: '道渊的故事',
    personaId: 'jiushen',
  );
  return (repo: repo, novel: novel);
}

void main() {
  group('display context', () {
    test(
      'reuses cached rules until the writing profile changes or is removed',
      () async {
        final (:repo, :novel) = await _cardNovel();
        addTearDown(repo.close);
        final branch = novel.activeBranchId;
        final original = await repo.displayContext(branch);
        await repo.setSetting('progress/$branch', {'fraction': .5});
        expect(identical(await repo.displayContext(branch), original), isTrue);

        final profile = (await repo.getSetting('writing/$branch'))!;
        final xin = await repo.savePersona(const Persona(id: '', name: '新主角'));
        await repo.setSetting('writing/$branch', {
          ...profile,
          'personaId': xin.id,
        });
        final updated = await repo.displayContext(branch);
        expect(updated.env.user, '新主角');
        expect(updated.cardId, 'card');
        expect(original.env.user, '玖神');

        // Editing the bound persona leaves the profile as it was.
        await repo.savePersona(xin.copyWith(name: '改名', outfit: '道袍'));
        final renamed = await repo.displayContext(branch);
        expect(renamed.env.user, '改名');
        expect(renamed.env.persona, '服饰：道袍');

        await repo.removeSetting('writing/$branch');
        final cleared = await repo.displayContext(branch);
        expect(cleared.rules, isEmpty);
        expect(cleared.cardId, isNull);
        expect(cleared.env.user, '我');
      },
    );

    test(
      'collects card rules, macro values, greetings and helper scripts',
      () async {
        final (:repo, :novel) = await _cardNovel();
        addTearDown(repo.close);
        final context = await repo.displayContext(novel.activeBranchId);
        expect(context.cardId, 'card');
        expect(context.rules.single['scriptName'], '开局创造人物');
        expect(context.env.char, '道渊');
        expect(context.env.user, '玖神');
        expect(context.greetings, [_opening, '[重塑仙缘]']);
        expect(context.helperScripts.single.name, 'MVU');
        expect(context.card['name'], '道渊');
        expect(
          (context.card['extensions'] as Map).containsKey('tavern_helper'),
          isFalse,
        );
        expect(
          identical(context, await repo.displayContext(novel.activeBranchId)),
          isTrue,
        );
      },
    );

    test(
      'presents an opening chapter with the card display regex and no task',
      () async {
        final (:repo, :novel) = await _cardNovel();
        addTearDown(repo.close);
        final story = await repo.getStory(novel.activeBranchId);
        final chapter = story.chapters.single;
        expect(
          (await repo.presentRevision(chapter.revisionId)).content.text.trim(),
          _opening,
        );
        await repo.saveChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          expectedRevisionId: chapter.revisionId,
          content: ManuscriptContent.plainText('[重塑仙缘]'),
        );
        final updated = (await repo.getStory(novel.activeBranchId))
            .chapters
            .single;
        final shown = await repo.presentRevision(updated.revisionId);
        expect(shown.content.text.trim(), _creationPage);
        expect(updated.content.text.trim(), '[重塑仙缘]');
        expect(
          HtmlBlocks.find(shown.content.text).single.kind,
          HtmlBlockKind.frontend,
        );
      },
    );
  });

  group('BranchChatBackend', () {
    test(
      'snapshot exposes chapters as messages with greetings as swipes',
      () async {
        final (:repo, :novel) = await _cardNovel();
        addTearDown(repo.close);
        final context = await repo.displayContext(novel.activeBranchId);
        final backend = BranchChatBackend(
          repository: repo,
          branchId: novel.activeBranchId,
          context: context,
        );
        final bridge = TavernBridge(
          backend: backend,
          actions: _Actions(),
          messageId: 0,
        );
        final state = await bridge.state();
        expect(state['iframe_name'], 'TH-message--0--0');
        expect(state['name1'], '玖神');
        expect(state['name2'], '道渊');
        final messages = state['messages'] as List;
        expect(messages, hasLength(1));
        final first = messages.single as Map;
        expect(first['role'], 'assistant');
        expect(first['swipe_id'], 0);
        expect(first['swipes'], [_opening, '[重塑仙缘]']);
        expect((state['card'] as Map)['name'], '道渊');
      },
    );

    test(
      'switching to the second greeting rewrites the opening chapter',
      () async {
        final (:repo, :novel) = await _cardNovel();
        addTearDown(repo.close);
        final backend = BranchChatBackend(
          repository: repo,
          branchId: novel.activeBranchId,
          context: await repo.displayContext(novel.activeBranchId),
        );
        final bridge = TavernBridge(
          backend: backend,
          actions: _Actions(),
          messageId: 0,
        );
        final result = await bridge.handleMessage(
          jsonEncode({
            'id': 7,
            'method': 'setChatMessages',
            'args': [
              [
                {'message_id': 0, 'swipe_id': 1},
              ],
              {'refresh': 'affected'},
            ],
          }),
        );
        expect(result.ok, isTrue, reason: '${result.payload}');
        expect(result.id, 7);
        final story = await repo.getStory(novel.activeBranchId);
        expect(story.chapters.single.content.text.trim(), '[重塑仙缘]');
        expect(
          (await repo.getSetting(
            'writing/${novel.activeBranchId}',
          ))?['greetingIndex'],
          1,
        );
        final context = await repo.displayContext(novel.activeBranchId);
        expect(context.greetingIndex, 1);
        final state = await TavernBridge(
          backend: BranchChatBackend(
            repository: repo,
            branchId: novel.activeBranchId,
            context: context,
          ),
          actions: _Actions(),
          messageId: 0,
        ).state();
        expect(((state['messages'] as List).single as Map)['swipe_id'], 1);
      },
    );

    test('variables round-trip through versioned branch variables', () async {
      final (:repo, :novel) = await _cardNovel();
      addTearDown(repo.close);
      final backend = BranchChatBackend(
        repository: repo,
        branchId: novel.activeBranchId,
        context: await repo.displayContext(novel.activeBranchId),
      );
      await backend.replaceVariables(
        {
          'stat_data': {
            '主角': {'境界': '凡人', '生命': 100},
          },
          'mood': '平静',
        },
        {'type': 'message', 'message_id': 0},
        messageId: 0,
      );
      final stored = await repo.getBranchVariables(novel.activeBranchId);
      expect(stored.local['mood'], '平静');
      expect(jsonDecode(stored.local['stat_data']!), {
        '主角': {'境界': '凡人', '生命': 100},
      });
      final read = await backend.variables({'type': 'chat'}, messageId: 0);
      expect(read['stat_data'], {
        '主角': {'境界': '凡人', '生命': 100},
      });
      await backend.replaceVariables(
        {'theme': 'dark'},
        {'type': 'global'},
        messageId: 0,
      );
      expect((await repo.getBranchVariables(novel.activeBranchId)).global, {
        'theme': 'dark',
      });
      expect(
        (await repo.getBranchVariables(novel.activeBranchId)).local['mood'],
        '平静',
      );
      await backend.replaceVariables(
        {'x': 1},
        {'type': 'script', 'script_id': 's1'},
        messageId: 0,
      );
      expect(
        await backend.variables({
          'type': 'script',
          'script_id': 's1',
        }, messageId: 0),
        {'x': 1},
      );
      final snapshot = await backend.snapshot(0);
      expect(((snapshot['variables'] as Map)['chat'] as Map)['mood'], '平静');
      expect(((snapshot['variables'] as Map)['other'] as Map)['script:s1'], {
        'x': 1,
      });
    });

    test(
      'chat variables written from an earlier chapter are read at the head',
      () async {
        final (:repo, :novel) = await _cardNovel();
        addTearDown(repo.close);
        final branch = novel.activeBranchId;
        await repo.createChapter(
          branchId: branch,
          title: '第二幕',
          content: ManuscriptContent.plainText('后来。'),
        );
        final backend = BranchChatBackend(
          repository: repo,
          branchId: branch,
          context: await repo.displayContext(branch),
        );
        // The opening page records its own message variables at chapter 0.
        await backend.replaceVariables(
          {
            'stat_data': {'hp': 1},
          },
          {'type': 'message', 'message_id': 0},
          messageId: 0,
        );
        final bridge = TavernBridge(
          backend: backend,
          actions: _Actions(),
          messageId: 0,
        );
        expect(await bridge.runSlash('/setvar key=hp 10 | /getvar hp'), '10');
        final chapters = (await repo.getStory(branch)).chapters;
        expect((await repo.getBranchVariables(branch)).local['hp'], '10');
        final atOpening = await repo.getBranchVariables(
          branch,
          throughChapterId: chapters[0].id,
        );
        expect(atOpening.local['stat_data'], '{"hp":1}');
        expect(atOpening.local.containsKey('hp'), isFalse);
        expect(
          (await backend.variables({
            'type': 'message',
            'message_id': 0,
          }, messageId: 0))['stat_data'],
          {'hp': 1},
        );
        final snapshot = await backend.snapshot(0);
        expect(
          ((snapshot['variables'] as Map)['messages'] as Map).keys,
          containsAll(['0', '1']),
        );
      },
    );

    test('createChatMessages appends chapters; deleting is refused', () async {
      final (:repo, :novel) = await _cardNovel();
      addTearDown(repo.close);
      final bridge = TavernBridge(
        backend: BranchChatBackend(
          repository: repo,
          branchId: novel.activeBranchId,
          context: await repo.displayContext(novel.activeBranchId),
        ),
        actions: _Actions(),
        messageId: 0,
      );
      await bridge.handle('createChatMessages', [
        [
          {'role': 'user', 'message': '我走进山门。'},
        ],
        {},
      ]);
      final story = await repo.getStory(novel.activeBranchId);
      expect(story.chapters, hasLength(2));
      expect(story.chapters.last.content.text.trim(), '我走进山门。');
      final refused = await bridge.handleMessage(
        jsonEncode({
          'id': 1,
          'method': 'deleteChatMessages',
          'args': [
            [1],
            <String, dynamic>{},
          ],
        }),
      );
      expect(refused.ok, isFalse);
      expect(refused.payload, contains('/cut'));
      expect(
        (await repo.getStory(novel.activeBranchId)).chapters,
        hasLength(2),
      );
    });
  });

  group('slash pipeline', () {
    late StoryRepository repo;
    late TavernBridge bridge;
    late _Actions actions;
    setUp(() async {
      final created = await _cardNovel();
      repo = created.repo;
      actions = _Actions();
      bridge = TavernBridge(
        backend: BranchChatBackend(
          repository: repo,
          branchId: created.novel.activeBranchId,
          context: await repo.displayContext(created.novel.activeBranchId),
        ),
        actions: actions,
        messageId: 0,
      );
    });
    tearDown(() => repo.close());

    test('/send opens a writing request with the text as brief', () async {
      await bridge.runSlash('/send 开启仙途');
      expect(actions.requests.single.brief, '开启仙途');
      expect(actions.requests.single.triggered, isFalse);
      expect(actions.requests.single.rewriteMessageId, isNull);
    });

    test(
      'composer text requests continuation without parsing slash commands',
      () async {
        const text = '她说：a | b\n/cut 0 只是故事里的文字';
        await bridge.handle('continueWriting', [text]);
        expect(actions.requests.single.brief, text);
        expect(actions.requests.single.continueNextChapter, isTrue);
        expect(actions.requests.single.rewriteMessageId, isNull);
      },
    );

    test('composer ignores blank text and rejects non-text input', () async {
      await bridge.handle('continueWriting', [' \n ']);
      expect(actions.requests, isEmpty);
      await expectLater(
        bridge.handle('continueWriting', [42]),
        throwsArgumentError,
      );
    });

    test('/setinput continues, but /cut still requests a rewrite', () async {
      await bridge.runSlash('/setinput 她走进山门 | /trigger');
      expect(actions.requests.single.brief, '她走进山门');
      expect(actions.requests.single.continueNextChapter, isTrue);
      actions.requests.clear();
      await bridge.runSlash('/setinput 改写开场 | /cut 0 | /trigger');
      expect(actions.requests.single.continueNextChapter, isFalse);
      expect(actions.requests.single.rewriteMessageId, 0);
    });

    test('/sys | /cut | /trigger asks to rewrite the cut chapter', () async {
      await bridge.runSlash(
        '/sys [仙缘已定 - 普通模式]\n**道号**: 玖神 | /cut 0 | /trigger',
      );
      final request = actions.requests.single;
      expect(request.brief, '[仙缘已定 - 普通模式]\n**道号**: 玖神');
      expect(request.rewriteMessageId, 0);
      expect(request.triggered, isTrue);
      expect(actions.toasts, isEmpty);
    });

    test('variables, echo, pass and pipes', () async {
      expect(await bridge.runSlash('/setvar key=mood 开心 | /getvar mood'), '开心');
      expect(await bridge.runSlash('/getvar key=mood'), '开心');
      expect(await bridge.runSlash('/addvar key=n 2 | /addvar key=n 2'), '4');
      expect(await bridge.runSlash('/incvar n'), '5');
      expect(
        await bridge.runSlash('/setglobalvar key=g "a | b" | /getglobalvar g'),
        'a | b',
      );
      expect(
        await bridge.runSlash('/pass 原样 | /echo severity=success {{pipe}}!'),
        '原样!',
      );
      expect(actions.toasts.single, ('success', '原样!'));
      await bridge.runSlash('/flushvar mood');
      expect(await bridge.runSlash('/getvar mood'), '');
      expect(await bridge.runSlash(r'/pass a \| b'), 'a | b');
      expect(actions.requests, isEmpty);
    });

    test('unsupported or malformed commands throw', () async {
      expect(() => bridge.runSlash('/foo'), throwsFormatException);
      expect(() => bridge.runSlash('/gen 写点什么'), throwsFormatException);
      expect(() => bridge.runSlash('不是命令'), throwsFormatException);
      expect(() => bridge.runSlash('/cut'), throwsFormatException);
      final result = await bridge.handleMessage(
        jsonEncode({
          'id': 3,
          'method': 'triggerSlash',
          'args': ['/foo'],
        }),
      );
      expect(result.ok, isFalse);
      expect(result.payload, contains('/foo'));
    });

    test('bridge rejects malformed, oversized or unknown messages', () async {
      expect((await bridge.handleMessage('nope')).ok, isFalse);
      expect((await bridge.handleMessage('{"id":"x"}')).ok, isFalse);
      expect(
        (await bridge.handleMessage(
          jsonEncode({'id': 1, 'method': 'steal', 'args': <Object?>[]}),
        )).payload,
        contains('steal'),
      );
      final big = TavernBridge(
        backend: bridge.backend,
        actions: actions,
        messageId: 0,
        maxMessageBytes: 10,
      );
      expect(
        (await big.handleMessage('{"id":1,"method":"toast","args":[]}'))
            .payload,
        contains('过大'),
      );
      await bridge.handle('toast', ['warning', '注意', '标题']);
      expect(actions.toasts.last, ('warning', '注意'));
      await bridge.handle('eventEmit', [
        'mag_variable_update_ended',
        [1, 'a'],
      ]);
      expect(actions.events.single.$1, 'mag_variable_update_ended');
      expect(actions.events.single.$2, [1, 'a']);
      await bridge.handle('log', ['error', 'boom']);
      expect(actions.logs.single, 'error: boom');
    });
  });

  group('PreviewChatBackend', () {
    test('switches greetings and keeps variables in memory', () async {
      final changes = <int>[];
      final backend = PreviewChatBackend(
        greetings: ['开场一', '开场二'],
        greetingIndex: 0,
        context: const DisplayContext(
          env: MacroEnv(user: '玖神', char: '道渊'),
        ),
        onGreetingChanged: changes.add,
      );
      final bridge = TavernBridge(
        backend: backend,
        actions: _Actions(),
        messageId: 0,
      );
      final state = await bridge.state();
      expect(((state['messages'] as List).single as Map)['swipes'], [
        '开场一',
        '开场二',
      ]);
      expect(state['preview'], isTrue);
      await bridge.handle('setChatMessages', [
        [
          {'message_id': 0, 'swipe_id': 1, 'message': '开场二'},
        ],
        {},
      ]);
      expect(changes, [1]);
      expect(backend.greetingIndex, 1);
      expect(await bridge.runSlash('/setvar key=k v | /getvar k'), 'v');
      expect(backend.chatVariables, {'k': 'v'});
      expect(
        () => bridge.handle('createChatMessages', [[], {}]),
        throwsFormatException,
      );
    });
  });

  test('variable codec keeps strings and restores JSON values', () {
    final encoded = encodeVariables({
      's': 'text',
      'n': 5,
      'b': true,
      'o': {
        'a': [1],
      },
    });
    expect(encoded, {'s': 'text', 'n': '5', 'b': 'true', 'o': '{"a":[1]}'});
    expect(decodeVariables(encoded), {
      's': 'text',
      'n': 5,
      'b': true,
      'o': {
        'a': [1],
      },
    });
    expect(decodeVariables({'x': '{broken', 'y': '"quoted"', 'z': ''}), {
      'x': '{broken',
      'y': '"quoted"',
      'z': '',
    });
  });
}
