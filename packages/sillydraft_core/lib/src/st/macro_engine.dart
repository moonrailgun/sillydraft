import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'import_types.dart';
import 'variable_codec.dart';

/// A task-local evaluator. Mutations are returned with the proposal, never
/// committed by previewing or compiling a request.
final class MacroEngine {
  MacroEngine({
    required Map<String, String> values,
    required this.clock,
    required int seed,
    Map<String, String> local = const {},
    Map<String, String> global = const {},
  }) : values = Map.of(values),
       local = Map.of(local),
       global = Map.of(global),
       _random = Random(seed),
       _seed = seed;
  final Map<String, String> values, local, global;
  final DateTime clock;
  final Random _random;
  final int _seed;
  final diagnostics = <CompatibilityDiagnostic>[];
  int _operations = 0;

  String render(String source, {String Function(String)? transform}) {
    if (source.length > 2 * 1024 * 1024) throw const FormatException('宏输入过长');
    final result = _render(source, 0, transform);
    return result.replaceAll(
      RegExp(r'\n*\{\{trim\}\}\n*', caseSensitive: false),
      '',
    );
  }

  String _render(String source, int level, String Function(String)? transform) {
    if (level > 32) throw const FormatException('宏嵌套过深');
    final out = StringBuffer();
    var cursor = 0;
    while (cursor < source.length) {
      final start = source.indexOf('{{', cursor);
      if (start < 0) {
        out.write(source.substring(cursor));
        break;
      }
      out.write(source.substring(cursor, start));
      final token = _token(source, start);
      if (token == null) {
        diagnostics.add(
          const CompatibilityDiagnostic(
            'unclosed_macro',
            '宏缺少结束括号',
            severity: DiagnosticSeverity.error,
          ),
        );
        out.write(source.substring(start));
        break;
      }
      if (++_operations > 10000) throw const FormatException('宏计算次数超出限制');
      final parsed = _arguments(token.body);
      final name = parsed.$1.toLowerCase();
      final args = parsed.$2;
      cursor = token.end;
      String value;
      if ((name == 'if' && args.length == 1) || name == 'trim') {
        final block = _block(source, cursor, name);
        if (block != null) {
          cursor = block.end;
          if (name == 'if') {
            value = _render(
              _condition(args.single, level) ? block.yes : block.no,
              level + 1,
              null,
            ).trim();
          } else {
            value = _render(block.yes, level + 1, null).trim();
          }
        } else if (name == 'trim') {
          value = '{{trim}}';
        } else {
          value = _unknown(token.body, '缺少 {{/if}}');
        }
      } else if (name == 'if' && args.length >= 2) {
        value = _render(
          _condition(args.first, level)
              ? args[1]
              : (args.length > 2 ? args[2] : ''),
          level + 1,
          null,
        ).trim();
      } else {
        value = _evaluate(
          name,
          args.map((s) => _render(s, level + 1, null)).toList(),
          token.body,
          start,
          prefix: name.startsWith('format_') ? _linePrefix(out) : '',
        );
      }
      out.write(transform == null ? value : transform(value));
      if (out.length > 2 * 1024 * 1024) throw const FormatException('宏输出过长');
    }
    return out.toString();
  }

  bool _condition(String source, int level) {
    var condition = source.trim();
    final negate = condition.startsWith('!');
    if (negate) condition = condition.substring(1).trimLeft();
    condition = _render(condition, level + 1, null);
    if (condition.startsWith('.')) {
      condition = local[condition.substring(1)] ?? '';
    } else if (condition.startsWith(r'$')) {
      condition = global[condition.substring(1)] ?? '';
    } else {
      condition = values[condition.toLowerCase()] ?? condition;
    }
    final truth =
        condition.isNotEmpty &&
        !['false', '0', 'off', 'no'].contains(condition.toLowerCase());
    return negate ? !truth : truth;
  }

  /// Text already written on the current output line, which 酒馆助手's
  /// `format_*_variable` macros use to indent multi-line YAML.
  static String _linePrefix(StringBuffer out) {
    final text = out.toString();
    return text.substring(text.lastIndexOf('\n') + 1);
  }

  static final _variableMacro = RegExp(
    r'^(get|format)_(message|chat|character|preset|global)_variable(_quoted)?$',
  );

