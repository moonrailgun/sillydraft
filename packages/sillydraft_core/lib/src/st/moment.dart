/// The parts of moment 2.30.1 (the version in ST 1.19.0's package-lock.json)
/// that ST's time macros use: `format`, `duration(ms).humanize` and
/// `moment(string)`. ST never changes moment's global locale (lib.js imports
/// plain `moment`; only `timestampToMoment` and reasoning.js set a locale, on
/// their own instances, and `loadLocale` restores the global one), so this is
/// moment's built-in `en` locale. Local time is a fixed UTC offset.
library;

import 'dart:math';

const momentInvalid = 'Invalid date';

/// moment `formattingTokens`.
final _tokens = RegExp(
  r'(\[[^\[]*\])|(\\)?([Hh]mm(ss)?|Mo|MM?M?M?|Do|DDDo|DD?D?D?|ddd?d?|do?|'
  r'w[o|w]?|W[o|W]?|Qo?|N{1,5}|YYYYYY|YYYYY|YYYY|YY|y{2,4}|yo?|gg(ggg?)?|'
  r'GG(GGG?)?|e|E|a|A|hh?|HH?|kk?|mm?|ss?|S{1,9}|x|X|zz?|ZZ?|.)',
);

/// moment `localFormattingTokens` and the `en` long date formats.
final _longTokens = RegExp(r'(\[[^\[]*\])|(\\)?(LTS|LT|LL?L?L?|l{1,4})');
const _long = {
  'LTS': 'h:mm:ss A',
  'LT': 'h:mm A',
  'L': 'MM/DD/YYYY',
  'LL': 'MMMM D, YYYY',
  'LLL': 'MMMM D, YYYY h:mm A',
  'LLLL': 'dddd, MMMM D, YYYY h:mm A',
  'l': 'M/D/YYYY',
  'll': 'MMM D, YYYY',
  'lll': 'MMM D, YYYY h:mm A',
  'llll': 'ddd, MMM D, YYYY h:mm A',
};

final _months =
    ('January February March April May June July August September October '
            'November December')
        .split(' ');
final _weekdays = 'Sunday Monday Tuesday Wednesday Thursday Friday Saturday'
    .split(' ');

/// The JS Date range: ±8.64e15 ms.
const _maxTime = 8640000000000000;

/// moment `format` of the instant [time] (epoch ms) seen [offset] minutes
/// from UTC. An empty [format] is moment's default ISO format; null is
/// where moment throws (a format with nothing but line breaks).
String? momentFormat(int time, num offset, String format) {
  if (format.isEmpty) format = 'YYYY-MM-DDTHH:mm:ssZ';
  final local = time + offset * 60000;
  if (local.abs() > _maxTime) return momentInvalid;
  for (var i = 5; i >= 0 && _longTokens.hasMatch(format); i--) {
    format = format.replaceAllMapped(_longTokens, (m) => _long[m[0]] ?? m[0]!);
  }
  final parts = [for (final m in _tokens.allMatches(format)) m[0]!];
  if (parts.isEmpty) return null;
  final d = DateTime.fromMillisecondsSinceEpoch(local.toInt(), isUtc: true);
  return parts
      .map((t) => _field(d, t, time, offset.toInt()) ?? _text(t))
      .join();
}

