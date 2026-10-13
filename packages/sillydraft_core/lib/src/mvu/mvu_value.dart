import 'dart:convert';
import 'dart:math' as math;

import 'package:yaml/yaml.dart';

/// Parsing of the literals MVU update commands carry, following
/// MagVarUpdate's `parseCommandValue`, `parseParameters`, `pathFix` and
/// `parseString`: JSON first, then relaxed JSON5 data literals, single
/// quoted text, pure arithmetic, YAML, and finally the bare string.
abstract final class MvuValue {
  /// Converts a command argument to a value. Arithmetic uses a small safe
  /// evaluator (no assignment, no host access); dates like `2025-01-01`
  /// stay strings rather than evaluating as subtraction.
  static Object? parseCommandValue(String raw) {
    final trimmed = raw.trim();
    switch (trimmed) {
      case 'true':
        return true;
      case 'false':
        return false;
      case 'null' || 'undefined':
        return null;
    }
    try {
      return jsonDecode(trimmed);
    } on FormatException {
      if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
          (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
        try {
          final result = parseJson5(trimmed);
          if (result is Map || result is List) return result;
        } on FormatException {
          // Not a data literal either; fall through.
        }
      }
    }
    if (trimmed.length >= 2 &&
        trimmed.startsWith("'") &&
        trimmed.endsWith("'")) {
      try {
        return parseYaml(trimmed);
      } on FormatException {
        // Keep trying the other forms.
      }
    }
    final number = MvuExpression.tryEvaluate(trimmed);
    if (number != null) return number;
    try {
      return parseYaml(trimmed);
    } on FormatException {
      // Not YAML; return the bare text.
    }
    return trimQuotesAndBackslashes(raw);
  }

  /// Strips backslashes, quotes and spaces from both ends. Multi-line text
  /// is returned unchanged, as the original regex only matches one line.
  static String trimQuotesAndBackslashes(String text) {
    final match = RegExp('''^[\\\\"'` ]*(.*?)[\\\\"'` ]*\$''').firstMatch(text);
    return match == null ? text : match.group(1)!;
  }

