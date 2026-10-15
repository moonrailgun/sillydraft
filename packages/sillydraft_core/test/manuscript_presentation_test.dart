import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('display regex uses frozen task context without changing document or variables', () {
    final content = ManuscriptContent.fromDelta([
      {
        'insert': '雾',
        'attributes': {'bold': true},
      },
      {'insert': '归来\n后续正文\n'},
    ]);
    final task = GenerationTask(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.completed,
      partialText: '雾归来',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'macroValues': {'char': '阿雾'},
        'variableResult': {
          'local': {'seen': 'old'},
          'global': <String, dynamic>{},
        },
        'outputRegex': [
          {
            'findRegex': '/雾/g',
            'replaceString': '{{char}}的薄雾{{setvar::seen::new}}',
            'placement': [2],
            'markdownOnly': true,
          },
          {
            'findRegex': '/正文/g',
            'replaceString': '不能出现在显示阶段',
            'placement': [2],
            'promptOnly': true,
          },
        ],
      },
    );
    final original = content.encoded;
    final shown = ManuscriptPresentation.fromTask(content, task);
    expect(shown.content.text, '阿雾的薄雾归来\n后续正文\n');
    expect(shown.content.delta.first['attributes'], {'bold': true});
    expect(
      shown.sourceOffset(shown.content.text.indexOf('后续')),
      content.text.indexOf('后续'),
    );
    expect(
      shown.displayOffset(content.text.indexOf('后续')),
      shown.content.text.indexOf('后续'),
    );
    expect(content.encoded, original);
    expect(
      ((task.input['variableResult'] as Map)['local'] as Map)['seen'],
      'old',
    );
    expect(
      ManuscriptPresentation.fromTask(content, task, rules: []).content,
      content,
      reason: 'an empty current rule list must not restore frozen rules',
    );
  });

  test('current branch rules refresh generated and manual revisions without rewriting snapshots', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '显示规则');
    final branch = novel.activeBranchId;
    final chapter = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('暗号'),
    );
    final rule = <String, dynamic>{
      'findRegex': '/暗号/g',
      'replaceString': '{{user}}的来信',
      'placement': [2],
      'markdownOnly': true,
      'disabled': true,
    };
    await repo.storeResource(
      id: 'preset',
      kind: ResourceKind.preset,
      name: '显示预设',
      filename: 'display.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: {
        'extensions': {
          'regex_scripts': [rule],
        },
      },
    );
    await repo.setSetting('writing/$branch', {'presetId': 'preset'});
    final task = await repo.createTask(
      branchId: branch,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      kind: TaskKind.writing,
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'macroValues': {'user': '阿雾'},
        'outputRegex': [rule],
      },
    );
    final proposal = await repo.createProposal(
      branchId: branch,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      taskId: task.id,
      content: ManuscriptContent.plainText('暗号到了。'),
    );
    final accepted = await repo.acceptProposal(proposal.id);
    final manual = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('暗号'),
    );
    final fork = await repo.forkBranch(branchId: branch, name: '支线');
    await repo.setSetting('writing/${fork.id}', {
      'presetId': 'preset',
      'presetOverrides': {
        'preset': {
          'extensions': {
            'regex_scripts': [
              {...rule, 'disabled': false},
            ],
          },
        },
      },
    });
    expect(
      (await repo.presentRevision(accepted.id, branchId: fork.id)).content.text,
      '阿雾的来信到了。\n',
      reason: 'live rules use the task macro values',
    );
    expect(
      (await repo.presentRevision(accepted.id, branchId: branch)).content.text,
      accepted.content.text,
      reason: 'another branch retains its own disabled setting',
    );
    expect(
      (await repo.presentRevision(
        manual.revisionId,
        branchId: fork.id,
      )).content.text,
      '我的来信\n',
      reason:
          'manual revisions also use the viewing branch, not originBranchId',
    );
    final edited = await repo.saveChapter(
      branchId: fork.id,
      chapterId: chapter.id,
      expectedRevisionId: accepted.id,
      content: ManuscriptContent.plainText('暗号归来。'),
    );
    expect(
      (await repo.presentRevision(
        edited.revisionId,
        branchId: fork.id,
      )).content.text,
      '阿雾的来信归来。\n',
      reason: 'manual edits inherit the task macro context',
    );
    expect((await repo.presentRevision(accepted.id)).content, accepted.content);
    expect((await repo.presentProposal(proposal.id)).content, proposal.content);
    expect((await repo.getTask(task.id)).input, task.input);
    expect((await repo.getRevision(accepted.id)).content, accepted.content);
  });

  test('display reads the env macros of the task, or of the branch', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final rule = <String, dynamic>{
      'findRegex': '/暗号/g',
      'replaceString': '{{persona}}|{{personality}}|{{char}}|{{model}}',
      'placement': [2],
      'markdownOnly': true,
    };
    await repo.storeResource(
      id: 'card',
      kind: ResourceKind.character,
      name: '道渊',
      filename: 'card.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: {
        'spec': 'chara_card_v2',
        'data': {
          'name': '道渊',
          'personality': ' 冷静{{user}} ',
          'first_mes': '开场',
          'extensions': {
            'regex_scripts': [rule],
          },
        },
      },
    );
    await repo.savePersona(const Persona(id: 'yu', name: '阿雨', outfit: '道袍'));
    final novel = await repo.createNovelFromCard(
      resourceId: 'card',
      title: '道渊的故事',
      personaId: 'yu',
    );
    final branch = novel.activeBranchId;
    // Without a task: the branch's card and persona; no request, no model.
    final manual = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('暗号'),
    );
    expect(
      (await repo.presentRevision(
        manual.revisionId,
        branchId: branch,
      )).content.text,
      '服饰：道袍|冷静阿雨|道渊|\n',
    );
    // A task keeps the env its prompt was compiled with.
    final task = await repo.createTask(
      branchId: branch,
      chapterId: manual.id,
      baseRevisionId: manual.revisionId,
      kind: TaskKind.writing,
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'macroEnv': const MacroEnv(
          user: '旧名',
          char: '道渊',
          persona: '旧装',
          card: {'personality': '{{user}}当时'},
          model: 'm1',
        ).toJson(),
        'outputRegex': [rule],
      },
    );
    expect(
      ManuscriptPresentation.fromTask(
        ManuscriptContent.plainText('暗号'),
        task,
      ).content.text,
      '旧装|旧名当时|道渊|m1\n',
    );
  });

  test('display reads the chat once the reply is in its chapter', () {
    GenerationTask task(Map<String, dynamic> input) => GenerationTask(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.completed,
      partialText: '',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'sourceRevisions': [<String, dynamic>{}, <String, dynamic>{}],
        'outputRegex': [
          {
            'findRegex': '/暗号/g',
            'replaceString':
                '{{lastMessageId}}|{{allChatRange}}|{{lastMessage}}|'
                '{{lastUserMessage}}|{{lastSwipeId}}|'
                '{{firstIncludedMessageId}}|{{lastGenerationType}}',
            'placement': [2],
            'markdownOnly': true,
          },
        ],
        ...input,
      },
    );
    String shown(GenerationTask task) => ManuscriptPresentation.fromTask(
      ManuscriptContent.plainText('暗号'),
      task,
    ).content.text;
    // The request's chat was two chapters and the brief; the reply is now
    // the second chapter, the last message, and the brief is not stored.
    expect(
      shown(
        task({
          'chatMacros': {
            'lastmessageid': '2',
            'lastmessage': '写',
            'lastusermessage': '写',
            'lastcharmessage': '前文',
            'allchatrange': '0-2',
            'lastswipeid': '',
            'currentswipeid': '',
            'firstincludedmessageid': '1',
            'firstdisplayedmessageid': '0',
            'lastgenerationtype': 'normal',
          },
        }),
      ),
      '1|0-1|暗号\n||1|1|normal\n',
    );
    // Older tasks: the chapters and the brief; the prompt's messages give
    // what was in context.
    final old = task({
      'compiled': {
        'messages': [
          {'role': 'system'},
          {'role': 'assistant'},
          {'role': 'user'},
        ],
      },
    });
    expect(shown(old), '1|0-1|暗号\n||1|1|normal\n');
    final macros = old.macros();
    // Their texts were not recorded.
    expect(
      macros.render('{{lastMessageId}}|{{allChatRange}}|{{lastMessage}}'),
      '2|0-2|{{lastMessage}}',
    );
    expect(macros.diagnostics.single.code, 'chat_state_unavailable');
  });

  test('display reads the request\'s token limits and outlets', () {
    GenerationTask task(Map<String, dynamic> input) => GenerationTask(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.completed,
      partialText: '',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'connection': ModelConnection(
          id: 'c',
          name: 'n',
          baseUrl: 'http://localhost:1/v1',
          model: 'm',
          contextWindow: 8000,
          maxOutputTokens: 1000,
        ).raw,
        'outputRegex': [
          {
            'findRegex': '/暗号/g',
            'replaceString':
                '{{maxPrompt}}|{{maxContext}}|{{maxResponse}}|{{outlet::x}}',
            'placement': [2],
            'markdownOnly': true,
          },
        ],
        ...input,
      },
    );
    String shown(GenerationTask task) => ManuscriptPresentation.fromTask(
      ManuscriptContent.plainText('暗号'),
      task,
    ).content.text;
    expect(
      shown(
        task({
          'macroEnv': const MacroEnv(
            maxContext: 4000,
            maxResponse: 500,
          ).toJson(),
          'outlets': {'x': '出口'},
        }),
      ),
      '3500|4000|500|出口\n',
    );
    // Older tasks: the connection, and the response length the request
    // asked for.
    expect(
      shown(
        task({
          'macroEnv': const MacroEnv(user: '阿雨').toJson()
            ..remove('maxContext')
            ..remove('maxResponse'),
          'compiled': {
            'parameters': {'max_tokens': 300},
          },
        }),
      ),
      '7700|8000|300|\n',
    );
    expect(shown(task({})), '7000|8000|1000|\n');
  });

  test(
    'display reads the instruct and system prompt templates of the task',
    () {
      final bundle = PresetImporter().decode({
        'preset': {'temp': 1},
        'instruct': {'input_sequence': '<in>', 'output_sequence': '<out>'},
        'context': {'chat_start': '<开始>'},
        'sysprompt': {'content': '写作'},
      });
      GenerationTask task(Map<String, dynamic> input) => GenerationTask(
        id: 'task',
        branchId: 'branch',
        kind: TaskKind.writing,
        status: TaskStatus.completed,
        partialText: '',
        reasoning: '',
        error: '',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        input: {
          'clock': '2026-01-01T00:00:00Z',
          'seed': 1,
          'outputRegex': [
            {
              'findRegex': '/暗号/g',
              'replaceString':
                  '{{systemPrompt}}|{{instructInput}}|{{chatStart}}',
              'placement': [2],
              'markdownOnly': true,
            },
          ],
          ...input,
        },
      );
      String shown(GenerationTask task) => ManuscriptPresentation.fromTask(
        ManuscriptContent.plainText('暗号'),
        task,
      ).content.text;
      final env = MacroEnv.of(user: '阿雨', preset: bundle).toJson();
      expect(shown(task({'macroEnv': env})), '写作|<in>|<开始>\n');
      // Tasks from before the system prompt was kept: their preset's.
      expect(
        shown(
          task({
            'macroEnv': {...env}..remove('sysprompt'),
            'preset': bundle.exportJson(),
          }),
        ),
        '写作|<in>|<开始>\n',
      );
    },
  );

  test('display reads the reasoning template and image prefixes of the '
      'task', () {
    final bundle = PresetImporter().decode({
      'preset': {'temp': 1},
      'reasoning': {'prefix': '<思>', 'suffix': '</思>', 'separator': '|'},
    });
    GenerationTask task(Map<String, dynamic> input) => GenerationTask(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.completed,
      partialText: '',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'outputRegex': [
          {
            'findRegex': '/暗号/g',
            'replaceString':
                '{{reasoningPrefix}}{{reasoningSeparator}}{{reasoningSuffix}}'
                '{{charPrefix}}',
            'placement': [2],
            'markdownOnly': true,
          },
        ],
        ...input,
      },
    );
    String shown(GenerationTask task) => ManuscriptPresentation.fromTask(
      ManuscriptContent.plainText('暗号'),
      task,
    ).content.text;
    final env = MacroEnv.of(
      card: {
        'name': '道渊',
        'extensions': {
          'sd_character_prompt': {'positive': 'masterpiece'},
        },
      },
      user: '阿雨',
      preset: bundle,
    ).toJson();
    expect(shown(task({'macroEnv': env})), '<思>|</思>masterpiece\n');
    // Tasks from before the reasoning macros: their preset's template, and
    // a fresh install's without one; the card's prefixes were not kept.
    final old = {...env}..remove('reasoning');
    (old['card'] as Map).remove('charPrefix');
    expect(
      shown(task({'macroEnv': old, 'preset': bundle.exportJson()})),
      '<思>|</思>\n',
    );
    expect(shown(task({'macroEnv': old})), '<think>\n</think>\n');
    final legacy = {
      'macroValues': {'user': '阿雨', 'char': '道渊'},
    };
    expect(
      shown(task({...legacy, 'preset': bundle.exportJson()})),
      '<思>|</思>\n',
    );
    expect(shown(task(legacy)), '<think>\n</think>\n');
  });
}