/// moment `removeFormattingTokens`.
String _text(String token) => RegExp(r'\[[\s\S]').hasMatch(token)
    ? token.replaceAll(RegExp(r'^\[|\]$'), '')
    : token.replaceAll(r'\', '');

/// moment `formatTokenFunctions` for the `en` locale, or null for a token
/// without one.
String? _field(DateTime d, String token, int time, int offset) {
  final year = d.year, month = d.month - 1, hours = d.hour;
  final day = d.weekday % 7, ms = d.millisecond;
  final dayOfYear = _day(year, d.month, d.day) - _day(year, 1, 1) + 1;
  final week = _weekOfYear(year, dayOfYear, 0, 6);
  final isoWeek = _weekOfYear(year, dayOfYear, 1, 4);
  final era = year >= 1 ? year : 1 - year;
  final h12 = hours % 12 == 0 ? 12 : hours % 12;
  String zone(String separator) {
    final abs = offset.abs();
    return '${offset < 0 ? '-' : '+'}${_fill(abs ~/ 60, 2)}$separator'
        '${_fill(abs % 60, 2)}';
  }

  if (RegExp(r'^S+$').hasMatch(token)) {
    return switch (token.length) {
      1 => '${ms ~/ 100}',
      2 => _fill(ms ~/ 10, 2),
      final n => _fill(ms * pow(10, n - 3).toInt(), n),
    };
  }
  return switch (token) {
    'M' => '${month + 1}',
    'MM' => _fill(month + 1, 2),
    'Mo' => _ordinal(month + 1),
    'MMM' => _months[month].substring(0, 3),
    'MMMM' => _months[month],
    'Q' => '${month ~/ 3 + 1}',
    'Qo' => _ordinal(month ~/ 3 + 1),
    'D' => '${d.day}',
    'DD' => _fill(d.day, 2),
    'Do' => _ordinal(d.day),
    'DDD' => '$dayOfYear',
    'DDDD' => _fill(dayOfYear, 3),
    'DDDo' => _ordinal(dayOfYear),
    'd' || 'e' => '$day',
    'do' => _ordinal(day),
    'dd' => _weekdays[day].substring(0, 2),
    'ddd' => _weekdays[day].substring(0, 3),
    'dddd' => _weekdays[day],
    'E' => '${day == 0 ? 7 : day}',
    'w' => '${week.week}',
    'ww' => _fill(week.week, 2),
    'wo' => _ordinal(week.week),
    'W' => '${isoWeek.week}',
    'WW' => _fill(isoWeek.week, 2),
    'Wo' => _ordinal(isoWeek.week),
    'gg' => _fill(week.year.remainder(100), 2),
    'gggg' => _fill(week.year, 4),
    'ggggg' => _fill(week.year, 5),
    'GG' => _fill(isoWeek.year.remainder(100), 2),
    'GGGG' => _fill(isoWeek.year, 4),
    'GGGGG' => _fill(isoWeek.year, 5),
    'Y' => year <= 9999 ? _fill(year, 4) : '+$year',
    'YY' => _fill(year.remainder(100), 2),
    'YYYY' => _fill(year, 4),
    'YYYYY' => _fill(year, 5),
    'YYYYYY' => _fill(year, 6, sign: true),
    'y' => '$era',
    'yo' => _ordinal(era),
    'yy' || 'yyy' || 'yyyy' => _fill(era, token.length),
    'N' || 'NN' || 'NNN' || 'NNNNN' => year >= 1 ? 'AD' : 'BC',
    'NNNN' => year >= 1 ? 'Anno Domini' : 'Before Christ',
    'a' => hours > 11 ? 'pm' : 'am',
    'A' => hours > 11 ? 'PM' : 'AM',
    'H' => '$hours',
    'HH' => _fill(hours, 2),
    'h' => '$h12',
    'hh' => _fill(h12, 2),
    'k' => '${hours == 0 ? 24 : hours}',
    'kk' => _fill(hours == 0 ? 24 : hours, 2),
    'hmm' => '$h12${_fill(d.minute, 2)}',
    'hmmss' => '$h12${_fill(d.minute, 2)}${_fill(d.second, 2)}',
    'Hmm' => '$hours${_fill(d.minute, 2)}',
    'Hmmss' => '$hours${_fill(d.minute, 2)}${_fill(d.second, 2)}',
    'm' => '${d.minute}',
    'mm' => _fill(d.minute, 2),
    's' => '${d.second}',
    'ss' => _fill(d.second, 2),
    'Z' => zone(':'),
    'ZZ' => zone(''),
    // `zoneAbbr`/`zoneName` are empty for a local moment.
    'z' || 'zz' => '',
    'X' => '${(time / 1000).floor()}',
    'x' => '$time',
    _ => null,
  };
}

/// moment `zeroFill`.
String _fill(int number, int width, {bool sign = false}) =>
    '${number >= 0 ? (sign ? '+' : '') : '-'}'
    '${number.abs().toString().padLeft(width, '0')}';

/// The `en` locale's `ordinal`.
String _ordinal(int number) {
  final b = number.remainder(10);
  final suffix = number.remainder(100) ~/ 10 == 1
      ? 'th'
      : b == 1
      ? 'st'
      : b == 2
      ? 'nd'
      : b == 3
      ? 'rd'
      : 'th';
  return '$number$suffix';
}

/// Days from 1970-01-01 to the date; [day] may run past the month.
int _day(int year, int month, int day) {
  // Howard Hinnant's days_from_civil.
  final y = month <= 2 ? year - 1 : year;
  final era = (y >= 0 ? y : y - 399) ~/ 400;
  final yoe = y - era * 400;
  final doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) ~/ 5;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468 + day - 1;
}

