import 'dart:convert';

import 'mvu_path.dart';
import 'mvu_value.dart';

/// One variable update instruction found in model output.
final class MvuCommand {
  MvuCommand({
    required this.type,
    required this.fullMatch,
    required List<String> args,
    required this.reason,
    this.index = 0,
  }) : args = List.of(args);

  /// `set`, `insert`, `assign`, `remove`, `unset`, `delete`, `add`, `move`.
  String type;
  final String fullMatch;
  final List<String> args;
  final String reason;
  final int index;

  /// Commands translated from a JSON Patch carry this reason; their paths
  /// are already exact bracket paths and must not be "fixed".
  bool get fromJsonPatch => reason == 'json_patch';

  Map<String, dynamic> toJson() => {
    'type': type,
    'full_match': fullMatch,
    'args': args,
    'reason': reason,
  };
}

/// Extracts update commands from a reply: `_.set('path', old, new);//why`
/// style calls anywhere in the visible text, plus JSON Patch arrays inside
/// `<JSONPatch>` blocks. Text inside `<think>`, `<thinking>`, `<reasoning>`,
/// `<analysis>` and `<analyze>` tags is ignored, as MagVarUpdate does.
abstract final class MvuCommandParser {
  static final _thinkingTags = RegExp(
    r'<(/?)\s*(think|thinking|reasoning|analysis|analyze)\b[^>]*>',
    caseSensitive: false,
  );
  static final _patchTags = RegExp(
    r'<(/?)\s*(json_?patch)\b[^>]*>',
    caseSensitive: false,
  );
  static final _legacy = RegExp(
    r'_\.(set|insert|assign|remove|unset|delete|add)\(',
  );

  static List<MvuCommand> extract(String text) {
    final visible = _maskThinking(text);
    final results = <MvuCommand>[];
    final masked = visible.split('');
    for (final block in _patchBlocks(visible)) {
      for (var i = block.start; i < block.end; i++) {
        if (masked[i] != '\n') masked[i] = ' ';
      }
      final content = _cleanStructured(
        text.substring(block.contentStart, block.contentEnd),
      );
      try {
        final patch = MvuValue.parseStructured(content);
        if (_isJsonPatch(patch)) {
          results.addAll(
            _fromJsonPatch(patch as List).map(
              (c) => MvuCommand(
                type: c.type,
                fullMatch: c.fullMatch,
                args: c.args,
                reason: c.reason,
                index: block.start,
              ),
            ),
          );
        }
      } on FormatException {
        // An unparsable patch block is skipped, as upstream does.
      }
    }
    final legacyText = masked.join();
    var i = 0;
    while (i < text.length) {
      final match = _legacy.firstMatch(legacyText.substring(i));
      if (match == null) break;
      final type = match.group(1)!;
      final start = i + match.start;
      final open = start + match.group(0)!.length;
      final close = _matchingParen(text, open);
      if (close < 0) {
        i = open;
        continue;
      }
      var end = close + 1;
      if (end >= text.length || text[end] != ';') {
        i = close + 1;
        continue;
      }
      end++;
      var comment = '';
      final trailing = RegExp(r'^\s*//(.*)').firstMatch(text.substring(end));
      if (trailing != null) {
        comment = trailing.group(1)!.trim();
        end += trailing.group(0)!.length;
      }
      final params = MvuValue.parseParameters(text.substring(open, close));
      final valid = switch (type) {
        'set' || 'assign' || 'insert' => params.length >= 2,
        'remove' || 'unset' || 'delete' => params.isNotEmpty,
        'add' => params.length == 2,
        _ => false,
      };
      if (valid) {
        results.add(
          MvuCommand(
            type: type,
            fullMatch: text.substring(start, end),
            args: params,
            reason: comment,
            index: start,
          ),
        );
      }
      i = end;
    }
    results.sort((a, b) => a.index.compareTo(b.index));
    return results;
  }

  /// The text with thinking blocks blanked (newlines kept) so offsets match.
  static String _maskThinking(String text) {
    final chars = text.split('');
    final stack = <String>[];
    var i = 0;
    while (i < text.length) {
      if (text[i] != '<') {
        if (stack.isNotEmpty && text[i] != '\n') chars[i] = ' ';
        i++;
        continue;
      }
      final tag = _thinkingTags.matchAsPrefix(text, i);
      if (tag == null) {
        if (stack.isNotEmpty) chars[i] = ' ';
        i++;
        continue;
      }
      final closing = tag.group(1) == '/';
      final name = tag.group(2)!.toLowerCase();
      if (closing) {
        if (stack.isNotEmpty && stack.last == name) stack.removeLast();
      } else {
        stack.add(name);
      }
      for (var k = tag.start; k < tag.end; k++) {
        if (chars[k] != '\n') chars[k] = ' ';
      }
      i = tag.end;
    }
    return chars.join();
  }

