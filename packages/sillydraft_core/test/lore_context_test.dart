import 'dart:async';
import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repo;
  late TaskRunner runner;
  late WritingService service;
  late String branch;
  final connection = ModelConnection(
    id: 'test',
    name: 'Test',
    baseUrl: 'http://localhost:1/v1',
    model: 'test',
    contextWindow: 2000,
    maxOutputTokens: 200,
  );

  setUp(() async {
    repo = StoryRepository.memory();
    runner = TaskRunner(
      repository: repo,
      providerFactory: (_) async => throw StateError('No model calls'),
    );
    service = WritingService(repository: repo, runner: runner);
    branch = (await repo.createNovel(title: '渡口')).activeBranchId;
  });
  tearDown(() async {
    await runner.close();
    await repo.close();
  });

  Future<LoreEntry> lore(
    String name,
    String text, {
    bool required = false,
    LoreKind kind = LoreKind.world,
    Map<String, dynamic> data = const {},
  }) => repo.saveLoreEntry(
    branchId: branch,
    kind: kind,
    name: name,
    content: text,
    data: {...data, 'contextRequired': required},
  );

  List<String> ids(PreparedWriting draft) => [
    for (final e in draft.input['loreRevisions'] as List) e['id'] as String,
  ];

  test(
    'selects relevant lore and keeps author constraints with frozen reasons',
    () async {
      final pinned = await lore('禁忌', '亡者不能复生', required: true);
      final person = await lore('林岚', '左手受伤');
      final ferry = await lore('旧时刻表', '渡口只在夜间开放');
      final sea = await lore('珊瑚', '海底珊瑚呈紫色');
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '林岚返回渡口',
      );
      expect(ids(draft), containsAll([pinned.id, person.id, ferry.id]));
      expect(ids(draft), isNot(contains(sea.id)));
      final selection = draft.input['loreSelection'] as Map;
      expect(
        (selection['selected'] as List)
            .where((e) => e['required'] == true)
            .map((e) => e['id']),
        containsAll([pinned.id, person.id]),
      );
      expect((selection['omitted'] as List).single['id'], sea.id);
      final task = await repo.createTask(
        branchId: branch,
        chapterId: chapter.id,
        kind: TaskKind.writing,
        input: draft.input,
      );
      await repo.saveLoreEntry(
        branchId: branch,
        id: person.id,
        expectedRevisionId: person.revisionId,
        kind: person.kind,
        name: person.name,
        content: '已痊愈',
      );
      expect(jsonEncode(task.input['request']), contains('左手受伤'));
      expect(task.input['loreSelection'], draft.input['loreSelection']);
    },
  );

  test(
    'unresolved hooks survive unrelated chapter goals but remain budgeted',
    () async {
      final hook = await lore(
        '红绳',
        '柜底的结尚未解开',
        kind: LoreKind.foreshadow,
        data: {'status': 'planted'},
      );
      final resolved = await lore(
        '旧信',
        '真相已揭晓',
        kind: LoreKind.foreshadow,
        data: {'status': 'resolved'},
      );
      await lore('渡口', '渡口雨夜');
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写渡口',
      );
      expect(ids(draft), contains(hook.id));
      expect(ids(draft), isNot(contains(resolved.id)));
      final selected =
          (draft.input['loreSelection'] as Map)['selected'] as List;
      expect(
        selected.singleWhere((e) => e['id'] == hook.id)['required'],
        isFalse,
      );
      await repo.saveLoreEntry(
        branchId: branch,
        id: hook.id,
        expectedRevisionId: hook.revisionId,
        kind: hook.kind,
        name: hook.name,
        content: '绳结' * 5000,
        data: hook.data,
      );
      final limited = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写渡口',
      );
      expect(limited.canRun, isTrue);
      final omitted =
          (limited.input['loreSelection'] as Map)['omitted'] as List;
      expect(
        omitted.singleWhere((e) => e['id'] == hook.id)['reason'],
        'budget',
      );
    },
  );

  test(
    'book foundation stays recallable but optional within context budget',
    () async {
      final foundation = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.world,
        name: '全书布局',
        content: '首场埋下旧谱差异，核对后再决定如何承认沉默。',
        certainty: LoreCertainty.plan,
        data: {'writingFoundation': 1},
      );
      await lore('渡口', '渡口雨夜');
      final chapter = await repo.createChapter(branchId: branch);
      Future<PreparedWriting> preview() => service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写渡口',
      );
      final draft = await preview();
      expect(ids(draft), contains(foundation.id));
      final selected =
          (draft.input['loreSelection'] as Map)['selected'] as List;
      final entry = selected.singleWhere((e) => e['id'] == foundation.id);
      expect(entry['reason'], 'foundation');
      expect(entry['required'], isFalse);
      await repo.saveLoreEntry(
        branchId: branch,
        id: foundation.id,
        expectedRevisionId: foundation.revisionId,
        kind: foundation.kind,
        name: foundation.name,
        content: '未发生的计划' * 5000,
        certainty: foundation.certainty,
        data: foundation.data,
      );
      final limited = await preview();
      expect(limited.canRun, isTrue);
      final omitted =
          (limited.input['loreSelection'] as Map)['omitted'] as List;
      expect(
        omitted.singleWhere((e) => e['id'] == foundation.id)['reason'],
        'budget',
      );
    },
  );

  test(
    'drops optional lore to fit the compiled preset output budget',
    () async {
      final pinned = await lore('禁忌', '亡者不能复生', required: true);
      final large = await lore('档案', '渡口${'旧闻' * 2500}');
      final chapter = await repo.createChapter(branchId: branch);
      final preset = PresetImporter().decode({
        ...defaultWritingPreset().raw,
        'openai_max_tokens': 1200,
      });
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写渡口',
        preset: preset,
      );
      expect(ids(draft), [pinned.id]);
      expect(draft.canRun, isTrue);
      expect(
        (draft.compiled['estimatedTokens'] as num) + 1200,
        lessThanOrEqualTo(2000),
      );
      final omitted = (draft.input['loreSelection'] as Map)['omitted'] as List;
      expect(omitted.single['id'], large.id);
      expect(omitted.single['reason'], 'budget');
      expect(jsonEncode(draft.input['request']), contains('亡者不能复生'));
      expect(jsonEncode(draft.input['request']), contains('写渡口'));
    },
  );

  test(
    'budget pruning lets queued events run before preparation completes',
    () async {
      final pinned = await lore('禁忌', '亡者不能复生', required: true);
      for (var i = 0; i < 12; i++) {
        await lore('档案 $i', '渡口${'旧闻' * 2500}');
      }
      final chapter = await repo.createChapter(branchId: branch);
      var ticks = 0;
      final timer = Timer.periodic(Duration.zero, (_) => ticks++);
      late final PreparedWriting draft;
      try {
        draft = await service.prepare(
          branchId: branch,
          chapterId: chapter.id,
          connection: connection,
          brief: '写渡口',
        );
      } finally {
        timer.cancel();
      }
      expect(ticks, greaterThan(1));
      expect(ids(draft), [pinned.id]);
      expect(draft.canRun, isTrue);
      final omitted = (draft.input['loreSelection'] as Map)['omitted'] as List;
      expect(omitted, hasLength(12));
      expect(omitted.every((entry) => entry['reason'] == 'budget'), isTrue);
      expect(
        (draft.compiled['estimatedTokens'] as num) + connection.maxOutputTokens,
        lessThanOrEqualTo(connection.contextWindow),
      );
    },
  );

  test('a named relationship keeps both endpoint records', () async {
    final a = await lore('林岚', '左手受伤', kind: LoreKind.character);
    final b = await lore('陈舟', '已失明', kind: LoreKind.character);
    final relation = await lore(
      '旧盟约',
      '彼此隐瞒真实身份',
      kind: LoreKind.relationship,
      data: {'fromId': a.id, 'toId': b.id},
    );
    final chapter = await repo.createChapter(branchId: branch);
    final draft = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '写旧盟约破裂',
    );
    expect(ids(draft), unorderedEquals([a.id, b.id, relation.id]));
    final prompt = jsonEncode(draft.input['request']);
    expect(prompt, contains('左手受伤'));
    expect(prompt, contains('已失明'));
    expect(draft.canRun, isTrue);
  });

  for (final brief in ['写林岚与陈舟会面', '继续']) {
    test('endpoint names recall relationships for: $brief', () async {
      final a = await lore('林岚', '左手受伤', kind: LoreKind.character);
      final b = await lore('陈舟', '已失明', kind: LoreKind.character);
      final relation = await lore(
        '旧盟约',
        '彼此隐瞒真实身份',
        kind: LoreKind.relationship,
        data: {'fromId': a.id, 'toId': b.id},
      );
      final chapter = await repo.createChapter(
        branchId: branch,
        content: ManuscriptContent.plainText('林岚推开门。'),
      );
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: brief,
        append: true,
      );
      expect(ids(draft), unorderedEquals([a.id, b.id, relation.id]));
      expect(jsonEncode(draft.input['request']), contains('彼此隐瞒真实身份'));
    });
  }

  test('required relationship endpoints survive budget pressure', () async {
    final a = await lore('林岚', '往事' * 3000, kind: LoreKind.character);
    final b = await lore('陈舟', '已失明', kind: LoreKind.character);
    final relation = await lore(
      '旧盟约',
      '彼此隐瞒真实身份',
      required: true,
      kind: LoreKind.relationship,
      data: {'fromId': a.id, 'toId': b.id},
    );
    final chapter = await repo.createChapter(branchId: branch);
    final draft = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '开篇',
    );
    expect(ids(draft), unorderedEquals([a.id, b.id, relation.id]));
    expect(draft.canRun, isFalse);
    expect(
      (draft.compiled['diagnostics'] as List).any(
        (d) => d['code'] == 'lore_context_overflow',
      ),
      isTrue,
    );
  });

  test(
    'optional relationships cannot outlive their trimmed endpoints',
    () async {
      final pinned = await lore('禁忌', '亡者不能复生', required: true);
      final a = await lore('林岚', '往事' * 3000, kind: LoreKind.character);
      final b = await lore('陈舟', '已失明', kind: LoreKind.character);
      final relation = await lore(
        '旧盟约',
        '渡口密会时彼此隐瞒真实身份',
        kind: LoreKind.relationship,
        data: {'fromId': a.id, 'toId': b.id},
      );
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写渡口密会',
      );
      expect(ids(draft), [pinned.id]);
      final omitted = (draft.input['loreSelection'] as Map)['omitted'] as List;
      expect(
        omitted.where((e) => e['reason'] == 'budget').map((e) => e['id']),
        unorderedEquals([a.id, b.id, relation.id]),
      );
      expect(draft.canRun, isTrue);
    },
  );

  test('map dependencies use eligible location versions only', () async {
    final location = await lore('河湾', 'OLD_LOCATION', kind: LoreKind.location);
    final excluded = await lore(
      '水塔',
      'WORLD_BOOK_ONLY',
      kind: LoreKind.location,
      data: {'worldBookOnly': true},
    );
    final map = await lore(
      '古城图',
      '北侧入口',
      kind: LoreKind.map,
      data: {
        'points': [
          {'id': 'a', 'x': 0.2, 'y': 0.3, 'entityId': location.id},
          {'id': 'b', 'x': 0.4, 'y': 0.5, 'entityId': excluded.id},
        ],
      },
    );
    final chapter = await repo.createChapter(branchId: branch);
    await repo.saveLoreEntry(
      branchId: branch,
      id: location.id,
      expectedRevisionId: location.revisionId,
      kind: location.kind,
      name: location.name,
      content: 'FUTURE_LOCATION',
    );
    for (final brief in ['写古城图的发现', '写河湾']) {
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: brief,
        regenerate: true,
      );
      expect(ids(draft), unorderedEquals([location.id, map.id]));
      final prompt = jsonEncode(draft.input['request']);
      expect(prompt, contains('OLD_LOCATION'));
      expect(prompt, isNot(contains('FUTURE_LOCATION')));
      expect(prompt, isNot(contains('WORLD_BOOK_ONLY')));
    }
  });

  test(
    'a referenced ID cannot stand in for a missing required record',
    () async {
      final a = await lore(
        '林岚',
        '左手受伤',
        required: true,
        kind: LoreKind.character,
      );
      final b = await lore('陈舟', '已失明', kind: LoreKind.character);
      await lore(
        '旧盟约',
        '彼此隐瞒真实身份',
        kind: LoreKind.relationship,
        data: {'fromId': a.id, 'toId': b.id},
      );
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写旧盟约破裂',
        globalRegex: [
          {
            'findRegex': '/\\{"id":"${a.id}".*?\\}\\},?/g',
            'replaceString': '',
            'placement': [1],
            'promptOnly': true,
          },
        ],
      );
      final prompt = jsonEncode(draft.input['request']);
      expect(prompt, contains(a.id));
      expect(prompt, isNot(contains('左手受伤')));
      expect(draft.canRun, isFalse);
      expect(
        (draft.compiled['diagnostics'] as List).any(
          (d) => d['code'] == 'lore_context_missing',
        ),
        isTrue,
      );
      await expectLater(service.startPrepared(draft), throwsFormatException);
    },
  );

  test('pruning a world book trigger preserves other relevant lore', () async {
    final pinned = await lore('禁忌', '亡者不能复生', required: true);
    final a = await lore('林岚', '左手受伤', kind: LoreKind.character);
    final b = await lore('陈舟', '已失明', kind: LoreKind.character);
    final relevant = await lore('行路记录', '渡口归途的路标都已撤走');
    final relation = await lore(
      '盟约',
      '渡口归途同行',
      kind: LoreKind.relationship,
      data: {'fromId': a.id, 'toId': b.id},
    );
    final trigger = await lore(
      '旧日档案',
      '渡口 lighthouse',
      kind: LoreKind.relationship,
      data: {'fromId': a.id, 'toId': b.id},
    );
    final chapter = await repo.createChapter(branchId: branch);
    final draft = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '写渡口归途',
      worldBooks: [
        ScopedWorldBook(
          WorldBook.fromJson({
            'name': '灯塔',
            'entries': [
              {
                'key': ['lighthouse'],
                'content': 'BEACON ${'旧闻' * 3000}',
                'position': 0,
                'ignoreBudget': true,
              },
            ],
          }),
        ),
      ],
    );
    expect(
      ids(draft),
      unorderedEquals([pinned.id, relevant.id, relation.id, a.id, b.id]),
    );
    final omitted = (draft.input['loreSelection'] as Map)['omitted'] as List;
    expect(omitted.single['id'], trigger.id);
    expect(omitted.single['reason'], 'budget');
    expect(jsonEncode(draft.input['request']), isNot(contains('BEACON')));
    expect(draft.canRun, isTrue);
  });

  test(
    'required overflow is visible in preview and cannot start a task',
    () async {
      final pinned = await lore('约束', '不可更改${'禁令' * 3000}', required: true);
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '开篇',
      );
      expect(ids(draft), [pinned.id]);
      expect(draft.canRun, isFalse);
      expect(
        (draft.compiled['diagnostics'] as List).any(
          (d) =>
              d['code'] == 'lore_context_overflow' && d['severity'] == 'error',
        ),
        isTrue,
      );
      await expectLater(service.startPrepared(draft), throwsFormatException);
    },
  );

  test(
    'budget pruning recomputes world books without leaking macro writes',
    () async {
      final pinned = await lore('禁忌', '亡者不能复生', required: true);
      await lore('档案', '渡口 lighthouse ${'旧闻' * 2500}');
      final chapter = await repo.createChapter(branchId: branch);
      final books = [
        ScopedWorldBook(
          WorldBook.fromJson({
            'name': '灯塔',
            'entries': [
              {
                'key': ['lighthouse'],
                'content': '{{setvar::beacon::lit}}BEACON_LIT',
                'position': 0,
              },
            ],
          }),
        ),
      ];
      Future<PreparedWriting> prepare(ModelConnection model) => service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: model,
        brief: '写渡口 {{incvar::counter}}',
        worldBooks: books,
      );
      final roomy = await prepare(
        ModelConnection.fromJson({...connection.raw, 'contextWindow': 20000}),
      );
      expect(jsonEncode(roomy.input['request']), contains('BEACON_LIT'));
      expect((roomy.input['variableResult'] as Map)['local']['beacon'], 'lit');
      final tight = await prepare(connection);
      expect(tight.canRun, isTrue);
      expect(ids(tight), [pinned.id]);
      expect(jsonEncode(tight.input['request']), isNot(contains('BEACON_LIT')));
      final variables = (tight.input['variableResult'] as Map)['local'] as Map;
      expect(
        variables['counter'],
        (roomy.input['variableResult'] as Map)['local']['counter'],
      );
      expect(variables, isNot(contains('beacon')));
      expect((await repo.getBranchVariables(branch)).local, isEmpty);
    },
  );

  test('a directly named constraint is not removed for budget', () async {
    final named = await lore('林岚', '人物经历${'往事' * 3000}');
    final chapter = await repo.createChapter(branchId: branch);
    final draft = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '写林岚回家',
    );
    expect(ids(draft), [named.id]);
    expect(draft.canRun, isFalse);
  });

  test(
    'required flags never bypass chapter boundaries or world book activation',
    () async {
      final earlier = await lore('旧规则', 'EARLIER', required: true);
      await lore(
        '快照',
        'SNAPSHOT',
        required: true,
        data: {'worldBookOnly': true},
      );
      final chapter = await repo.createChapter(
        branchId: branch,
        content: ManuscriptContent.plainText('OLD_CHAPTER'),
      );
      await lore('当前规则', 'CURRENT', required: true);
      await repo.createChapter(branchId: branch);
      await lore('未来规则', 'FUTURE', required: true);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '重新开篇',
        regenerate: true,
      );
      expect(ids(draft), [earlier.id]);
      final prompt = jsonEncode(draft.input['request']);
      for (final excluded in ['CURRENT', 'FUTURE', 'SNAPSHOT', 'OLD_CHAPTER']) {
        expect(prompt, isNot(contains(excluded)));
      }
    },
  );

  test(
    'uses recent prose for short requests and falls back without a match',
    () async {
      final person = await lore('林岚', '左手受伤');
      final other = await lore('珊瑚', '海底呈紫色');
      final chapter = await repo.createChapter(
        branchId: branch,
        content: ManuscriptContent.plainText('林岚推开门。'),
      );
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '继续',
        append: true,
      );
      expect(ids(draft), [person.id]);
      final restart = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '开篇',
        regenerate: true,
      );
      expect(ids(restart), containsAll([person.id, other.id]));
    },
  );

  test('a preset cannot silently remove the required lore block', () async {
    await lore('禁忌', '亡者不能复生', required: true);
    final chapter = await repo.createChapter(branchId: branch);
    final draft = await service.prepare(
      branchId: branch,
      chapterId: chapter.id,
      connection: connection,
      brief: '开篇',
      preset: PresetImporter().decode({
        ...defaultWritingPreset().raw,
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
            ],
          },
        ],
      }),
    );
    expect(draft.canRun, isFalse);
    expect(
      (draft.compiled['diagnostics'] as List).any(
        (d) => d['code'] == 'lore_context_missing' && d['severity'] == 'error',
      ),
      isTrue,
    );
  });

  test(
    'text completion also trims optional lore and keeps the required text',
    () async {
      final pinned = await lore('禁忌', '亡者不能复生', required: true);
      await lore('档案', '渡口${'旧闻' * 2500}');
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: '写渡口',
        preset: PresetImporter().decode({
          'name': 'text',
          'temp': 0.7,
          'genamt': 1200,
          'max_length': 2000,
        }),
      );
      expect(ids(draft), [pinned.id]);
      expect(draft.canRun, isTrue);
      expect(draft.compiled['completionText'], contains('亡者不能复生'));
      expect(
        (draft.compiled['estimatedTokens'] as num) + 1200,
        lessThanOrEqualTo(2000),
      );
    },
  );

  test(
    'English name matching does not protect a substring of another name',
    () async {
      final ann = await lore('Ann', 'SCULPTOR');
      final anna = await lore('Anna', 'SAILOR');
      final chapter = await repo.createChapter(branchId: branch);
      final draft = await service.prepare(
        branchId: branch,
        chapterId: chapter.id,
        connection: connection,
        brief: 'Anna returns',
      );
      expect(ids(draft), [anna.id]);
      expect(ids(draft), isNot(contains(ann.id)));
    },
  );
}