  String _evaluate(
    String name,
    List<String> args,
    String original,
    int position, {
    String prefix = '',
  }) {
    if (values.containsKey(name) && args.isEmpty) return values[name]!;
    final variable = _variableMacro.firstMatch(name);
    if (variable != null) {
      return _variableMacroValue(
        variable.group(1)!,
        variable.group(2)!,
        args.isEmpty ? '' : args.first,
        quoted: variable.group(3) != null,
        prefix: prefix,
      );
    }
    if (name.startsWith('//') || name == 'noop') return '';
    if (name.startsWith('.') && args.isEmpty) {
      return local[name.substring(1)] ?? '';
    }
    if (name.startsWith(r'$') && args.isEmpty) {
      return global[name.substring(1)] ?? '';
    }
    if (name == 'space' || name == 'newline') {
      final count = args.isEmpty ? 1 : int.tryParse(args.first) ?? 1;
      return (name == 'space' ? ' ' : '\n') * count.clamp(0, 4096);
    }
    if (name == 'reverse' && args.isNotEmpty) {
      return String.fromCharCodes(args.first.runes.toList().reversed);
    }
    if (name == 'random' || name == 'pick') {
      final options = args.length == 1
          ? args.first.split(',').map((s) => s.trim()).toList()
          : args;
      if (options.isEmpty) return '';
      if (name == 'random') return options[_random.nextInt(options.length)];
      diagnostics.add(
        const CompatibilityDiagnostic(
          'pick_adapted',
          'pick 使用任务种子保持稳定；种子规则与 ST 聊天标识不同',
          severity: DiagnosticSeverity.info,
        ),
      );
      final digest = sha256
          .convert(utf8.encode('$_seed:$position:$original'))
          .bytes;
      return options[((digest[0] << 16) | (digest[1] << 8) | digest[2]) %
          options.length];
    }
    if (name == 'date') {
      return '${clock.year}-${_two(clock.month)}-${_two(clock.day)}';
    }
    if (name == 'time') return '${_two(clock.hour)}:${_two(clock.minute)}';
    if (name == 'isodate') return clock.toIso8601String().split('T').first;
    final scope = name.contains('global') ? global : local;
    final operation = name.replaceFirst('global', '');
    if (args.isNotEmpty) {
      final key = args.first;
      switch (operation) {
        case 'getvar':
          return scope[key] ?? '';
        case 'hasvar':
        case 'varexists':
          return scope.containsKey(key) ? 'true' : 'false';
        case 'deletevar':
        case 'flushvar':
          scope.remove(key);
          return '';
        case 'setvar':
          if (args.length < 2) return _unknown(original, 'setvar 缺少值');
          scope[key] = args[1];
          return '';
        case 'addvar':
          if (args.length < 2) return _unknown(original, 'addvar 缺少值');
          scope[key] = _add(scope[key] ?? '', args[1]);
          return '';
        case 'incvar':
        case 'decvar':
          return scope[key] = _add(
            scope[key] ?? '',
            operation == 'incvar' ? 1 : -1,
          );
      }
    }
    return _unknown(original, '未支持的宏：$name');
  }

  /// 酒馆助手's `{{get_X_variable::path}}` and `{{format_X_variable::path}}`
  /// macro-likes, which MVU cards use to put their state into prompts.
  /// `message` and `chat` read this task's local variables, `global` the
  /// global ones; character and preset variables are not kept here. Keys
  /// starting with `$` are omitted, strings pass through, anything else is
  /// JSON (`get`) or YAML indented to the line (`format`).
  String _variableMacroValue(
    String kind,
    String type,
    String path, {
    required bool quoted,
    required String prefix,
  }) {
    final store = switch (type) {
      'global' => decodeVariables(global),
      'message' || 'chat' => decodeVariables(local),
      _ => <String, dynamic>{},
    };
    final value = _withoutDollarKeys(_lookup(store, _htmlUnescape(path)));
    if (kind == 'get') {
      return value is String ? value : jsonEncode(value);
    }
    final text = value is String
        ? value
        : _yaml(value, 0, quoted: quoted).trimRight();
    return text.replaceAll('\n', '\n${' ' * prefix.length}');
  }

  static Object? _lookup(Object? root, String path) {
    if (path.trim().isEmpty) return root;
    Object? current = root;
    for (final part
        in path.split(RegExp(r'\.|\[|\]\.?')).where((p) => p.isNotEmpty)) {
      final key = part.replaceAll(RegExp(r'''^["']|["']\$'''), '');
      if (current is Map) {
        current = current[key];
      } else if (current is List) {
        final index = int.tryParse(key);
        current = index != null && index >= 0 && index < current.length
            ? current[index]
            : null;
      } else {
        return null;
      }
    }
    return current;
  }