  static List<({int start, int end, int contentStart, int contentEnd})>
  _patchBlocks(String text) {
    final blocks = <({int start, int end, int contentStart, int contentEnd})>[];
    final stack = <({int start, int contentStart})>[];
    var quote = '';
    var i = 0;
    while (i < text.length) {
      final char = text[i];
      if (stack.isNotEmpty && quote.isNotEmpty) {
        if (char == r'\') {
          i += 2;
          continue;
        }
        if (char == quote) quote = '';
        i++;
        continue;
      }
      if (stack.isNotEmpty && (char == '"' || char == "'")) {
        quote = char;
        i++;
        continue;
      }
      if (char == '<') {
        final tag = _patchTags.matchAsPrefix(text, i);
        if (tag != null) {
          if (tag.group(1) == '/') {
            if (stack.isNotEmpty) {
              final open = stack.removeLast();
              blocks.add((
                start: open.start,
                end: tag.end,
                contentStart: open.contentStart,
                contentEnd: tag.start,
              ));
            }
          } else {
            stack.add((start: tag.start, contentStart: tag.end));
          }
          i = tag.end;
          continue;
        }
      }
      i++;
    }
    blocks.sort((a, b) => a.start.compareTo(b.start));
    return blocks;
  }

  static String _cleanStructured(String input) => input
      .trim()
      .replaceFirst(
        RegExp(r'^```(?:json5?|ya?ml)?\s*', caseSensitive: false),
        '',
      )
      .replaceFirst(RegExp(r'\s*```$'), '')
      .trim();

  static bool _isJsonPatch(Object? value) =>
      value is List &&
      value.every(
        (op) =>
            op is Map &&
            op['op'] is String &&
            (op['path'] is String ||
                (op['op'] == 'move' && op['to'] is String)),
      );

  static String _pointerToPath(Object? pointer) {
    if (pointer is! String || pointer.isEmpty) return '';
    final body = pointer.startsWith('/') ? pointer.substring(1) : pointer;
    return MvuPath.fromSegments(
      body
          .split('/')
          .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
          .toList(),
    );
  }

  static List<MvuCommand> _fromJsonPatch(List patch) {
    final commands = <MvuCommand>[];
    for (final raw in patch) {
      final op = raw as Map;
      final path = _pointerToPath(op['path'] ?? op['to']);
      final full = jsonEncode(op);
      switch (op['op']) {
        case 'replace':
          commands.add(
            MvuCommand(
              type: 'set',
              fullMatch: full,
              args: [path, jsonEncode(op['value'])],
              reason: 'json_patch',
            ),
          );
        case 'delta':
          commands.add(
            MvuCommand(
              type: 'add',
              fullMatch: full,
              args: [path, jsonEncode(op['value'])],
              reason: 'json_patch',
            ),
          );
        case 'insert' || 'add':
          final parts = MvuPath.toPath(path);
          final last = parts.isEmpty ? '' : parts.last;
          final container = MvuPath.fromSegments(
            parts.sublist(0, parts.isEmpty ? 0 : parts.length - 1),
          );
          commands.add(
            MvuCommand(
              type: 'insert',
              fullMatch: full,
              args: [
                container,
                RegExp(r'^\d+$').hasMatch(last) ? last : jsonEncode(last),
                jsonEncode(op['value']),
              ],
              reason: 'json_patch',
            ),
          );
        case 'remove':
          commands.add(
            MvuCommand(
              type: 'delete',
              fullMatch: full,
              args: [path],
              reason: 'json_patch',
            ),
          );
        case 'move':
          commands.add(
            MvuCommand(
              type: 'move',
              fullMatch: full,
              args: [_pointerToPath(op['from']), path],
              reason: 'json_patch',
            ),
          );
      }
    }
    return commands;
  }

  /// Index of the `)` matching the `(` just before [from], ignoring
  /// parentheses inside quoted strings; -1 when unbalanced.
  static int _matchingParen(String text, int from) {
    var depth = 1;
    var inQuote = false;
    var quote = '';
    for (var i = from; i < text.length; i++) {
      final char = text[i];
      final previous = i > 0 ? text[i - 1] : '';
      if ((char == '"' || char == "'" || char == '`') && previous != r'\') {
        if (!inQuote) {
          inQuote = true;
          quote = char;
        } else if (char == quote) {
          inQuote = false;
        }
      }
      if (!inQuote) {
        if (char == '(') {
          depth++;
        } else if (char == ')') {
          depth--;
          if (depth == 0) return i;
        }
      }
    }
    return -1;
  }
}
