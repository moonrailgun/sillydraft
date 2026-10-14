import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('chinese numbers read the way chapter numbers are written', () {
    expect(
      [
        for (final n in [1, 10, 12, 20, 104, 110, 1001]) chineseNumber(n),
      ],
      ['一', '十', '十二', '二十', '一百零四', '一百一十', '一千零一'],
    );
  });

  test('a heading splits into its number, numerals and name', () {
    expect(splitChapterTitle('第六章 反客为主的午休天台'), (
      number: 6,
      name: '反客为主的午休天台',
      numerals: ChapterNumerals.chinese,
    ));
    expect(splitChapterTitle('第12章：夜雨'), (
      number: 12,
      name: '夜雨',
      numerals: ChapterNumerals.arabic,
    ));
    expect(splitChapterTitle(' 第 3 章 · 归途 '), (
      number: 3,
      name: '归途',
      numerals: ChapterNumerals.arabic,
    ));
    expect(splitChapterTitle('第１２章 雨'), (
      number: 12,
      name: '雨',
      numerals: ChapterNumerals.arabic,
    ));
    expect(splitChapterTitle('第一百零四章'), (
      number: 104,
      name: '',
      numerals: ChapterNumerals.chinese,
    ));
    expect(splitChapterTitle('序章'), (number: null, name: '序章', numerals: null));
    expect(splitChapterTitle('卷一 · 第三章 归途'), (
      number: null,
      name: '卷一 · 第三章 归途',
      numerals: null,
    ));
  });

  test('display titles join the number and the name', () {
    expect(chapterTitle(6, '归途', ChapterNumerals.chinese), '第六章 归途');
    expect(chapterTitle(6, '归途', ChapterNumerals.arabic), '第6章 归途');
    expect(chapterTitle(1, '', ChapterNumerals.chinese), '第一章');
    expect(chapterTitle(null, '序章', ChapterNumerals.chinese), '序章');
    expect(chapterTitle(null, '', ChapterNumerals.chinese), '');
  });

  test(
    'existing titles are numbered only where the display stays the same',
    () {
      List<(bool, String)> number(List<String> titles) => [
        for (final t in numberChapterTitles(titles)) (t.numbered, t.name),
      ];
      expect(number(['第一章', '第二章 灯塔']), [(true, ''), (true, '灯塔')]);
      expect(number(['序章', '第一章 码头']), [(false, '序章'), (true, '码头')]);
      expect(number(['第一卷 起雾 · 第一章 码头', '第二章 灯塔']), [
        (false, '第一卷 起雾 · 第一章 码头'),
        (false, '第二章 灯塔'),
      ]);
      // From a gap on, titles stay as written.
      expect(number(['第一章 a', '第三章 b', '第四章 c']), [
        (true, 'a'),
        (false, '第三章 b'),
        (false, '第四章 c'),
      ]);
      // An untitled chapter takes the next number.
      expect(number(['', '第二章 b']), [(true, ''), (true, 'b')]);
    },
  );

  test('a book keeps the numerals most of its numbered titles use', () {
    expect(inferNumerals(['第1章', '第2章', '第三章']), ChapterNumerals.arabic);
    expect(inferNumerals(['第一章', '第2章', '第三章']), ChapterNumerals.chinese);
    expect(inferNumerals(['序章']), ChapterNumerals.chinese);
  });
}