/// JS `getUTCDay` of a day count: 0 is Sunday.
int _weekday(int days) => (days + 4) % 7;

bool _leap(int year) => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
int _daysInYear(int year) => _leap(year) ? 366 : 365;

/// moment `firstWeekOffset`.
int _firstWeekOffset(int year, int dow, int doy) {
  final fwd = 7 + dow - doy;
  return -((7 + _weekday(_day(year, 1, fwd)) - dow) % 7) + fwd - 1;
}

/// moment `weeksInYear`.
int _weeksInYear(int year, int dow, int doy) =>
    (_daysInYear(year) -
        _firstWeekOffset(year, dow, doy) +
        _firstWeekOffset(year + 1, dow, doy)) ~/
    7;

/// moment `weekOfYear`; `en` weeks start on Sunday with [dow] 0 and [doy] 6,
/// ISO weeks with 1 and 4.
({int week, int year}) _weekOfYear(int year, int dayOfYear, int dow, int doy) {
  final week =
      ((dayOfYear - _firstWeekOffset(year, dow, doy) - 1) / 7).floor() + 1;
  if (week < 1) {
    return (week: week + _weeksInYear(year - 1, dow, doy), year: year - 1);
  }
  if (week > _weeksInYear(year, dow, doy)) {
    return (week: week - _weeksInYear(year, dow, doy), year: year + 1);
  }
  return (week: week, year: year);
}

/// moment `duration(ms).humanize(withSuffix)` with the default thresholds
/// and rounding (ST changes neither).
String momentHumanize(num ms, {bool withSuffix = false}) {
  if (ms.isNaN) return momentInvalid;
  final abs = ms.abs();
  final seconds = (abs / 1000).round(), minutes = (abs / 6e4).round();
  final hours = (abs / 36e5).round(), days = (abs / 864e5).round();
  final months = abs / 864e5 * 4800 / 146097;
  final text = seconds <= 44
      ? 'a few seconds'
      : minutes <= 1
      ? 'a minute'
      : minutes < 45
      ? '$minutes minutes'
      : hours <= 1
      ? 'an hour'
      : hours < 22
      ? '$hours hours'
      : days <= 1
      ? 'a day'
      : days < 26
      ? '$days days'
      : months.round() <= 1
      ? 'a month'
      : months.round() < 11
      ? '${months.round()} months'
      : (months / 12).round() <= 1
      ? 'a year'
      : '${(months / 12).round()} years';
  if (!withSuffix) return text;
  return ms > 0 ? 'in $text' : '$text ago';
}

/// `moment(text).valueOf()` with local time [offset] minutes from UTC: epoch
/// ms, NaN where moment finds [text] invalid, or null where moment hands it
/// to the browser's `new Date(text)` (`createFromInputFallback`, which moment
/// itself warns "is not reliable across all browsers and versions").
double? momentParse(String text, int offset) {
  if (text.isEmpty) return double.nan;
  final asp = RegExp(
    r'^\/?Date\((-?\d+)',
    caseSensitive: false,
  ).firstMatch(text);
  if (asp != null) return _clip(double.parse(asp[1]!));
  final iso = _extendedIso.firstMatch(text) ?? _basicIso.firstMatch(text);
  final format = iso == null ? null : _isoFormat(iso);
  if (format != null) return _fromFormat(text, format, offset);
  return _rfc2822(text);
}

