/// How a novel writes its chapter numbers: 第六章 or 第6章.
enum ChapterNumerals { chinese, arabic }

const _digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
const _values = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};
const _units = {'十': 10, '百': 100, '千': 1000, '万': 10000};

/// [n] in Chinese numerals as chapter numbers are written: 十二, 一百零四.
String chineseNumber(int n) {
  if (n <= 0 || n >= 10000) return '$n';
  final out = StringBuffer();
  var zero = false;
  for (final (unit, name) in [(1000, '千'), (100, '百'), (10, '十'), (1, '')]) {
    final d = n ~/ unit % 10;
    if (d == 0) {
      zero = out.isNotEmpty;
      continue;
    }
    if (zero) out.write('零');
    zero = false;
    // 十二, not 一十二, when the tens lead.
    if (!(unit == 10 && d == 1 && out.isEmpty)) out.write(_digits[d]);
    out.write(name);
  }
  return '$out';
}

/// What a chapter is called: 第六章 归途, 第六章 when it has no name, or
/// only its name outside the numbering.
String chapterTitle(int? number, String name, ChapterNumerals numerals) {
  if (number == null) return name;
  final n = numerals == ChapterNumerals.arabic
      ? '$number'
      : chineseNumber(number);
  return name.isEmpty ? '第$n章' : '第$n章 $name';
}

final _heading = RegExp(r'^第\s*([0-9０-９]+|[零〇一二两三四五六七八九十百千万]+)\s*章');
final _separator = RegExp(r'^[\s:：·・\-—–、.．]+');

/// A whole heading taken apart: 第十二章：夜雨 is 12 named 夜雨. A heading
/// that does not open with 第N章 (序章, 卷一 · 第三章 归途) has no number
/// and is its own name.
({int? number, String name, ChapterNumerals? numerals}) splitChapterTitle(
  String title,
) {
  final text = title.trim();
  final match = _heading.firstMatch(text);
  if (match == null) return (number: null, name: text, numerals: null);
  final digits = match[1]!;
  final name = text.substring(match.end).replaceFirst(_separator, '').trim();
  final arabic = int.tryParse(
    String.fromCharCodes([
      // Full-width digits read as ASCII ones.
      for (final c in digits.runes) c >= 0xff10 && c <= 0xff19 ? c - 0xfee0 : c,
    ]),
  );
  if (arabic != null) {
    return (number: arabic, name: name, numerals: ChapterNumerals.arabic);
  }
  var total = 0, digit = 0;
  for (final c in digits.split('')) {
    if (_values[c] case final v?) {
      digit = v;
    } else {
      total += (digit == 0 ? 1 : digit) * _units[c]!;
      digit = 0;
    }
  }
  return (number: total + digit, name: name, numerals: ChapterNumerals.chinese);
}

/// Existing [titles], in order, as numbering and names that show exactly as
/// before: a title joins the numbering only where its 第N章 is the number
/// the order gives it, any other stays outside it as written. An untitled
/// chapter takes the next number, as 第N章 did for it before.
List<({bool numbered, String name})> numberChapterTitles(List<String> titles) {
  final result = <({bool numbered, String name})>[];
  var count = 0;
  for (final title in titles) {
    final split = splitChapterTitle(title);
    if (title.trim().isEmpty || split.number == count + 1) {
      count++;
      result.add((numbered: true, name: split.name));
    } else {
      result.add((numbered: false, name: title.trim()));
    }
  }
  return result;
}

/// The numerals most numbered [titles] use; Chinese when there are none.
ChapterNumerals inferNumerals(Iterable<String> titles) {
  var arabic = 0, chinese = 0;
  for (final title in titles) {
    switch (splitChapterTitle(title).numerals) {
      case ChapterNumerals.arabic:
        arabic++;
      case ChapterNumerals.chinese:
        chinese++;
      case null:
        break;
    }
  }
  return arabic > chinese ? ChapterNumerals.arabic : ChapterNumerals.chinese;
}
