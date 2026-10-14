import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

const _initVar = '''
世界:
  当前时间: 未知
  遭遇冷却: 20
  动向: {}
主角:
  姓名: 未知
  生命: 100
  好感度: [33, "好感度说明，范围 0-100"]
  储物袋:
    - \$__META_EXTENSIBLE__\$
    - 灵石
人物:
  \$meta:
    extensible: true
    template:
      好感: 0
      关系阶段: 陌生
绝色榜: {}
\$器灵台词: []
''';

Map<String, dynamic> _card({String opening = '开场。', bool zod = false}) => {
  'spec': 'chara_card_v2',
  'spec_version': '2.0',
  'data': {
    'name': '道渊',
    'description': '修仙世界',
    'scenario': '玄天界',
    'first_mes': opening,
    'alternate_greetings': ['[重塑仙缘]'],
    'character_book': {
      'name': '道渊世界书',
      'entries': [
        {
          'id': 1,
          'keys': <String>[],
          'comment': '[initvar] 初始',
          'constant': true,
          'enabled': false,
          'content': _initVar,
        },
        {
          'id': 2,
          'keys': <String>[],
          'comment': '变量列表',
          'constant': true,
          'enabled': true,
          'content': '<status_current_variables>\n{{format_message_variable::stat_data}}\n</status_current_variables>',
        },
      ],
    },
    'extensions': {
      if (zod)
        'tavern_helper': {
          'scripts': [
            {
              'name': 'ZOD',
              'enabled': true,
              'content': "import { registerMvuSchema } from 'x';",
            },
          ],
        },
    },
  },
};

MvuData _data() {
  final data = MvuData();
  MvuInit.load(data, [
    const MvuInitEntry(book: 'b', comment: '[initvar]', content: _initVar),
  ]);
  MvuInit.finalizeSchema(data);
  return data;
}