double _clip(num time) =>
    time.abs() <= _maxTime ? time.truncateToDouble() : double.nan;

final _extendedIso = RegExp(
  r'^\s*((?:[+-]\d{6}|\d{4})-(?:\d\d-\d\d|W\d\d-\d|W\d\d|\d\d\d|\d\d))'
  r'(?:(T| )(\d\d(?::\d\d(?::\d\d(?:[.,]\d+)?)?)?)([+-]\d\d(?::?\d\d)?|\s*Z)?)?$',
);
final _basicIso = RegExp(
  r'^\s*((?:[+-]\d{6}|\d{4})(?:\d\d\d\d|W\d\d\d|W\d\d|\d\d\d|\d\d|))'
  r'(?:(T| )(\d\d(?:\d\d(?:\d\d(?:[.,]\d+)?)?)?)([+-]\d\d(?::?\d\d)?|\s*Z)?)?$',
);

/// moment `isoDates`: format, pattern, time allowed.
final _isoDates = [
  ('YYYYYY-MM-DD', RegExp(r'[+-]\d{6}-\d\d-\d\d'), true),
  ('YYYY-MM-DD', RegExp(r'\d{4}-\d\d-\d\d'), true),
  ('GGGG-[W]WW-E', RegExp(r'\d{4}-W\d\d-\d'), true),
  ('GGGG-[W]WW', RegExp(r'\d{4}-W\d\d'), false),
  ('YYYY-DDD', RegExp(r'\d{4}-\d{3}'), true),
  ('YYYY-MM', RegExp(r'\d{4}-\d\d'), false),
  ('YYYYYYMMDD', RegExp(r'[+-]\d{10}'), true),
  ('YYYYMMDD', RegExp(r'\d{8}'), true),
  ('GGGG[W]WWE', RegExp(r'\d{4}W\d{3}'), true),
  ('GGGG[W]WW', RegExp(r'\d{4}W\d{2}'), false),
  ('YYYYDDD', RegExp(r'\d{7}'), true),
  ('YYYYMM', RegExp(r'\d{6}'), false),
  ('YYYY', RegExp(r'\d{4}'), false),
];
final _isoTimes = [
  ('HH:mm:ss.SSSS', RegExp(r'\d\d:\d\d:\d\d\.\d+')),
  ('HH:mm:ss,SSSS', RegExp(r'\d\d:\d\d:\d\d,\d+')),
  ('HH:mm:ss', RegExp(r'\d\d:\d\d:\d\d')),
  ('HH:mm', RegExp(r'\d\d:\d\d')),
  ('HHmmss.SSSS', RegExp(r'\d\d\d\d\d\d\.\d+')),
  ('HHmmss,SSSS', RegExp(r'\d\d\d\d\d\d,\d+')),
  ('HHmmss', RegExp(r'\d\d\d\d\d\d')),
  ('HHmm', RegExp(r'\d\d\d\d')),
  ('HH', RegExp(r'\d\d')),
];

/// moment `configFromISO`: the format for an ISO match, or null where it
/// marks the input invalid and parsing moves on to RFC 2822.
String? _isoFormat(RegExpMatch match) {
  final date = _isoDates.where((d) => d.$2.hasMatch(match[1]!)).firstOrNull;
  if (date == null) return null;
  var time = '';
  if (match[3] != null) {
    final found = _isoTimes.where((t) => t.$2.hasMatch(match[3]!)).firstOrNull;
    if (found == null || !date.$3) return null;
    time = '${match[2] ?? ' '}${found.$1}';
  }
  return '${date.$1}$time${match[4] == null ? '' : 'Z'}';
}

