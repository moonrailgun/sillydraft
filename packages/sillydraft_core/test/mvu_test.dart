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

MvuData _data() {
  final data = MvuData();
  MvuInit.load(data, [
    const MvuInitEntry(book: 'b', comment: '[initvar]', content: _initVar),
  ]);
  MvuInit.finalizeSchema(data);
  return data;
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
}