final class _ScriptProvider implements ModelProvider {
  _ScriptProvider(this.config, this.text);
  @override
  final ModelConnection config;
  final String text;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    yield TextDelta(text);
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

void main() {
  group('value parsing', () {
    test('parameters split on top-level commas only', () {
      expect(
        MvuValue.parseParameters(
          '"path.to.item", "hello, world", [1, [2, 3]], {a: "x,y"}',
        ),
        ['"path.to.item"', '"hello, world"', '[1, [2, 3]]', '{a: "x,y"}'],
      );
      expect(MvuValue.parseParameters(''), isEmpty);
    });

    test('command values follow MVU precedence', () {
      expect(MvuValue.parseCommandValue('35'), 35);
      expect(MvuValue.parseCommandValue('"35"'), '35');
      expect(MvuValue.parseCommandValue("'10 + 2'"), '10 + 2');
      expect(MvuValue.parseCommandValue('10 + 2 * 5 - 3 / 3'), 19);
      expect(MvuValue.parseCommandValue('(100 - 30) / (2 + 5)'), 10);
      expect(MvuValue.parseCommandValue('log(10^3, 10) * sqrt(144)'), 36);
      expect(
        MvuValue.parseCommandValue('Math.floor(3.9) + math.pow(2, 3)'),
        11,
      );
      expect(MvuValue.parseCommandValue('true'), isTrue);
      expect(MvuValue.parseCommandValue('null'), isNull);
      expect(MvuValue.parseCommandValue('{name: "John", age: 30}'), {
        'name': 'John',
        'age': 30,
      });
      expect(
        MvuValue.parseCommandValue("['2015-01-01', '日期 YYYY - MM - DD']"),
        ['2015-01-01', '日期 YYYY - MM - DD'],
      );
      expect(MvuValue.parseCommandValue('2025-01-01'), '2025-01-01');
      expect(MvuValue.parseCommandValue('元会历·3726年'), '元会历·3726年');
      expect(MvuValue.parseCommandValue('hello_world'), 'hello_world');
      expect(MvuValue.parseCommandValue("'it''s'"), "it's");
      expect(MvuValue.parseCommandValue('Math.random = 0'), 'Math.random = 0');
    });

    test('paths are normalised the way MVU fixes them', () {
      expect(MvuValue.pathFix('foo."bar".baz'), 'foo.bar.baz');
      expect(MvuValue.pathFix('foo."a b".c'), 'foo["a b"].c');
      expect(MvuValue.pathFix('武器栏["衔尾蛇"]'), '武器栏[衔尾蛇]');
      expect(MvuValue.pathFix('弹药系统[7.62mm ETC弹匣]'), '弹药系统["7.62mm ETC弹匣"]');
      expect(MvuValue.pathFix('foo["0"]'), 'foo["0"]');
      expect(MvuPath.toPath('a.b[0]["c d"].e'), ['a', 'b', '0', 'c d', 'e']);
      expect(
        MvuPath.get({
          'a': [
            1,
            {'b': 2},
          ],
        }, 'a[1].b'),
        2,
      );
    });

    test(
      'relaxed JSON accepts comments, trailing commas and YAML falls back',
      () {
        expect(MvuValue.parseStructured('{a: 1, /* c */ b: [1, 2,],} // x'), {
          'a': 1,
          'b': [1, 2],
        });
        expect(MvuValue.parseStructured('a: 1\nb:\n  - x'), {
          'a': 1,
          'b': ['x'],
        });
        expect(() => MvuValue.parseStructured('{'), throwsFormatException);
      },
    );
  });

  group('command extraction', () {
    test('finds script calls, requires a semicolon and keeps reasons', () {
      final commands = MvuCommandParser.extract('''
正文。
_.set('悠纪.好感度', 33, 35);//愉快的一次讨论
_.set('data', ["item with ); inside"], ["new item"]); // 特殊字符
_.set('name', 'old', 'new')
_.set('short');
_.add('钱', 10 * 2);
_.remove('物品', '剑');
''');
      expect(commands.map((c) => c.type), ['set', 'set', 'add', 'remove']);
      expect(commands.first.args, ["'悠纪.好感度'", '33', '35']);
      expect(commands.first.reason, '愉快的一次讨论');
      expect(commands[1].reason, '特殊字符');
      expect(commands[1].args[1], '["item with ); inside"]');
    });

    test('ignores analysis blocks and reads JSON Patch blocks', () {
      final commands = MvuCommandParser.extract('''
<UpdateVariable>
<Analysis>
1. 时间: _.set('x', 1);
</Analysis>
<JSONPatch>
```json
[
  { "op": "replace", "path": "/世界/当前时间", "value": "三月" },
  { "op": "delta", "path": "/世界/遭遇冷却", "value": -1 },
  { "op": "insert", "path": "/人物/新人", "value": {"好感": 1} },
  { "op": "insert", "path": "/\$器灵台词/-", "value": "哟" },
  { "op": "remove", "path": "/绝色榜/旧" },
  { "op": "move", "from": "/a", "path": "/b" }
]
```
</JSONPatch>
</UpdateVariable>''');
      expect(commands.map((c) => c.type), [
        'set',
        'add',
        'insert',
        'insert',
        'delete',
        'move',
      ]);
      expect(commands.first.args, ['["世界"]["当前时间"]', '"三月"']);
      expect(commands[2].args, ['["人物"]', '"新人"', '{"好感":1}']);
      expect(commands[3].args, ['["\$器灵台词"]', '"-"', '"哟"']);
      expect(commands.every((c) => c.fromJsonPatch), isTrue);
    });
  });

  group('updater', () {
    test('set honours value-with-description pairs and number coercion', () {
      final data = _data();
      final result = MvuUpdater.apply('''
_.set('主角.好感度', 33, 35);//相谈甚欢
_.set('主角.生命', "80");
_.set('主角.不存在', 1);
_.set('世界.当前时间', '元会历·3726年');
''', data);
      expect(result.modified, isTrue);
      expect(data.statData['主角']['好感度'], [35, '好感度说明，范围 0-100']);
      expect(data.statData['主角']['生命'], 80);
      expect(data.statData['世界']['当前时间'], '元会历·3726年');
      expect(result.errors, hasLength(1));
      expect(result.errors.single, contains('主角.不存在'));
      expect(data.displayData['主角']['好感度'], '33->35 (相谈甚欢)');
      expect(data.deltaData['主角']['生命'], '100->80 ');
      expect(data.deltaData['主角'], isNot(contains('姓名')));
      expect(data.displayData['主角']['姓名'], '未知');
    });

    test('insert respects extensible markers, templates and delete rules', () {
      final data = _data();
      expect(
        ((((data.schema['properties']['主角'] as Map)['properties']
                as Map)['储物袋'])
            as Map)['extensible'],
        isTrue,
      );
      expect(data.statData['主角']['储物袋'], ['灵石']);
      final result = MvuUpdater.apply('''
_.insert('主角.储物袋', '飞剑');
_.insert('人物', '温月清', {"好感": 5});
_.insert('世界.动向', '魔宗异动', {"阶段": "起"});
_.remove('主角.储物袋', '灵石');
_.delete('人物.温月清.关系阶段');
''', data);
      expect(data.statData['主角']['储物袋'], ['飞剑']);
      expect(data.statData['人物']['温月清'], {'好感': 5, '关系阶段': '陌生'});
      expect(data.statData['世界']['动向'], isEmpty);
      expect(result.errors, hasLength(2));
      expect(result.errors.first, contains('不可扩展'));
      expect(result.errors.last, contains('必需'));
      expect(
        (((data.schema['properties']['人物'] as Map)['properties'] as Map)['温月清']
            as Map)['type'],
        'object',
      );
    });

    test('add handles numbers and ISO dates; move relocates values', () {
      final data = _data();
      data.statData['时间'] = '2026-10-13T08:00:00.000Z';
      MvuInit.finalizeSchema(data);
      final result = MvuUpdater.apply('''
_.add('主角.好感度', 2);
_.add('世界.遭遇冷却', -1);//冷却
_.add('时间', 60 * 60 * 1000);
_.add('主角.姓名', 1);
<JSONPatch>[{"op":"move","from":"/主角/姓名","path":"/主角/道号"}]</JSONPatch>
''', data);
      expect(data.statData['主角']['好感度'][0], 35);
      expect(data.statData['世界']['遭遇冷却'], 19);
      expect(data.statData['时间'], '2026-10-13T09:00:00.000Z');
      expect(data.statData['主角'], isNot(contains('姓名')));
      expect(data.statData['主角']['道号'], '未知');
      expect(data.deltaData['世界']['遭遇冷却'], '20->19 (冷却)');
      expect(result.errors.single, contains('不能做加法'));
    });

    test(
      'an any schema turns structural checks off, as MVU Zod cards expect',
      () {
        final data = _data()..schema = MvuService.anySchema;
        final result = MvuUpdater.apply('''
<JSONPatch>[
 {"op":"insert","path":"/绝色榜/瑶汐","value":{"仙姿":"清冷"}},
 {"op":"insert","path":"/\$器灵台词/-","value":"哟"},
 {"op":"remove","path":"/主角/生命"}
]</JSONPatch>''', data);
        expect(result.errors, isEmpty);
        expect(data.statData['绝色榜']['瑶汐'], {'仙姿': '清冷'});
        expect(data.statData['\$器灵台词'], ['哟']);
        expect(data.statData['主角'], isNot(contains('生命')));
        expect(data.schema['type'], 'any');
      },
    );

    test('records round-trip through stored string variables', () {
      final data = _data();
      final stored = data.toStored();
      expect(MvuData.presentIn(stored), isTrue);
      final back = MvuData.fromStored({...stored, 'mood': '平静'})!;
      expect(back.statData, data.statData);
      expect(back.schema, data.schema);
      expect(MvuData.fromStored({'mood': '平静'}), isNull);
    });
  });

  group('init var', () {
    test('merges books in order, keeps existing keys, unwraps fences', () {
      final data = MvuData(
        statData: {
          'existing': 'keep',
          '悠纪': {'喵': '1'},
        },
      );
      final errors = <String>[];
      final loaded = MvuInit.load(data, [
        const MvuInitEntry(
          book: 'a',
          comment: 'alpha [initvar]',
          content: '{"悠纪":{"喵":"1","喵呜":"2"},"new_key":"new","list":[1,2]}',
        ),
        const MvuInitEntry(
          book: 'a',
          comment: '[INITVAR] block',
          content:
              '<initvar>\n```json\n{"block":"yes","list":[]}\n```\n</initvar>',
        ),
        const MvuInitEntry(
          book: 'a',
          comment: 'skip',
          content: '{"ignored":1}',
        ),
        const MvuInitEntry(
          book: 'b',
          comment: '[initvar]',
          content: 'bad: [unclosed',
        ),
      ], errors: errors);
      expect(loaded, isTrue);
      expect(data.statData, {
        '悠纪': {'喵': '1'},
        'existing': 'keep',
        'new_key': 'new',
        'list': <Object?>[],
        'block': 'yes',
      });
      expect(data.initializedLorebooks.keys, ['a', 'b']);
      expect(errors.single, contains('b'));
      expect(MvuInit.load(data, const []), isFalse);
    });

    test('opening <initvar> blocks override the book', () {
      expect(
        MvuInit.openingOverride(
          '文字<initvar>\n{"a": 1}\n</initvar>再来<initvar>b: 2</initvar>',
        ),
        {'a': 1, 'b': 2},
      );
      expect(MvuInit.openingOverride('没有'), isNull);
    });
  });

  group('story integration', () {
    late StoryRepository repo;
    setUp(() async {
      repo = StoryRepository.memory();
    });
    tearDown(() => repo.close());

    Future<Novel> novelWith({String opening = '开场。', bool zod = false}) async {
      await repo.storeResource(
        id: 'card',
        kind: ResourceKind.character,
        name: '道渊',
        filename: 'card.json',
        sourceHash: 'fixture',
        encryptedSource: [],
        data: _card(opening: opening, zod: zod),
      );
      await repo.savePersona(const Persona(id: 'jiushen', name: '玖神'));
      return repo.createNovelFromCard(
        resourceId: 'card',
        title: '道渊',
        personaId: 'jiushen',
      );
    }

    test('creating a novel from a card seeds the opening chapter', () async {
      final novel = await novelWith(
        opening: '{{user}}踏入山门。\n<UpdateVariable>\n_.set(\'主角.姓名\', \'未知\', \'玖神\');//开局\n</UpdateVariable>',
      );
      final data = (await MvuService(repo).storedAt(novel.activeBranchId))!;
      expect(data.statData['主角']['姓名'], '玖神');
      expect(data.statData['主角']['生命'], 100);
      expect(data.initializedLorebooks.keys, ['道渊世界书']);
      expect(data.displayData['主角']['姓名'], '未知->玖神 (开局)');
      expect(data.schema['type'], 'object');
      expect(await MvuService(repo).schemaChecks(novel.activeBranchId), isTrue);
    });

    test('a card with a schema script disables structural checks', () async {
      final novel = await novelWith(zod: true);
      final data = (await MvuService(repo).storedAt(novel.activeBranchId))!;
      expect(data.schema, {'type': 'any'});
      await repo.setSetting('writing/${novel.activeBranchId}', {
        ...?await repo.getSetting('writing/${novel.activeBranchId}'),
        MvuService.schemaChecksKey: true,
      });
      expect(await MvuService(repo).schemaChecks(novel.activeBranchId), isTrue);
    });

    test(
      'generation reads the state, applies the reply and keeps one status bar',
      () async {
        final novel = await novelWith();
        final branchId = novel.activeBranchId;
        final story = await repo.getStory(branchId);
        final card = const CardImporter().decode(
          Uint8List.fromList(utf8.encode(jsonEncode(_card()))),
          'card.json',
        );
        const reply = '''
她笑了。
<UpdateVariable>
<Analysis>
1. 好感度: Y
</Analysis>
_.set('主角.好感度', 33, 40);//初见
<JSONPatch>[{"op":"delta","path":"/世界/遭遇冷却","value":-1}]</JSONPatch>
</UpdateVariable>''';
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => _ScriptProvider(c, reply),
        );
        addTearDown(runner.close);
        final service = WritingService(repository: repo, runner: runner);
        final connection = ModelConnection(
          id: 'local',
          name: 'Test',
          baseUrl: 'http://localhost:1234/v1',
          model: 'm',
        );
        final draft = await service.prepare(
          branchId: branchId,
          chapterId: story.chapters.single.id,
          connection: connection,
          brief: '继续',
          append: true,
          card: card,
        );
        final messages = (draft.compiled['messages'] as List).cast<Map>();
        final prompt = messages.map((m) => m['content']).join('\n');
        expect(prompt, contains('<status_current_variables>\n世界:\n  当前时间: 未知'));
        expect(prompt, contains('  好感度:\n    - 33\n    - 好感度说明，范围 0-100'));
        expect(prompt, isNot(contains('\$器灵台词')));
        expect(draft.compiled['trace'], contains('mvu:base:initvar'));
        final task = await service.startPrepared(draft);
        await runner.wait(task.id);
        final done = await repo.getTask(task.id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect(done.result['mvu']['modified'], isTrue);
        expect(done.result['mvu']['errors'], isEmpty);
        final proposal = await repo.getProposal(
          done.result['proposalId'] as String,
        );
        expect(
          proposal.content.text.trim(),
          endsWith('<StatusPlaceHolderImpl/>'),
        );
        expect(proposal.content.text, contains("_.set('主角.好感度', 33, 40)"));
        await repo.acceptProposal(proposal.id);
        final data = (await MvuService(repo).storedAt(branchId))!;
        expect(data.statData['主角']['好感度'][0], 40);
        expect(data.statData['世界']['遭遇冷却'], 19);
        expect(data.displayData['主角']['好感度'], '33->40 (初见)');

        // The next request starts from the stored record and never sends the
        // placeholder; appending again keeps a single status bar.
        final updated = await repo.getStory(branchId);
        final next = await service.prepare(
          branchId: branchId,
          chapterId: updated.chapters.single.id,
          connection: connection,
          brief: '再来',
          append: true,
          card: card,
        );
        final nextPrompt = (next.compiled['messages'] as List)
            .cast<Map>()
            .map((m) => m['content'])
            .join('\n');
        expect(nextPrompt, isNot(contains('StatusPlaceHolderImpl')));
        expect(nextPrompt, contains('遭遇冷却: 19'));
        expect(next.compiled['trace'], contains('mvu:base:initvar'));
        final second = await service.startPrepared(next);
        await runner.wait(second.id);
        final secondProposal = await repo.getProposal(
          (await repo.getTask(second.id)).result['proposalId'] as String,
        );
        expect(
          '<StatusPlaceHolderImpl/>'.allMatches(secondProposal.content.text),
          hasLength(1),
        );
        await repo.acceptProposal(secondProposal.id);
        final replayed = (await MvuService(repo).storedAt(branchId))!;
        // Both replies live in the opening chapter, so its record is the
        // opening's base plus every command in the chapter text.
        expect(replayed.statData['世界']['遭遇冷却'], 18);
      },
    );

    test(
      'reprocess and reloadInitVar rebuild records from the chapters',
      () async {
        final novel = await novelWith();
        final branchId = novel.activeBranchId;
        final service = MvuService(repo);
        final story = await repo.getStory(branchId);
        final second = await repo.createChapter(
          branchId: branchId,
          content: ManuscriptContent.plainText(
            "第二幕。\n_.set('主角.生命', 100, 60);//受伤\n",
          ),
        );
        expect(
          (await service.storedAt(
            branchId,
            chapterId: second.id,
          ))!.statData['主角']['生命'],
          100,
        );
        final errors = await service.reprocess(branchId);
        expect(errors, isEmpty);
        final at2 = (await service.storedAt(branchId, chapterId: second.id))!;
        expect(at2.statData['主角']['生命'], 60);
        expect(at2.deltaData['主角']['生命'], '100->60 (受伤)');
        final at1 = (await service.storedAt(
          branchId,
          chapterId: story.chapters.single.id,
        ))!;
        expect(at1.statData['主角']['生命'], 100);
        final base = await service.baseFor(branchId, second.id);
        expect(base!.statData['主角']['生命'], 100);
        // A book bound later brings new keys without touching existing ones.
        await repo.storeResource(
          id: 'book',
          kind: ResourceKind.worldBook,
          name: '额外',
          filename: 'book.json',
          sourceHash: 'fixture2',
          encryptedSource: [],
          data: {
            'name': '额外',
            'entries': [
              {
                'id': 1,
                'keys': <String>[],
                'comment': '[InitVar] 额外',
                'content': '{"主角": {"生命": 1}, "天气": "晴"}',
              },
            ],
          },
        );
        await repo.setSetting('writing/$branchId', {
          ...?await repo.getSetting('writing/$branchId'),
          'worldBookIds': ['book'],
        });
        final reloaded = (await service.reloadInitVar(branchId))!;
        expect(reloaded.statData['天气'], '晴');
        expect(reloaded.statData['主角']['生命'], 60);
        expect(
          reloaded.initializedLorebooks.keys,
          containsAll(['道渊世界书', '额外']),
        );
      },
    );

    test('an opening <initvar> override survives reprocess and seeding', () async {
      final novel = await novelWith(
        opening:
            '<initvar>\n{"主角": {"生命": 50, "姓名": "阿雾"}}\n</initvar>\n'
            "_.set('主角.生命', 50, 45);//开局",
      );
      final branchId = novel.activeBranchId;
      final service = MvuService(repo);
      final created = (await service.storedAt(branchId))!;
      expect(created.statData['主角'], {'生命': 45, '姓名': '阿雾'});
      expect(created.statData, isNot(contains('世界')));
      final story = await repo.getStory(branchId);
      final opening = story.chapters.single;
      // The opening's base is the seed: override applied, commands not yet.
      final base = (await service.baseFor(branchId, opening.id))!;
      expect(base.statData['主角']['生命'], 50);
      await service.reprocess(branchId);
      final replayed = (await service.storedAt(branchId))!;
      expect(replayed.statData['主角'], {'生命': 45, '姓名': '阿雾'});
      // A later chapter without a stored record also starts from the override.
      final second = await repo.createChapter(
        branchId: branchId,
        content: ManuscriptContent.plainText('第二幕。'),
      );
      final fromOpening = (await service.baseFor(branchId, second.id))!;
      expect(fromOpening.statData['主角']['生命'], 45);
      // Entries supplied by a writing request give the same record.
      final supplied = (await service.baseFor(
        branchId,
        second.id,
        entries: MvuService.entriesOfCard(_card()),
        schemaChecks: true,
      ))!;
      expect(supplied.statData, fromOpening.statData);
    });

    test('rewrites inside an MVU chapter keep offsets and a single tidy placeholder', () async {
      final novel = await novelWith();
      final branchId = novel.activeBranchId;
      final card = const CardImporter().decode(
        Uint8List.fromList(utf8.encode(jsonEncode(_card()))),
        'card.json',
      );
      final connection = ModelConnection(
        id: 'local',
        name: 'Test',
        baseUrl: 'http://localhost:1234/v1',
        model: 'm',
      );
      Future<String> run(
        String reply, {
        int? start,
        int? end,
        bool append = true,
      }) async {
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => _ScriptProvider(c, reply),
        );
        try {
          final service = WritingService(repository: repo, runner: runner);
          final chapter = (await repo.getStory(branchId)).chapters.single;
          final draft = await service.prepare(
            branchId: branchId,
            chapterId: chapter.id,
            connection: connection,
            brief: '写',
            append: append,
            card: card,
            rangeStart: start,
            rangeEnd: end,
          );
          final task = await service.startPrepared(draft);
          await runner.wait(task.id);
          final done = await repo.getTask(task.id);
          expect(done.status, TaskStatus.completed, reason: done.error);
          await repo.acceptProposal(done.result['proposalId'] as String);
          return (await repo.getStory(branchId)).chapters.single.content.text;
        } finally {
          await runner.close();
        }
      }

      var text = await run('第一段。');
      expect(text, '开场。\n\n第一段。\n\n<StatusPlaceHolderImpl/>\n');
      text = await run('第二段。');
      expect(text, '开场。\n\n第一段。\n\n第二段。\n\n<StatusPlaceHolderImpl/>\n');
      // Replace the last paragraph up to the very end of the chapter.
      final from = text.indexOf('第二段');
      text = await run(
        "改写段。\n_.set('主角.生命', 100, 70);",
        start: from,
        end: text.length - 1,
        append: false,
      );
      expect(text, startsWith('开场。\n\n第一段。\n\n改写段。'));
      expect('<StatusPlaceHolderImpl/>'.allMatches(text), hasLength(1));
      expect(text, endsWith('\n\n<StatusPlaceHolderImpl/>\n'));
      expect(
        (await MvuService(repo).storedAt(branchId))!.statData['主角']['生命'],
        70,
      );
    });

    test('{{lastMessage}} never carries the placeholder', () async {
      final preset = PresetImporter().decode({
        'name': 'last',
        'prompts': [
          {
            'identifier': 'main',
            'role': 'system',
            'content': '上一幕：{{lastMessage}}',
          },
          {'identifier': 'chatHistory', 'role': 'system', 'marker': true},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
        ],
      });
      final compiled = PromptCompiler().compile(
        PresetInput(
          preset: preset,
          branchId: 'b',
          throughPosition: 0,
          brief: '继续',
          clock: DateTime.utc(2026),
          randomSeed: 1,
          history: const [
            ContextChapter(
              branchId: 'b',
              position: 0,
              chapterId: 's',
              revisionId: 'r',
              content: '她笑了。\n\n<StatusPlaceHolderImpl/>\n',
            ),
          ],
        ),
      );
      final text = compiled.messages.map((m) => m.content).join('\n');
      expect(text, isNot(contains('StatusPlaceHolderImpl')));
      expect(text, contains('上一幕：她笑了。'));
    });

    test('the HTML bridge parses messages and reloads InitVar', () async {
      final novel = await novelWith();
      final backend = BranchChatBackend(
        repository: repo,
        branchId: novel.activeBranchId,
        context: await repo.displayContext(novel.activeBranchId),
      );
      final state = await backend.snapshot(0);
      final data = ((state['variables'] as Map)['chat'] as Map)
          .cast<String, dynamic>();
      expect(data['stat_data']['主角']['生命'], 100);
      final parsed = await backend.mvuParseMessage(
        "_.set('主角.生命', 100, 70);//试炼",
        data,
      );
      expect(parsed['stat_data']['主角']['生命'], 70);
      expect(parsed['delta_data']['主角']['生命'], '100->70 (试炼)');
      expect(data['stat_data']['主角']['生命'], 100);
      expect(await backend.mvuReloadInitVar(parsed), isNull);
      final fresh = await backend.mvuReloadInitVar({
        'stat_data': {'x': 1},
      });
      expect(fresh!['stat_data']['x'], 1);
      expect(fresh['stat_data']['主角']['生命'], 100);
    });
  });
}
