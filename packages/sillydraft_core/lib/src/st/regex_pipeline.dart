import 'import_types.dart';
import 'macro_engine.dart';

enum RegexStage { general, prompt, display }

final class RegexPipeline {
  RegexPipeline({
    List<Map<String, dynamic>> global = const [],
    List<Map<String, dynamic>> preset = const [],
    List<Map<String, dynamic>> card = const [],
  }) : _rules = [...global, ...preset, ...card].map(JsonSource.new).toList();
  final List<JsonSource> _rules;
  final diagnostics = <CompatibilityDiagnostic>[];

  String apply(
    String text, {
    required int placement,
    required RegexStage stage,
    required MacroEngine macros,
    bool isEdit = false,
    int? depth,
    void Function(List<({int start, int end, String text})>)? onReplacements,
  }) {
    var output = text;
    for (final source in _rules) {
      final rule = source.raw;
      if (rule['disabled'] == true) continue;
      final prompt = rule['promptOnly'] == true,
          display = rule['markdownOnly'] == true;
      if (!((prompt && stage == RegexStage.prompt) ||
          (display && stage == RegexStage.display) ||
          (!prompt && !display && stage == RegexStage.general))) {
        continue;
      }
      if (isEdit && rule['runOnEdit'] != true) continue;
      final placements = rule['placement'];
      if (placements is! List || !placements.contains(placement)) continue;
      final min = rule['minDepth'], max = rule['maxDepth'];
      if (depth != null &&
          ((min is num && min >= -1 && depth < min) ||
              (max is num && max >= 0 && depth > max))) {
        continue;
      }
      try {
        var pattern = stringField(rule, 'findRegex');
        if (pattern.isEmpty || output.isEmpty) continue;
        final mode = rule['substituteRegex'];
        if (mode == 1 || mode == 2) {
          pattern = macros.render(
            pattern,
            transform: mode == 2 ? RegExp.escape : null,
          );
        }
        final parsed = parseJavascriptRegex(pattern);
        if (pattern.length > 4096 || output.length > 1024 * 1024) {
          throw const FormatException('正则处理大小超限');
        }
        final trims = stringList(rule['trimStrings'], 'trimStrings');
        final replacements = <({int start, int end, String text})>[];
        String replace(Match rawMatch) {
          final match = rawMatch as RegExpMatch;
          final template = stringField(
            rule,
            'replaceString',
          ).replaceAll(RegExp(r'\{\{match\}\}', caseSensitive: false), r'$0');
          final captured = template.replaceAllMapped(
            RegExp(r'\$(\d+)|\$<([^>]+)>'),
            (group) {
              String value = '';
              if (group[1] != null) {
                final index = int.parse(group[1]!);
                if (index <= match.groupCount) value = match.group(index) ?? '';
              } else if (match.groupNames.contains(group[2])) {
                value = match.namedGroup(group[2]!) ?? '';
              }
              for (final trim in trims) {
                value = value.replaceAll(macros.render(trim), '');
              }
              return value;
            },
          );
          final replacement = macros.render(captured);
          replacements.add((
            start: match.start,
            end: match.end,
            text: replacement,
          ));
          return replacement;
        }

        output = parsed.global
            ? output.replaceAllMapped(parsed.regex, replace)
            : output.replaceFirstMapped(parsed.regex, replace);
        if (replacements.isNotEmpty) onReplacements?.call(replacements);
      } on FormatException catch (error) {
        diagnostics.add(
          CompatibilityDiagnostic(
            'unsupported_regex',
            error.message,
            severity: DiagnosticSeverity.error,
          ),
        );
      }
    }
    return output;
  }
}

({RegExp regex, bool global}) parseJavascriptRegex(String value) {
  var pattern = value, flags = '';
  if (value.startsWith('/')) {
    final end = value.lastIndexOf('/');
    if (end <= 0) throw const FormatException('正则缺少结束分隔符');
    pattern = value.substring(1, end);
    flags = value.substring(end + 1);
  }
  if (flags.split('').any((f) => !'gimsu'.contains(f))) {
    throw const FormatException('未支持的 JavaScript 正则标志');
  }
  return (
    regex: RegExp(
      pattern,
      caseSensitive: !flags.contains('i'),
      multiLine: flags.contains('m'),
      dotAll: flags.contains('s'),
      unicode: flags.contains('u'),
    ),
    global: flags.contains('g'),
  );
}
