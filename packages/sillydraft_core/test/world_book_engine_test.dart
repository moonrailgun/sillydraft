import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

// Expectations come from the pinned ST 1.19.0 (06bde939…) world-info.js
// `checkWorldInfo`, run on the same books with a fresh install's settings.

/// A card's book entry (V2 spec), read as `convertCharacterBook` does.
Map<String, dynamic> card(
  int id,
  List<String> keys,
  String content,
  int order, {
  bool? enabled = true,
  Map<String, dynamic> ext = const {},
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'keys': keys,
  'content': content,
  'insertion_order': order,
  'extensions': ext,
  'enabled': ?enabled,
  ...extra,
};

/// An ST world file entry, read as stored.
Map<String, dynamic> native(
  int uid,
  List<String> key,
  String content,
  int order, [
  Map<String, dynamic> extra = const {},
]) => {
  'uid': uid,
  'key': key,
  'content': content,
  'order': order,
  'position': 0,
  ...extra,
};

Map<String, dynamic> book(
  List<Map<String, dynamic>> entries, [
  Map<String, dynamic> extra = const {},
]) => {
  'entries': {for (final e in entries) '${e['uid']}': e},
  ...extra,
};

WorldBookResult scan(
  List<Map<String, dynamic>> books, {
  List<Map<String, dynamic>>? cardEntries,
  required List<String> chat,
  int? budget,
  String? character = '苏雾',
  Map<String, String> data = const {},
}) => WorldBookEngine().activate(
  [for (final b in books) ScopedWorldBook(WorldBook.fromJson(b))],
  characterBook: cardEntries == null
      ? null
      : WorldBook.fromJson({'entries': cardEntries}),
  character: character,
  branchId: 'main',
  throughPosition: 0,
  messages: chat,
  macros: MacroEngine(values: {}, clock: DateTime.utc(2026), seed: 1),
  seed: 1,
  budget: budget,
  scanData: (field) => data[field] ?? '',
);

void main() {
  test('all books are scanned together, the character\'s first', () {
    // getSortedEntries `character_first`: the card's book by order, then
    // the other books' entries together by order; recursion (on in a fresh
    // install) crosses books; a book's own settings are not read.
    final result = scan(
      [
        book(
          [
            native(1, ['乙'], '丙', 100),
            native(2, [], '丁', 60, {'constant': true}),
          ],
          {'recursive_scanning': false, 'scan_depth': 0},
        ),
        book([
          native(1, [], '戊', 80, {'constant': true}),
          native(2, ['丙'], '己', 60),
          native(3, [], '庚', 60, {'constant': true}),
        ]),
      ],
      cardEntries: [
        card(1, ['雨'], '甲 harbor', 100),
        card(2, ['harbor'], '乙', 50),
      ],
      chat: ['苏雾: 她推开门', '阿雨: 下雨了'],
    );
    expect(result.before, '己\n庚\n丁\n戊\n丙');
    expect(result.after, '乙\n甲 harbor');
  });

  test('card entries are read as convertCharacterBook converts them', () {
    final result = scan(
      [
        book([
          // A world file's own fields count, not its stale `extensions`.
          native(
            1,
            ['雨'],
            'n1',
            10,
            {
              'extensions': {'position': 1, 'exclude_recursion': true},
            },
          ),
          native(
            2,
            ['雨'],
            'n2',
            20,
            {'position': 1, 'useProbability': true, 'probability': 0},
          ),
          native(3, ['雨'], 'n3', 30, {'probability': 0}),
        ]),
      ],
      cardEntries: [
        // No position: after the character.
        card(1, ['雨'], 'c1', 10),
        // No `enabled`: disabled.
        card(2, ['雨'], 'c2', 20, enabled: null),
        // `useProbability` defaults to on.
        card(3, ['雨'], 'c3', 30, ext: {'probability': 0}),
        // Only `extensions.case_sensitive` counts.
        card(4, ['Rain'], 'c4', 40, extra: {'case_sensitive': true}),
        card(5, ['Rain'], 'c5', 50, ext: {'case_sensitive': true}),
        card(6, ['雨'], 'c6', 60, extra: {'position': 'before_char'}),
        card(
          7,
          ['雨'],
          'c7',
          70,
          extra: {'position': 'before_char'},
          ext: {'position': 1},
        ),
      ],
      chat: ['苏雾: 下雨了 rain'],
    );
    expect(result.before, 'n1\nn3\nc6');
    expect(result.after, 'c1\nc4\nc7');
  });

  test('keys are matched in the last two messages as whole words', () {
    final result = scan(
      [],
      cardEntries: [
        card(1, ['第一条'], 's1', 1),
        card(2, ['第一条'], 's2', 2, ext: {'scan_depth': 3}),
        // `\W` is ASCII: a CJK neighbour is a word boundary.
        card(3, ['cat'], 's3', 3),
        card(4, ['cat'], 's4', 4, ext: {'scan_depth': 3}),
        card(5, ['cat'], 's5', 5, ext: {'match_whole_words': false}),
        card(6, ['二'], 's6', 6),
        card(7, ['the cats'], 's7', 7),
        card(8, ['THE'], 's8', 8),
        card(9, ['/c.ts s/'], 's9', 9),
        // Not a valid regex: matched as text.
        card(10, ['/x(/'], 's10', 10),
        card(11, ['苏雾'], 's11', 11),
        card(12, [' 第二条 '], 's12', 12),
        card(13, ['第二条'], 's13', 13, ext: {'scan_depth': 0}),
        // Each message starts with \x01 in the scanned text.
        card(14, ['/^苏雾/'], 's14', 14),
        card(15, [r'/sat\.$/m'], 's15', 15),
      ],
      chat: ['苏雾: 第一条 cat-food', '阿雨: 第二条', '苏雾: 第三条 the cats sat.\n/x(/ 完'],
    );
    expect(result.before, '');
    expect(
      result.after,
      [
        's2',
        's4',
        's5',
        's6',
        's7',
        's8',
        's9',
        's10',
        's11',
        's12',
        's15',
      ].join('\n'),
    );
  });

  test('recursion follows the exclude, prevent and delay settings', () {
    final result = scan(
      [],
      cardEntries: [
        card(
          1,
          [],
          'alpha',
          100,
          extra: {'constant': true},
          ext: {'prevent_recursion': true},
        ),
        card(2, ['alpha'], 'x2', 90),
        card(3, [], 'beta', 80, extra: {'constant': true}),
        card(4, ['beta'], 'gamma', 70, ext: {'exclude_recursion': true}),
        card(5, ['beta'], 'delta', 60),
        card(6, ['beta'], 'd1', 50, ext: {'delay_until_recursion': true}),
        // Its level opens once nothing else is left to recurse.
        card(7, ['delta'], 'd2', 40, ext: {'delay_until_recursion': 2}),
        card(8, ['gamma'], 'x8', 30),
      ],
      chat: ['苏雾: 开始'],
    );
    expect(result.after, 'd2\nd1\ndelta\nbeta\nalpha');
  });

  test('later steps count no prevented text toward the budget', () {
    // Step one: 长×6 + kw = 11 of 12; step two counts kw and 短 only.
    final result = scan(
      [],
      cardEntries: [
        card(
          1,
          [],
          '长长长长长长',
          100,
          extra: {'constant': true},
          ext: {'prevent_recursion': true},
        ),
        card(2, [], 'kw', 90, extra: {'constant': true}),
        card(3, ['kw'], '短', 80),
      ],
      chat: ['苏雾: 开始'],
      budget: 12,
    );
    expect(result.after, '短\nkw\n长长长长长长');
    expect(result.diagnostics, isEmpty);
  });

  test('an inclusion group keeps one entry', () {
    final result = scan(
      [],
      cardEntries: [
        // Highest order of the overrides.
        card(1, [], 'g1', 10, extra: {'constant': true}, ext: {'group': 'A'}),
        for (final (id, order) in [(2, 20), (3, 30)])
          card(
            id,
            [],
            'g$id',
            order,
            extra: {'constant': true},
            ext: {'group': 'A', 'group_override': true},
          ),
        // Weighted: only h2 has weight.
        card(
          4,
          [],
          'h1',
          50,
          extra: {'constant': true},
          ext: {'group': 'B', 'group_weight': 0},
        ),
        card(
          5,
          [],
          'h2',
          40,
          extra: {'constant': true},
          ext: {'group': 'B', 'group_weight': 100},
        ),
        // Scored: k2 matches more keys.
        card(
          6,
          ['雨'],
          'k1',
          60,
          ext: {'group': 'C', 'use_group_scoring': true},
        ),
        card(
          7,
          ['雨', '夜'],
          'k2',
          61,
          ext: {'group': 'C', 'use_group_scoring': true},
        ),
        // A group already in the prompt takes no more.
        card(8, [], 'm1', 5, extra: {'constant': true}, ext: {'group': 'D'}),
        card(9, ['g3'], 'm2', 4, ext: {'group': 'D'}),
      ],
      chat: ['苏雾: 雨夜'],
    );
    expect(result.after, 'm1\ng3\nh2\nk2');
  });

  test('decorators, triggers, character filters and delays', () {
    final result = scan(
      [
        book([
          native(1, ['不存在'], '@@activate\nt1', 1),
          native(2, [], '@@dont_activate\nt2', 2, {'constant': true}),
          native(3, [], 't3', 3, {
            'constant': true,
            'triggers': ['continue'],
          }),
          native(4, [], 't4', 4, {
            'constant': true,
            'triggers': ['normal'],
          }),
          for (final (uid, exclude, names, tags) in [
            (5, false, ['苏雾'], <String>[]),
            (6, false, ['别人'], <String>[]),
            (7, true, ['苏雾'], <String>[]),
            // The character has no tags.
            (8, false, <String>[], ['t-1']),
            (9, true, <String>[], ['t-1']),
          ])
            native(uid, [], 't$uid', uid, {
              'constant': true,
              'characterFilter': {
                'isExclude': exclude,
                'names': names,
                'tags': tags,
              },
            }),
          // Two messages: a delay of 3 holds, 2 does not.
          native(10, [], 't10', 10, {'constant': true, 'delay': 3}),
          native(11, [], 't11', 11, {'constant': true, 'delay': 2}),
          native(12, [], 't12', 12, {
            'constant': true,
            'sticky': 2,
            'cooldown': 3,
          }),
          native(13, ['不存在'], '@@@activate\nt13', 13),
          native(14, ['不存在'], '@@unknown\n@@@activate\nt14', 14),
        ]),
      ],
      chat: ['苏雾: 一', '阿雨: 二'],
    );
    expect(result.before, 't1\nt4\nt5\nt9\nt11\nt12\nt14');
    // Each request scans as ST does in a new chat: no timed effect yet.
    expect(result.diagnostics.map((d) => (d.code, d.severity)), [
      ('world_book_timed_effect', DiagnosticSeverity.warning),
      ('world_book_timed_effect', DiagnosticSeverity.warning),
    ]);
  });

  test('an entry can also scan the card and persona texts', () {
    final result = scan(
      [
        book([
          native(1, ['守塔'], 'u1', 1, {'matchCharacterDescription': true}),
          native(2, ['守塔'], 'u2', 2),
          native(3, ['雾港'], 'u3', 3, {'matchScenario': true}),
          native(4, ['旧友'], 'u4', 4, {'matchPersonaDescription': true}),
        ]),
      ],
      chat: ['苏雾: 一'],
      data: {
        'characterDescription': '守塔人',
        'scenario': '住在雾港',
        'personaDescription': '旧友',
      },
    );
    expect(result.before, 'u1\nu3\nu4');
  });

  test('secondary keys follow the selective logic', () {
    Map<String, dynamic> entry(
      int uid,
      List<String> also,
      int logic, {
      bool selective = true,
    }) => native(
      uid,
      ['雨'],
      'v$uid',
      uid,
      {'selective': selective, 'keysecondary': also, 'selectiveLogic': logic},
    );
    final result = scan(
      [
        book([
          entry(1, ['夜', '晴'], 0),
          entry(2, ['夜', '晴'], 1),
          entry(3, ['夜'], 2),
          entry(4, ['夜', '晴'], 3),
          entry(5, ['夜'], 3),
          entry(6, ['晴'], 3, selective: false),
        ]),
      ],
      chat: ['苏雾: 雨 夜'],
    );
    expect(result.before, 'v1\nv2\nv5\nv6');
  });
}
