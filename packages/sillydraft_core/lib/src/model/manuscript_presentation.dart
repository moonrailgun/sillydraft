import '../st/import_types.dart';
import '../st/macro_engine.dart';
import '../st/regex_pipeline.dart';
import 'manuscript.dart';
import 'task.dart';

/// Disposable display projection. Canonical storage, exports and model context
/// always use ManuscriptContent; offsets here map reading positions back to it.
final class ManuscriptPresentation {
  ManuscriptPresentation._(this.content, this._sourceOffsets);
  factory ManuscriptPresentation.identity(ManuscriptContent content) =>
      ManuscriptPresentation._(
        content,
        List.generate(content.text.length + 1, (i) => i),
      );

  factory ManuscriptPresentation.fromTask(
    ManuscriptContent content,
    GenerationTask task, {
    List<Map<String, dynamic>>? rules,
  }) {
    final input = task.input;
    rules ??= (input['outputRegex'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (rules.isEmpty) return ManuscriptPresentation.identity(content);
    final variables = input['variableResult'] as Map? ?? {};
    return ManuscriptPresentation.fromRules(
      content,
      rules: rules,
      macros: MacroEngine(
        values: (input['macroValues'] as Map? ?? {}).cast<String, String>(),
        local: (variables['local'] as Map? ?? {}).cast<String, String>(),
        global: (variables['global'] as Map? ?? {}).cast<String, String>(),
        clock: DateTime.parse(input['clock'] as String),
        seed: input['seed'] as int,
      ),
    );
  }

  /// Applies display-stage regex [rules] to [content]. With [strict], a rule
  /// or macro error throws; otherwise the text is shown as written.
  factory ManuscriptPresentation.fromRules(
    ManuscriptContent content, {
    required List<Map<String, dynamic>> rules,
    required MacroEngine macros,
    bool strict = true,
  }) {
    if (rules.isEmpty) return ManuscriptPresentation.identity(content);
    var operations = content.delta;
    final offsets = List.generate(content.text.length + 1, (i) => i);
    final pipeline = RegexPipeline(preset: rules);
    pipeline.apply(
      content.text,
      placement: 2,
      stage: RegexStage.display,
      macros: macros,
      depth: 0,
      onReplacements: (changes) {
        for (final change in changes.reversed) {
          final before = <Map<String, dynamic>>[],
              after = <Map<String, dynamic>>[];
          Map<String, dynamic>? inherited;
          var position = 0;
          for (final op in operations) {
            final value = op['insert'],
                length = value is String ? value.length : 1;
            if (position <= change.start && change.start < position + length) {
              inherited = op['attributes'] as Map<String, dynamic>?;
            }
            final left = (change.start - position).clamp(0, length);
            final right = (change.end - position).clamp(0, length);
            if (left > 0) {
              before.add({
                ...op,
                'insert': value is String ? value.substring(0, left) : value,
              });
            }
            if (right < length) {
              after.add({
                ...op,
                'insert': value is String ? value.substring(right) : value,
              });
            }
            position += length;
          }
          final sourceStart = offsets[change.start],
              sourceEnd = offsets[change.end];
          offsets.replaceRange(change.start, change.end, [
            for (var i = 0; i < change.text.length; i++)
              sourceStart +
                  ((sourceEnd - sourceStart) * i ~/ change.text.length),
          ]);
          operations = [
            ...before,
            if (change.text.isNotEmpty)
              {'insert': change.text, 'attributes': ?inherited},
            ...after,
          ];
        }
      },
    );
    final errors = [
      ...pipeline.diagnostics,
      ...macros.diagnostics,
    ].where((d) => d.severity == DiagnosticSeverity.error);
    if (errors.isNotEmpty) {
      if (!strict) return ManuscriptPresentation.identity(content);
      throw FormatException(errors.map((e) => e.message).join('\n'));
    }
    final shown = ManuscriptContent.fromDelta(operations);
    while (offsets.length <= shown.text.length) {
      offsets.add(content.text.length);
    }
    return ManuscriptPresentation._(shown, offsets);
  }

  final ManuscriptContent content;
  final List<int> _sourceOffsets;
  int sourceOffset(int displayOffset) =>
      _sourceOffsets[displayOffset.clamp(0, _sourceOffsets.length - 1)];
  int displayOffset(int sourceOffset) {
    final index = _sourceOffsets.indexWhere((offset) => offset >= sourceOffset);
    return index < 0 ? content.text.length : index;
  }
}