  /// Splits a command's argument list on top-level commas, keeping quoted
  /// strings and nested brackets intact.
  static List<String> parseParameters(String source) {
    final params = <String>[];
    final current = StringBuffer();
    var inQuote = false;
    var quote = '';
    var brackets = 0, braces = 0, parens = 0;
    for (var i = 0; i < source.length; i++) {
      final char = source[i];
      if ((char == '"' || char == "'" || char == '`') &&
          (i == 0 || source[i - 1] != r'\')) {
        if (!inQuote) {
          inQuote = true;
          quote = char;
        } else if (char == quote) {
          inQuote = false;
        }
      }
      if (!inQuote) {
        if (char == '(') parens++;
        if (char == ')') parens--;
        if (char == '[') brackets++;
        if (char == ']') brackets--;
        if (char == '{') braces++;
        if (char == '}') braces--;
      }
      if (char == ',' &&
          !inQuote &&
          parens == 0 &&
          brackets == 0 &&
          braces == 0) {
        params.add(current.toString().trim());
        current.clear();
        continue;
      }
      current.write(char);
    }
    if (current.toString().trim().isNotEmpty) {
      params.add(current.toString().trim());
    }
    return params;
  }

  /// Normalises a model-written path: quoted dotted segments lose their
  /// quotes, bracket keys with spaces are quoted, bare numbers stay indexes.
  static String pathFix(String path) {
    if (path.isEmpty) return path;
    final fixedBrackets = path.replaceAllMapped(RegExp(r'\[([^\]]*)\]'), (m) {
      var inner = m.group(1)!.trim();
      if (inner.isEmpty) return '[]';
      var wasQuoted = false;
      final first = inner[0], last = inner[inner.length - 1];
      if (inner.length >= 2 &&
          (first == '"' || first == "'") &&
          first == last) {
        wasQuoted = true;
        inner = inner.substring(1, inner.length - 1);
      }
      final pureDigits = RegExp(r'^\d+$').hasMatch(inner);
      final hasWhitespace = RegExp(r'\s').hasMatch(inner);
      if (pureDigits) {
        if (!wasQuoted) return '[$inner]';
        return '["${inner.replaceAll('"', r'\"')}"]';
      }
      if (hasWhitespace) return '["${inner.replaceAll('"', r'\"')}"]';
      return '[$inner]';
    });
    return fixedBrackets.replaceAllMapped(
      RegExp('''(^|\\.)(["'])([^"']*)\\2(?=\\.|\\[|\$)'''),
      (m) {
        final prefix = m.group(1)!, name = m.group(3)!;
        final hasWhitespace = RegExp(r'\s').hasMatch(name);
        final hasSpecial = RegExp(r'[.\[\]]').hasMatch(name);
        if (!hasWhitespace && !hasSpecial) return '$prefix$name';
        final escaped = name.replaceAll('"', r'\"');
        return prefix == '.' ? '["$escaped"]' : '$prefix["$escaped"]';
      },
    );
  }

  /// MVU's `parseString`: YAML (which covers JSON) unless the text looks
  /// like JSON, in which case relaxed JSON is tried first. Throws
  /// [FormatException] when nothing parses.
  static Object? parseStructured(String content) {
    final jsonFirst = RegExp(r'^[\[{]').hasMatch(content.trimLeft());
    final errors = <String>[];
    if (!jsonFirst) {
      try {
        return parseYaml(content);
      } on FormatException catch (e) {
        errors.add('YAML: ${e.message}');
      }
    }
    try {
      return parseJson5(content);
    } on FormatException catch (e) {
      errors.add('JSON: ${e.message}');
    }
    if (jsonFirst) {
      try {
        return parseYaml(content);
      } on FormatException catch (e) {
        errors.add('YAML: ${e.message}');
      }
    }
    throw FormatException('无法解析变量内容：${errors.join('；')}');
  }

  /// YAML to plain Dart data (maps keyed by strings). Throws
  /// [FormatException] on invalid YAML.
  static Object? parseYaml(String content) {
    try {
      return _plain(loadYaml(content));
    } on YamlException catch (e) {
      throw FormatException(e.message);
    } on ArgumentError catch (e) {
      throw FormatException(e.message.toString());
    }
  }

  static Object? _plain(Object? value) => switch (value) {
    YamlMap m => <String, dynamic>{
      for (final entry in m.entries) '${entry.key}': _plain(entry.value),
    },
    Map m => <String, dynamic>{
      for (final entry in m.entries) '${entry.key}': _plain(entry.value),
    },
    YamlList l => l.map(_plain).toList(),
    List l => l.map(_plain).toList(),
    YamlScalar s => _plain(s.value),
    _ => value,
  };

  /// Relaxed JSON: comments, trailing commas, single quotes, unquoted keys,
  /// `+`/hex numbers, `Infinity`/`NaN` (as null). Throws [FormatException].
  static Object? parseJson5(String source) {
    final parser = _Json5Parser(source);
    final value = parser.value();
    parser.skipWhitespace();
    if (!parser.atEnd) throw parser.error('多余的内容');
    return value;
  }
}

final class _Json5Parser {
  _Json5Parser(this.source);
  final String source;
  int _i = 0;
  bool get atEnd => _i >= source.length;

  FormatException error(String message) => FormatException('$message（位置 $_i）');

  void skipWhitespace() {
    while (_i < source.length) {
      final char = source[_i];
      if (char == ' ' ||
          char == '\n' ||
          char == '\r' ||
          char == '\t' ||
          char == ' ' ||
          char == '﻿') {
        _i++;
      } else if (source.startsWith('//', _i)) {
        final end = source.indexOf('\n', _i);
        _i = end < 0 ? source.length : end + 1;
      } else if (source.startsWith('/*', _i)) {
        final end = source.indexOf('*/', _i + 2);
        if (end < 0) throw error('块注释未闭合');
        _i = end + 2;
      } else {
        break;
      }
    }
  }