  static Object? _withoutDollarKeys(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          if (!entry.key.toString().startsWith(r'$'))
            entry.key.toString(): _withoutDollarKeys(entry.value),
      };
    }
    if (value is List) return value.map(_withoutDollarKeys).toList();
    return value;
  }

  static String _htmlUnescape(String text) => text
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  static final _plainUnsafe = RegExp(
    r'''^[\s\-?:,\[\]{}#&*!|>'"%@`]|: |\s#|[:\s]$|^(true|false|null|~|yes|no|on|off)$|^[-+]?(\d[\d_]*\.?\d*([eE][-+]?\d+)?|\.\d+|0x[0-9a-fA-F]+)$''',
    caseSensitive: false,
  );

  /// A compact YAML dump in the style of the `yaml` npm package with
  /// literal block quotes, enough for prompts to read.
  static String _yaml(Object? value, int indent, {required bool quoted}) {
    final pad = ' ' * indent;
    String scalar(Object? v) {
      if (v == null) return 'null';
      if (v is bool || v is num) return v.toString();
      if (v is Map) return '{}';
      if (v is List) return '[]';
      final text = v.toString();
      if (text.contains('\n')) {
        final lines = text.trimRight().split('\n');
        return '|-\n${lines.map((l) => '$pad  $l').join('\n')}';
      }
      if (quoted || text.isEmpty || _plainUnsafe.hasMatch(text)) {
        return jsonEncode(text);
      }
      return text;
    }

    // The quoted variant quotes strings but keeps keys plain.
    String key(String k) =>
        k.isEmpty || _plainUnsafe.hasMatch(k) ? jsonEncode(k) : k;
    if (value is Map) {
      if (value.isEmpty) return '{}';
      final lines = <String>[];
      for (final entry in value.entries) {
        final v = entry.value;
        if ((v is Map && v.isNotEmpty) || (v is List && v.isNotEmpty)) {
          lines.add('$pad${key(entry.key.toString())}:');
          lines.add(_yaml(v, indent + 2, quoted: quoted));
        } else {
          lines.add('$pad${key(entry.key.toString())}: ${scalar(v)}');
        }
      }
      return lines.join('\n');
    }
    if (value is List) {
      if (value.isEmpty) return '[]';
      final lines = <String>[];
      for (final item in value) {
        if ((item is Map && item.isNotEmpty) ||
            (item is List && item.isNotEmpty)) {
          final nested = _yaml(item, indent + 2, quoted: quoted);
          lines.add('$pad- ${nested.trimLeft()}');
        } else {
          lines.add('$pad- ${scalar(item)}');
        }
      }
      return lines.join('\n');
    }
    return '$pad${scalar(value)}';
  }

  String _unknown(String raw, String message) {
    diagnostics.add(
      CompatibilityDiagnostic(
        'unknown_macro',
        message,
        severity: DiagnosticSeverity.error,
      ),
    );
    return '{{$raw}}';
  }

  String _two(int number) => number.toString().padLeft(2, '0');
  String _add(String current, Object increment) {
    try {
      final value = jsonDecode(current);
      if (value is List) return jsonEncode([...value, increment]);
    } on FormatException {
      /* Ordinary strings need no JSON parsing. */
    }
    final a = current.trim().isEmpty ? 0 : num.tryParse(current);
    final text = increment.toString();
    final b = text.trim().isEmpty ? 0 : num.tryParse(text);
    return a != null && b != null ? _number(a + b) : '$current$text';
  }

  String _number(num number) =>
      number == number.toInt() ? '${number.toInt()}' : '$number';

  ({String body, int end})? _token(String source, int start) {
    var depth = 1;
    var i = start + 2;
    for (; i + 1 < source.length; i++) {
      if (source.startsWith('{{', i)) {
        depth++;
        i++;
      } else if (source.startsWith('}}', i)) {
        if (--depth == 0) {
          return (body: source.substring(start + 2, i), end: i + 2);
        }
        i++;
      }
    }
    return null;
  }

  (String, List<String>) _arguments(String body) {
    final parts = <String>[];
    var depth = 0;
    var from = 0;
    for (var i = 0; i + 1 < body.length; i++) {
      if (body.startsWith('{{', i)) {
        depth++;
        i++;
      } else if (body.startsWith('}}', i)) {
        depth--;
        i++;
      } else if (depth == 0 && body.startsWith('::', i)) {
        parts.add(body.substring(from, i));
        from = i + 2;
        i++;
      }
    }
    parts.add(body.substring(from));
    final head = parts.removeAt(0).trim();
    final space = head.indexOf(RegExp(r'\s'));
    if (space >= 0) {
      parts.insert(0, head.substring(space + 1).trim());
      return (head.substring(0, space), parts);
    }
    return (head, parts);
  }

  ({String yes, String no, int end})? _block(
    String source,
    int start,
    String name,
  ) {
    var level = 0;
    var cursor = start;
    int? middleStart, middleEnd;
    while (cursor < source.length) {
      final next = source.indexOf('{{', cursor);
      if (next < 0) break;
      final token = _token(source, next);
      if (token == null) break;
      final parsed = _arguments(token.body);
      final tag = parsed.$1.toLowerCase();
      if (tag == name && (name != 'if' || parsed.$2.length == 1)) {
        level++;
      }
      if (tag == '/$name') {
        if (level == 0) {
          return (
            yes: source.substring(start, middleStart ?? next),
            no: middleEnd == null ? '' : source.substring(middleEnd, next),
            end: token.end,
          );
        }
        level--;
      }
      if (name == 'if' && level == 0 && tag == 'else') {
        middleStart = next;
        middleEnd = token.end;
      }
      cursor = token.end;
    }
    return null;
  }
}