/// The non-strict parse patterns of the tokens in ISO formats.
final _parsePatterns = {
  'YYYY': RegExp(r'\d{1,4}'),
  'YYYYYY': RegExp(r'[+-]?\d{1,6}'),
  'GGGG': RegExp(r'\d{1,4}'),
  'DDD': RegExp(r'\d{1,3}'),
  'SSSS': RegExp(r'\d+'),
  'Z': RegExp(r'Z|[+-]\d\d(?::?\d\d)?', caseSensitive: false),
  for (final token in ['MM', 'DD', 'WW', 'E', 'HH', 'mm', 'ss'])
    token: RegExp(r'\d\d?'),
};

/// moment `configFromStringAndFormat`, `configFromArray` and
/// `checkOverflow` for the ISO formats, non-strict as `moment(text)` is.
double _fromFormat(String input, String format, int offset) {
  // year, month, date, hour, minute, second, millisecond
  final a = List<int?>.filled(7, null);
  final week = <String, int>{};
  int? dayOfYear, zone;
  var rest = input;
  for (final match in _tokens.allMatches(format)) {
    final token = match[0]!;
    final pattern =
        _parsePatterns[token] ??
        RegExp(RegExp.escape(token.replaceAll(RegExp(r'^\[|\]$'), '')));
    final parsed = pattern.firstMatch(rest)?[0];
    if (parsed == null || parsed.isEmpty) continue;
    rest = rest.substring(rest.indexOf(parsed) + parsed.length);
    final value = int.tryParse(parsed) ?? 0;
    switch (token) {
      case 'YYYY':
        a[0] = parsed.length == 2 ? value + (value > 68 ? 1900 : 2000) : value;
      case 'YYYYYY':
        a[0] = value;
      case 'MM':
        a[1] = value - 1;
      case 'DD':
        a[2] = value;
      case 'DDD':
        dayOfYear = value;
      case 'GGGG':
        week['GG'] = value;
      case 'WW':
        week['W'] = value;
      case 'E':
        week['E'] = value;
      case 'HH':
        a[3] = value;
      case 'mm':
        a[4] = value;
      case 'ss':
        a[5] = value;
      case 'SSSS':
        a[6] = (double.parse('0.$parsed') * 1000).truncate();
      case 'Z':
        // `offsetFromString`: `Z` is 0, `+05` five hours.
        final parts = RegExp(r'[+-]|\d\d').allMatches(parsed).toList();
        final minutes = parts.length < 2
            ? 0
            : int.parse(parts[1][0]!) * 60 +
                  (parts.length > 2 ? int.parse(parts[2][0]!) : 0);
        zone = parts.isNotEmpty && parts[0][0] == '-' ? -minutes : minutes;
    }
  }
  if (week.isNotEmpty && a[1] == null && a[2] == null) {
    // `dayOfYearFromWeekInfo` with ISO weeks; every ISO week format has the
    // week year.
    final year = week['GG']!, w = week['W'] ?? 1, weekday = week['E'] ?? 1;
    if (w < 1 || w > _weeksInYear(year, 1, 4) || weekday < 1 || weekday > 7) {
      return double.nan;
    }
    var day = 1 + 7 * (w - 1) + (6 + weekday) % 7;
    day += _firstWeekOffset(year, 1, 4);
    a[0] = year;
    dayOfYear = day;
    if (day <= 0) {
      a[0] = year - 1;
      dayOfYear = _daysInYear(year - 1) + day;
    } else if (day > _daysInYear(year)) {
      a[0] = year + 1;
      dayOfYear = day - _daysInYear(year);
    }
  }
  final year = a[0]!;
  if (dayOfYear != null) {
    if (dayOfYear > _daysInYear(year) || dayOfYear == 0) return double.nan;
    // `createUTCDate(year, 0, dayOfYear)`.
    var month = 1;
    while (_day(year, month + 1, 1) - _day(year, 1, 1) < dayOfYear) {
      month++;
    }
    a[1] = month - 1;
    a[2] = dayOfYear - (_day(year, month, 1) - _day(year, 1, 1));
  }
  final [_, month, date, hour, minute, second, ms] = [
    for (final (i, v) in a.indexed) v ?? (i == 2 ? 1 : 0),
  ];
  final midnight = hour == 24 && minute == 0 && second == 0 && ms == 0;
  if (month < 0 ||
      month > 11 ||
      date < 1 ||
      date > _day(year, month + 2, 1) - _day(year, month + 1, 1) ||
      hour < 0 ||
      (hour > 23 && !midnight) ||
      minute < 0 ||
      minute > 59 ||
      second < 0 ||
      second > 59 ||
      ms < 0 ||
      ms > 999) {
    return double.nan;
  }
  // `createDate` (local) or `createUTCDate`, then the zone. Both get the
  // hour as parsed, so 24:00 is the next day, and for a year below 100 they
  // set the year back afterwards: 0099-12-31T24:00 is 0099-01-01.
  var fields =
      (_day(year, month + 1, date) * 24 + hour) * 3600000 +
      minute * 60000 +
      second * 1000 +
      ms;
  if (midnight && month == 11 && date == 31 && year >= 0 && year < 100) {
    fields -= _daysInYear(year) * 86400000;
  }
  if (zone == null) return _clip(fields - offset * 60000);
  if (fields.abs() > _maxTime) return double.nan;
  return _clip(fields - zone * 60000);
}