  Object? value() {
    skipWhitespace();
    if (atEnd) throw error('内容为空');
    final char = source[_i];
    if (char == '{') return _object();
    if (char == '[') return _array();
    if (char == '"' || char == "'") return _string();
    if (source.startsWith('true', _i)) {
      _i += 4;
      return true;
    }
    if (source.startsWith('false', _i)) {
      _i += 5;
      return false;
    }
    if (source.startsWith('null', _i)) {
      _i += 4;
      return null;
    }
    if (source.startsWith('undefined', _i)) {
      _i += 9;
      return null;
    }
    return _number();
  }

  Map<String, dynamic> _object() {
    final result = <String, dynamic>{};
    _i++;
    while (true) {
      skipWhitespace();
      if (atEnd) throw error('对象未闭合');
      if (source[_i] == '}') {
        _i++;
        return result;
      }
      final String key;
      if (source[_i] == '"' || source[_i] == "'") {
        key = _string();
      } else {
        final match = RegExp(
          r'[\p{L}\p{N}_$\-]+',
          unicode: true,
        ).matchAsPrefix(source, _i);
        if (match == null) throw error('对象键无效');
        key = match.group(0)!;
        _i = match.end;
      }
      skipWhitespace();
      if (atEnd || source[_i] != ':') throw error('缺少冒号');
      _i++;
      result[key] = value();
      skipWhitespace();
      if (atEnd) throw error('对象未闭合');
      if (source[_i] == ',') {
        _i++;
      } else if (source[_i] != '}') {
        throw error('缺少逗号');
      }
    }
  }

  List<Object?> _array() {
    final result = <Object?>[];
    _i++;
    while (true) {
      skipWhitespace();
      if (atEnd) throw error('数组未闭合');
      if (source[_i] == ']') {
        _i++;
        return result;
      }
      result.add(value());
      skipWhitespace();
      if (atEnd) throw error('数组未闭合');
      if (source[_i] == ',') {
        _i++;
      } else if (source[_i] != ']') {
        throw error('缺少逗号');
      }
    }
  }

  String _string() {
    final quote = source[_i++];
    final buffer = StringBuffer();
    while (true) {
      if (atEnd) throw error('字符串未闭合');
      final char = source[_i++];
      if (char == quote) return buffer.toString();
      if (char != r'\') {
        buffer.write(char);
        continue;
      }
      if (atEnd) throw error('字符串未闭合');
      final escaped = source[_i++];
      switch (escaped) {
        case 'n':
          buffer.write('\n');
        case 'r':
          buffer.write('\r');
        case 't':
          buffer.write('\t');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case 'v':
          buffer.write('\v');
        case '0':
          buffer.write('\u0000');
        case '\n':
          break;
        case 'u':
          final hex = source.substring(_i, math.min(_i + 4, source.length));
          final code = int.tryParse(hex, radix: 16);
          if (code == null || hex.length < 4) throw error('无效的 Unicode 转义');
          buffer.writeCharCode(code);
          _i += 4;
        case 'x':
          final hex = source.substring(_i, math.min(_i + 2, source.length));
          final code = int.tryParse(hex, radix: 16);
          if (code == null || hex.length < 2) throw error('无效的十六进制转义');
          buffer.writeCharCode(code);
          _i += 2;
        default:
          buffer.write(escaped);
      }
    }
  }

  Object? _number() {
    final match = RegExp(
      r'[+-]?(?:Infinity|NaN|0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)',
    ).matchAsPrefix(source, _i);
    if (match == null) throw error('无法识别的值');
    _i = match.end;
    var text = match.group(0)!;
    if (text.contains('Infinity') || text.contains('NaN')) return null;
    final negative = text.startsWith('-');
    if (text.startsWith('+') || negative) text = text.substring(1);
    if (text.startsWith('0x') || text.startsWith('0X')) {
      final v = int.parse(text.substring(2), radix: 16);
      return negative ? -v : v;
    }
    final v = num.parse(text);
    return negative ? -v : v;
  }
}

