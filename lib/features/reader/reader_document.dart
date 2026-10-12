import 'package:flutter/material.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

/// One selectable paragraph tree, with canonical offsets for search/bookmarks.
final class ReaderDocument {
  ReaderDocument._(this.span, this._offsets);
  factory ReaderDocument.build(
    ManuscriptPresentation presentation, {
    required double fontSize,
    required Widget Function(String? uri) image,
  }) {
    final paragraphs = <InlineSpan>[], line = <InlineSpan>[];
    final offsets = <int>[];
    var position = 0, lineStart = 0, ordered = 0;
    TextStyle inline(Map attributes) => TextStyle(
      fontWeight: attributes['bold'] == true ? FontWeight.bold : null,
      fontStyle: attributes['italic'] == true ? FontStyle.italic : null,
      decoration: TextDecoration.combine([
        if (attributes['underline'] == true) TextDecoration.underline,
        if (attributes['strike'] == true) TextDecoration.lineThrough,
      ]),
    );
    void finish(Map attributes) {
      final list = attributes['list'];
      ordered = list == 'ordered' ? ordered + 1 : 0;
      final prefix = switch (list) {
        'ordered' => '$ordered. ',
        'bullet' => '• ',
        'checked' => '☑ ',
        'unchecked' => '☐ ',
        _ => attributes['blockquote'] == true ? '│ ' : '',
      };
      final marker = '${'  ' * (attributes['indent'] as int? ?? 0)}$prefix';
      offsets.addAll(
        List.filled(marker.length, presentation.sourceOffset(lineStart)),
      );
      for (var i = lineStart; i < position; i++) {
        offsets.add(presentation.sourceOffset(i));
      }
      final header = attributes['header'] as int?;
      paragraphs.add(
        TextSpan(
          style: TextStyle(
            fontSize: header == null
                ? null
                : fontSize * [1.6, 1.4, 1.25, 1.15, 1.05, 1.0][header - 1],
            fontWeight: header == null ? null : FontWeight.bold,
            fontStyle: attributes['blockquote'] == true
                ? FontStyle.italic
                : null,
          ),
          children: [
            if (marker.isNotEmpty) TextSpan(text: marker),
            ...line,
          ],
        ),
      );
      line.clear();
      lineStart = position;
    }

    for (final op in presentation.content.delta) {
      final value = op['insert'], attributes = op['attributes'] as Map? ?? {};
      if (value is Map) {
        line.add(WidgetSpan(child: image(value['image'] as String?)));
        position++;
        continue;
      }
      final text = value as String;
      var start = 0;
      for (var i = 0; i < text.length; i++) {
        if (text[i] != '\n') continue;
        line.add(
          TextSpan(
            text: text.substring(start, i + 1),
            style: inline(attributes),
          ),
        );
        position += i + 1 - start;
        finish(attributes);
        start = i + 1;
      }
      if (start < text.length) {
        line.add(
          TextSpan(text: text.substring(start), style: inline(attributes)),
        );
        position += text.length - start;
      }
    }
    if (line.isNotEmpty) finish({});
    offsets.add(presentation.sourceOffset(position));
    return ReaderDocument._(TextSpan(children: paragraphs), offsets);
  }
  final TextSpan span;
  final List<int> _offsets;
  int sourceOffset(int displayOffset) =>
      _offsets[displayOffset.clamp(0, _offsets.length - 1)];
  int displayOffset(int sourceOffset) {
    final found = _offsets.indexWhere((value) => value >= sourceOffset);
    return found < 0 ? _offsets.length - 1 : found;
  }
}