final _rfc = RegExp(
  r'^(?:(Mon|Tue|Wed|Thu|Fri|Sat|Sun),?\s)?(\d{1,2})\s'
  r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s(\d{2,4})\s'
  r'(\d\d):(\d\d)(?::(\d\d))?\s(?:(UT|GMT|[ECMP][SD]T)|([Zz])|([+-]\d{4}))$',
);
const _obsOffsets = {
  'UT': 0,
  'GMT': 0,
  'EDT': -4 * 60,
  'EST': -5 * 60,
  'CDT': -5 * 60,
  'CST': -6 * 60,
  'MDT': -6 * 60,
  'MST': -7 * 60,
  'PDT': -7 * 60,
  'PST': -8 * 60,
};

/// moment `configFromRFC2822` and `checkOverflow`: null where it moves on to
/// the browser (no match, or a weekday that is not the date's).
double? _rfc2822(String text) {
  final match = _rfc.firstMatch(
    text
        .replaceAll(RegExp(r'\([^()]*\)|[\n\t]'), ' ')
        .replaceAll(RegExp(r'(\s\s+)'), ' ')
        .replaceFirst(RegExp(r'^\s\s*'), '')
        .replaceFirst(RegExp(r'\s\s*$'), ''),
  );
  if (match == null) return null;
  final short = int.parse(match[4]!);
  final year = short <= 49
      ? 2000 + short
      : short <= 999
      ? 1900 + short
      : short;
  final month = _months.indexWhere((m) => m.startsWith(match[3]!));
  final date = int.parse(match[2]!);
  final hour = int.parse(match[5]!), minute = int.parse(match[6]!);
  final second = match[7] == null ? null : int.parse(match[7]!);
  final days = _day(year, month + 1, date);
  if (match[1] != null &&
      _weekdays.indexWhere((d) => d.startsWith(match[1]!)) != _weekday(days)) {
    return null;
  }
  // No milliseconds are parsed, so 24:00 overflows too.
  if (date < 1 ||
      date > _day(year, month + 2, 1) - _day(year, month + 1, 1) ||
      hour > 23 ||
      minute > 59 ||
      (second ?? 0) > 59) {
    return double.nan;
  }
  final zone = match[8] != null
      ? _obsOffsets[match[8]]!
      : match[9] != null
      ? 0
      : _numericZone(int.parse(match[10]!));
  return _clip(
    days * 864e5 +
        hour * 36e5 +
        minute * 6e4 +
        (second ?? 0) * 1000 -
        zone * 6e4,
  );
}

/// moment `calculateOffset` for `+hhmm`.
int _numericZone(int hm) {
  final m = hm.remainder(100);
  return (hm - m) ~/ 100 * 60 + m;
}