/// A safe arithmetic evaluator standing in for mathjs: numbers, `+ - * / %
/// ^`, parentheses and a fixed set of functions and constants, optionally
/// spelled `Math.x` or `math.x`. Anything else is not an expression.
abstract final class MvuExpression {
  static final _allowed = RegExp(r'^[\d\s+\-*/%^().,A-Za-z_]+$');
  static final _dateLike = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}');

  /// The numeric value, or null when [text] is not a pure expression.
  static num? tryEvaluate(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        !_allowed.hasMatch(trimmed) ||
        _dateLike.hasMatch(trimmed) ||
        !RegExp(r'\d|\b(pi|e|tau|PI|E)\b').hasMatch(trimmed)) {
      return null;
    }
    try {
      final parser = _ExpressionParser(trimmed);
      final value = parser.expression();
      parser.skip();
      if (!parser.atEnd) return null;
      if (value.isNaN || value.isInfinite) return null;
      return _round(value);
    } on FormatException {
      return null;
    }
  }

  /// Mirrors `parseFloat(result.toPrecision(12))`.
  static num _round(double value) {
    final rounded = double.parse(value.toStringAsPrecision(12));
    return rounded == rounded.truncateToDouble() && rounded.abs() < 1e15
        ? rounded.toInt()
        : rounded;
  }

  static const _constants = {
    'pi': math.pi,
    'PI': math.pi,
    'e': math.e,
    'E': math.e,
    'tau': 2 * math.pi,
    'SQRT2': math.sqrt2,
    'LN2': math.ln2,
    'LN10': math.ln10,
  };

  static double? _call(String name, List<double> args) {
    double one() {
      if (args.length != 1) throw const FormatException('参数数量错误');
      return args.single;
    }

    switch (name) {
      case 'abs':
        return one().abs();
      case 'ceil':
        return one().ceilToDouble();
      case 'floor':
        return one().floorToDouble();
      case 'round':
        return one().roundToDouble();
      case 'trunc' || 'fix':
        return one().truncateToDouble();
      case 'sign':
        return one().sign;
      case 'sqrt':
        return math.sqrt(one());
      case 'cbrt':
        final v = one();
        return v < 0
            ? -math.pow(-v, 1 / 3).toDouble()
            : math.pow(v, 1 / 3).toDouble();
      case 'exp':
        return math.exp(one());
      case 'log':
        if (args.length == 2) return math.log(args[0]) / math.log(args[1]);
        return math.log(one());
      case 'log10':
        return math.log(one()) / math.ln10;
      case 'log2':
        return math.log(one()) / math.ln2;
      case 'sin':
        return math.sin(one());
      case 'cos':
        return math.cos(one());
      case 'tan':
        return math.tan(one());
      case 'asin':
        return math.asin(one());
      case 'acos':
        return math.acos(one());
      case 'atan':
        return math.atan(one());
      case 'atan2':
        if (args.length != 2) throw const FormatException('参数数量错误');
        return math.atan2(args[0], args[1]);
      case 'pow':
        if (args.length != 2) throw const FormatException('参数数量错误');
        return math.pow(args[0], args[1]).toDouble();
      case 'mod':
        if (args.length != 2) throw const FormatException('参数数量错误');
        return args[0] % args[1];
      case 'min':
        if (args.isEmpty) throw const FormatException('参数数量错误');
        return args.reduce(math.min);
      case 'max':
        if (args.isEmpty) throw const FormatException('参数数量错误');
        return args.reduce(math.max);
      case 'sum':
        return args.fold<double>(0.0, (a, b) => a + b);
      case 'mean':
        if (args.isEmpty) throw const FormatException('参数数量错误');
        return args.fold<double>(0.0, (a, b) => a + b) / args.length;
      case 'hypot':
        return math.sqrt(args.fold<double>(0.0, (a, b) => a + b * b));
      case 'clamp':
        if (args.length != 3) throw const FormatException('参数数量错误');
        return args[0].clamp(args[1], args[2]).toDouble();
      case 'random':
        throw const FormatException('不支持随机数');
    }
    return null;
  }
}

