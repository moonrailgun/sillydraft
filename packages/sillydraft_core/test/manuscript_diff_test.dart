import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('separate edits retain the unchanged paragraphs between them', () {
    final changes = compareParagraphs(
      '开头\n旧一\n中间\n旧二\n结尾\n',
      '开头\n新一\n中间\n新二\n结尾\n',
    );
    expect(changes.map((change) => change.kind), [
      ParagraphChangeKind.unchanged,
      ParagraphChangeKind.removed,
      ParagraphChangeKind.added,
      ParagraphChangeKind.unchanged,
      ParagraphChangeKind.removed,
      ParagraphChangeKind.added,
      ParagraphChangeKind.unchanged,
    ]);
    expect(changes[3].paragraphs, ['中间\n']);
  });

  test('a changed word marks the entire paragraph', () {
    final changes = compareParagraphs('她走向渡口。\n', '她走向山谷。\n');
    expect(changes.map((change) => change.kind), [
      ParagraphChangeKind.removed,
      ParagraphChangeKind.added,
    ]);
    expect(changes.first.paragraphs, ['她走向渡口。\n']);
    expect(changes.last.paragraphs, ['她走向山谷。\n']);
  });

  test('empty texts and unchanged texts need no artificial paragraph', () {
    expect(compareParagraphs('', ''), isEmpty);
    final changes = compareParagraphs('正文\n\n', '正文\n\n');
    expect(changes.single.kind, ParagraphChangeKind.unchanged);
    expect(changes.single.paragraphs, ['正文\n', '\n']);
  });

  test(
    'both texts reconstruct exactly including repeated lines and Unicode',
    () {
      for (final (before, after) in [
        ('', '新段\n'),
        ('旧段', ''),
        ('重复\n重复\n尾巴', '重复\n插入\n重复\n尾巴'),
        (' \r\n🌧️ 渡口\r\n\n结尾', '\t\r\n🌧️ 渡口\r\n\n结尾\n'),
        ('甲\n乙\n丙\n', '丙\n甲\n乙\n'),
      ]) {
        _expectReconstruction(before, after);
      }
    },
  );

  test('long chapters retain individual edits', () {
    final paragraphs = List.generate(5000, (index) => '第 $index 段\n');
    final before = paragraphs.join();
    paragraphs[2500] = '这一段已修改\n';
    final changes = compareParagraphs(before, paragraphs.join());
    expect(
      changes
          .where((change) => change.kind != ParagraphChangeKind.unchanged)
          .map((change) => change.paragraphs),
      [
        ['第 2500 段\n'],
        ['这一段已修改\n'],
      ],
    );
  });

  test('more than 65536 unique paragraphs never corrupt the text', () {
    final paragraphs = List.generate(66000, (index) => '第 $index 段\n');
    final before = paragraphs.join();
    paragraphs[65990] = '最后的修改🌧️\n';
    _expectReconstruction(before, paragraphs.join());
  });
}

void _expectReconstruction(String before, String after) {
  final changes = compareParagraphs(before, after);
  String without(ParagraphChangeKind kind) => changes
      .where((change) => change.kind != kind)
      .expand((change) => change.paragraphs)
      .join();
  expect(without(ParagraphChangeKind.added), before);
  expect(without(ParagraphChangeKind.removed), after);
}
