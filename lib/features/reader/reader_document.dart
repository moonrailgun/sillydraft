import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'reader_markup.dart';

/// One selectable paragraph tree, with canonical offsets for search/bookmarks.
///
/// Indents are the page's: whatever whitespace starts a line in the source
/// is left out, and with [indent] every body paragraph is indented by two
/// ems. Paragraphs are followed by [paragraphSpacing] lines of
/// space. With spacing on, blank lines in the
/// source collapse, so books imported with blank lines between paragraphs
/// read the same as ones without. Everything added for layout maps back to a
/// source offset, so bookmarks and search stay exact.
///
/// With an [html] builder, HTML blocks in the text (fenced pages, raw
/// fragments) become one inline widget each on a line of their own; the
/// widget stands for the whole block in the offset map. [hideHtml] and
/// [hideImages] independently omit blocks and image embeds, preserving the
/// prose's source offsets.
///
/// Text is marked up the way SillyTavern shows a chat message (see
/// [ProseMarkup]): Markdown emphasis shows as emphasis with its markers left
/// out, dialogue in quotes takes [quoteColor] and italics outside dialogue
/// take [italicColor]. Null colours keep the text colour.
final class ReaderDocument {
  ReaderDocument._(this.span, this._offsets, this.blocks);
  factory ReaderDocument.build(
    ManuscriptPresentation presentation, {
    required double fontSize,
    required Widget Function(String? uri) image,
    Widget Function(HtmlBlock block, int index)? html,
    bool hideHtml = false,
    bool hideImages = false,
    double paragraphSpacing = 0,
    bool indent = false,
    Color? quoteColor,
    Color? italicColor,
  }) {
    final blocks = !hideHtml && html == null
        ? const <HtmlBlock>[]
        : HtmlBlocks.find(presentation.content.text);
    // The source's own indents are dropped: [indent] alone indents.
    final markup = ProseMarkup.parse(
      presentation.content.text,
      skip: [for (final b in blocks) (start: b.start, end: b.end)],
      trimIndent: true,
    );
    final paragraphs = <InlineSpan>[], line = <InlineSpan>[];
    final offsets = <int>[];
    final hiddenImages = <int>{};
    var position = 0, lineStart = 0, ordered = 0;
    var blockIndex = 0, skipUntil = 0, opStart = 0;
    TextStyle inline(Map attributes, int flags) {
      bool marked(int flag) => flags & flag != 0;
      final italic = attributes['italic'] == true || marked(ProseMarkup.italic);
      return TextStyle(
        fontWeight: attributes['bold'] == true || marked(ProseMarkup.bold)
            ? FontWeight.bold
            : null,
        fontStyle: italic ? FontStyle.italic : null,
        // As in ST, italics inside dialogue keep the dialogue colour.
        color: marked(ProseMarkup.quote)
            ? quoteColor
            : italic
            ? italicColor
            : null,
        decoration: TextDecoration.combine([
          if (attributes['underline'] == true || marked(ProseMarkup.underline))
            TextDecoration.underline,
          if (attributes['strike'] == true) TextDecoration.lineThrough,
        ]),
      );
    }

    // Adds [from]..[to] of [text], an op starting at display offset [base],
    // split where its markup changes and without hidden markers.
    void add(String text, int from, int to, int base, Map attributes) {
      var run = from;
      for (var i = from + 1; i <= to; i++) {
        if (i < to && markup[base + i] == markup[base + run]) continue;
        final flags = markup[base + run];
        if (flags & ProseMarkup.hidden == 0) {
          line.add(
            TextSpan(
              text: text.substring(run, i),
              style: inline(attributes, flags),
            ),
          );
        }
        run = i;
      }
    }

    void finish(Map attributes, {bool ended = true}) {
      final list = attributes['list'];
      ordered = list == 'ordered' ? ordered + 1 : 0;
      final header = attributes['header'] as int?;
      final body =
          list == null && attributes['blockquote'] != true && header == null;
      final blank =
          line.every((s) => s is TextSpan) &&
          line.map((s) => (s as TextSpan).text ?? '').join().trim().isEmpty;
      final prefix = switch (list) {
        'ordered' => '$ordered. ',
        'bullet' => '• ',
        'checked' => '☑ ',
        'unchecked' => '☐ ',
        _ when attributes['blockquote'] == true => '│ ',
        _ => '',
      };
      final marker = '${'  ' * (attributes['indent'] as int? ?? 0)}$prefix';
      // Not two full-width spaces: a justified line drops the width of the
      // spaces it starts with, so wrapping paragraphs lost their indent.
      final indented = indent && body && !blank;
      offsets.addAll(
        List.filled(
          marker.length + (indented ? 1 : 0),
          presentation.sourceOffset(lineStart),
        ),
      );
      for (var i = lineStart; i < position; i++) {
        if (markup[i] & ProseMarkup.hidden != 0 || hiddenImages.contains(i)) {
          continue;
        }
        offsets.add(presentation.sourceOffset(i));
      }
      final spaced = paragraphSpacing > 0;
      paragraphs.add(
        TextSpan(
          style: TextStyle(
            fontSize: spaced && body && blank
                ? 1
                : header == null
                ? null
                : fontSize * [1.6, 1.4, 1.25, 1.15, 1.05, 1.0][header - 1],
            height: spaced && body && blank ? 1 : null,
            fontWeight: header == null ? null : FontWeight.bold,
            fontStyle: attributes['blockquote'] == true
                ? FontStyle.italic
                : null,
          ),
          children: [
            if (indented) WidgetSpan(child: SizedBox(width: fontSize * 2)),
            if (marker.isNotEmpty) TextSpan(text: marker),
            ...line,
          ],
        ),
      );
      // List items and quote lines stay together; paragraphs breathe.
      if (spaced && ended && !blank && list == null) {
        paragraphs.add(
          TextSpan(
            text: '\n',
            style: TextStyle(fontSize: fontSize * paragraphSpacing, height: 1),
          ),
        );
        offsets.add(presentation.sourceOffset(position));
      }
      line.clear();
      lineStart = position;
    }

    // The block is one placeholder character plus a line break; both map
    // to the block's edges so bookmarks and search land beside it. The
    // widget gets its own semantics node: merged into the paragraph's text,
    // interactive children would conflict with their siblings.
    void emitBlock(HtmlBlock block) {
      if (line.isNotEmpty) finish(const {});
      if (!hideHtml) {
        paragraphs.add(
          TextSpan(
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.top,
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: html!(block, blockIndex),
                ),
              ),
              const TextSpan(text: '\n'),
            ],
          ),
        );
        offsets.add(presentation.sourceOffset(block.start));
        offsets.add(presentation.sourceOffset(block.end - 1));
      }
      blockIndex++;
      skipUntil = block.end;
      position = block.end;
      lineStart = block.end;
    }

    for (final op in presentation.content.delta) {
      final value = op['insert'], attributes = op['attributes'] as Map? ?? {};
      if (value is Map) {
        if (opStart >= skipUntil) {
          if (hideImages) {
            hiddenImages.add(opStart);
          } else {
            line.add(WidgetSpan(child: image(value['image'] as String?)));
          }
          position = opStart + 1;
        }
        opStart++;
        continue;
      }
      final text = value as String;
      var segment = 0;
      for (var i = 0; i < text.length; i++) {
        final at = opStart + i;
        if (at < skipUntil) {
          segment = i + 1;
          continue;
        }
        if (blockIndex < blocks.length && at == blocks[blockIndex].start) {
          if (i > segment) {
            add(text, segment, i, opStart, attributes);
            position = at;
          }
          emitBlock(blocks[blockIndex]);
          segment = i + 1;
          continue;
        }
        if (text[i] != '\n') continue;
        add(text, segment, i + 1, opStart, attributes);
        position = at + 1;
        finish(attributes);
        segment = i + 1;
      }
      if (segment < text.length) {
        add(text, segment, text.length, opStart, attributes);
        position = opStart + text.length;
      }
      opStart += text.length;
    }
    if (line.isNotEmpty) finish({}, ended: false);
    offsets.add(presentation.sourceOffset(position));
    return ReaderDocument._(
      TextSpan(children: paragraphs),
      offsets,
      hideHtml ? const [] : blocks,
    );
  }
  final TextSpan span;
  final List<int> _offsets;

  /// HTML blocks shown as widgets, in text order.
  final List<HtmlBlock> blocks;
  int sourceOffset(int displayOffset) =>
      _offsets[displayOffset.clamp(0, _offsets.length - 1)];
  int displayOffset(int sourceOffset) {
    final found = _offsets.indexWhere((value) => value >= sourceOffset);
    return found < 0 ? _offsets.length - 1 : found;
  }
}