final class _ExpressionParser {
  _ExpressionParser(this.source);
  final String source;
  int _i = 0;
  bool get atEnd => _i >= source.length;

  void skip() {
    while (!atEnd && RegExp(r'\s').hasMatch(source[_i])) {
      _i++;
    }
  }

  double expression() {
    var left = term();
    while (true) {
      skip();
      if (atEnd) return left;
      final char = source[_i];
      if (char == '+') {
        _i++;
        left += term();
      } else if (char == '-') {
        _i++;
        left -= term();
      } else {
        return left;
      }
    }
  }

  double term() {
    var left = unary();
    while (true) {
      skip();
      if (atEnd) return left;
      final char = source[_i];
      if (char == '*') {
        _i++;
        left *= unary();
      } else if (char == '/') {
        _i++;
        left /= unary();
      } else if (char == '%') {
        _i++;
        left %= unary();
      } else {
        return left;
      }
    }
  }

  double unary() {
    skip();
    if (!atEnd && source[_i] == '-') {
      _i++;
      return -unary();
    }
    if (!atEnd && source[_i] == '+') {
      _i++;
      return unary();
    }
    return power();
  }

  double power() {
    final base = primary();
    skip();
    if (!atEnd && source[_i] == '^') {
      _i++;
      return math.pow(base, unary()).toDouble();
    }
    return base;
  }

  double primary() {
    skip();
    if (atEnd) throw const FormatException('表达式不完整');
    final char = source[_i];
    if (char == '(') {
      _i++;
      final value = expression();
      skip();
      if (atEnd || source[_i] != ')') throw const FormatException('括号未闭合');
      _i++;
      return value;
    }
    final number = RegExp(r'(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?')
        .matchAsPrefix(source, _i);
    if (number != null) {
      _i = number.end;
      return double.parse(number.group(0)!);
    }
    final ident = RegExp(r'[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?')
        .matchAsPrefix(source, _i);
    if (ident == null) throw const FormatException('无法识别的符号');
    _i = ident.end;
    var name = ident.group(0)!;
    if (name.startsWith('Math.') || name.startsWith('math.')) {
      name = name.substring(5);
    } else if (name.contains('.')) {
      throw const FormatException('未知命名空间');
    }
    skip();
    if (!atEnd && source[_i] == '(') {
      _i++;
      final args = <double>[];
      skip();
      if (!atEnd && source[_i] == ')') {
        _i++;
      } else {
        while (true) {
          args.add(expression());
          skip();
          if (atEnd) throw const FormatException('括号未闭合');
          if (source[_i] == ',') {
            _i++;
            continue;
          }
          if (source[_i] == ')') {
            _i++;
            break;
          }
          throw const FormatException('参数格式错误');
        }
      }
      final result = MvuExpression._call(name, args);
      if (result == null) throw FormatException('未知函数：$name');
      return result;
    }
    final constant = MvuExpression._constants[name];
    if (constant == null) throw FormatException('未知符号：$name');
    return constant;
  }
}

/// YAML output matching the `yaml` npm package's defaults closely enough
/// for prompts: two-space indents, `- ` lists, literal blocks for multi-line
/// strings, plain scalars when unambiguous.
abstract final class MvuYaml {
  /// `YAML.stringify(value, { blockQuote: 'literal' })` without the trailing
  /// newline. With [quoteStrings], every string is double-quoted.
  static String stringify(Object? value, {bool quoteStrings = false}) {
    final buffer = StringBuffer();
    _write(buffer, value, 0, quoteStrings, inList: false);
    return buffer.toString().trimRight();
  }

