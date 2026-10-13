import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

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
}