  static void _write(
    StringBuffer out,
    Object? value,
    int indent,
    bool quote, {
    required bool inList,
  }) {
    final pad = ' ' * indent;
    if (value is Map) {
      if (value.isEmpty) {
        out.writeln('{}');
        return;
      }
      var first = true;
      for (final entry in value.entries) {
        final key = _key('${entry.key}');
        if (!(first && inList)) out.write(pad);
        first = false;
        final child = entry.value;
        if ((child is Map && child.isNotEmpty) ||
            (child is List && child.isNotEmpty)) {
          out.writeln('$key:');
          _write(out, child, indent + 2, quote, inList: false);
        } else if (child is String && _isMultiline(child)) {
          out.writeln('$key: ${_blockHeader(child)}');
          _writeBlock(out, child, indent + 2);
        } else {
          out.write('$key: ');
          _writeScalar(out, child, quote);
          out.writeln();
        }
      }
      return;
    }
    if (value is List) {
      if (value.isEmpty) {
        out.writeln('[]');
        return;
      }
      var first = true;
      for (final item in value) {
        if (!(first && inList)) out.write(pad);
        first = false;
        if ((item is Map && item.isNotEmpty) ||
            (item is List && item.isNotEmpty)) {
          out.write('- ');
          _write(out, item, indent + 2, quote, inList: true);
        } else if (item is String && _isMultiline(item)) {
          out.writeln('- ${_blockHeader(item)}');
          _writeBlock(out, item, indent + 2);
        } else {
          out.write('- ');
          _writeScalar(out, item, quote);
          out.writeln();
        }
      }
      return;
    }
    if (value is String && _isMultiline(value)) {
      out.writeln(_blockHeader(value));
      _writeBlock(out, value, indent);
      return;
    }
    _writeScalar(out, value, quote);
    out.writeln();
  }

  static bool _isMultiline(String s) => s.contains('\n');

  static String _blockHeader(String s) {
    final trailing = s.length - s.trimRight().length;
    final newlines = s.substring(s.length - trailing).split('\n').length - 1;
    final indicator = newlines == 0
        ? '-'
        : newlines == 1
        ? ''
        : '+';
    final needsIndent = s.startsWith(' ') || s.startsWith('\n');
    return '|${needsIndent ? '2' : ''}$indicator';
  }

  static void _writeBlock(StringBuffer out, String s, int indent) {
    final pad = ' ' * indent;
    final lines = s.split('\n');
    final trailingEmpty = s.endsWith('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i == lines.length - 1 && trailingEmpty && lines[i].isEmpty) break;
      out.writeln(lines[i].isEmpty ? '' : '$pad${lines[i]}');
    }
  }

  static String _key(String key) =>
      key.isEmpty || _needsQuotes(key) ? jsonEncode(key) : key;

  static void _writeScalar(StringBuffer out, Object? value, bool quote) {
    switch (value) {
      case null:
        out.write('null');
      case bool b:
        out.write(b);
      case num n:
        out.write(
          n is double && n == n.truncateToDouble() && n.abs() < 1e15
              ? n.toInt()
              : n,
        );
      case String s:
        out.write(quote || _needsQuotes(s) ? jsonEncode(s) : s);
      default:
        out.write(jsonEncode(value));
    }
  }

  static final _ambiguous = RegExp(
    r'''^(?:[-?:,\[\]{}#&*!|>'"%@`]|\s|$)|: |\s#|:$|^\s|\s$|^(?:true|false|null|~|yes|no|on|off|\.inf|-\.inf|\.nan)$|^[-+]?(?:\d[\d_]*\.?[\d_]*(?:[eE][-+]?\d+)?|0x[0-9a-fA-F]+|0o[0-7]+|\.\d+)$|^\d+:\d+''',
    caseSensitive: false,
  );

  static bool _needsQuotes(String s) =>
      s.isEmpty || _ambiguous.hasMatch(s) || s.contains('\t');
}
