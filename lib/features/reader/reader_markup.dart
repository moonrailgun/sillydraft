import 'dart:typed_data';

/// SillyTavern's chat formatting for the reader: which characters are
/// dialogue in quotes, which carry Markdown emphasis, and which are emphasis
/// markers to hide.
///
/// Quotes follow `messageFormatting` in ST's script.js: `"…"`, `“…”`, `«…»`,
/// `「…」`, `『…』` and `＂…＂`, each closing on the same line, none inside
/// code spans or fences, and a `"` inside an HTML tag never opens one.
/// Emphasis follows showdown with ST's options: `***x***`, `**x**` and
/// `*x*`; `__x__` underlines (`underline: true`) and a word wrapped in single
/// underscores is italic (ST's underscore extension). Showdown lets emphasis
/// run on through a paragraph; here it stays within a line, so a stray `*`
/// never restyles the rest of the chapter. HTML tags and comments are
/// hidden, as ST's default (`encode_tags` off) leaves them to the browser.
final class ProseMarkup {
  ProseMarkup._(this._flags);

  /// Marks up [text], leaving the [skip] ranges (HTML blocks) alone. With
  /// [trimIndent] the whitespace that starts each line outside code is
  /// hidden too, hidden tags before it included, so a page's own indent
  /// setting is the only indent: model replies indent some paragraphs and
  /// not others.
  factory ProseMarkup.parse(
    String text, {
    Iterable<({int start, int end})> skip = const [],
    bool trimIndent = false,
  }) {
    final flags = Uint8List(text.length);
    // Skipped ranges become line breaks: nothing is found in them or across
    // them, and every index still lines up with [text].
    final units = text.codeUnits.toList();
    for (final range in skip) {
      units.fillRange(range.start, range.end, _newline);
    }
    var masked = String.fromCharCodes(units);
    // ST hides the double quotes inside tags before looking for dialogue.
    masked = masked.replaceAllMapped(_tag, (m) => m[0]!.replaceAll('"', '￾'));
    for (final m in _quoted.allMatches(masked)) {
      flags.fillRange(m.start, m.end, m.group(1) != null ? _code : quote);
    }
    // ST leaves tags unencoded (`encode_tags` is off) and DOMPurify drops
    // the ones it does not know, keeping their text: `<game>` never shows.
    // ponytail: known inline tags are hidden too; `<b>`/`<i>` styling and
    // `<br>` breaks would need their own pass.
    for (final m in _htmlTag.allMatches(masked)) {
      if (flags[m.start] == _code) continue;
      for (var i = m.start; i < m.end; i++) {
        flags[i] |= hidden;
      }
    }
    final indents = <int>[];
    if (trimIndent) {
      var lineStart = true;
      for (var i = 0; i < masked.length; i++) {
        final unit = masked.codeUnitAt(i);
        if (unit == _newline) {
          lineStart = true;
        } else if (flags[i] & hidden != 0) {
          // A hidden tag: what follows it still starts the line.
        } else if (lineStart &&
            flags[i] != _code &&
            _blank.hasMatch(masked[i])) {
          indents.add(i);
        } else {
          lineStart = false;
        }
      }
    }
    // Code is left as written: emphasis stops at it like at a line break.
    final lines = String.fromCharCodes([
      for (var i = 0; i < masked.length; i++)
        flags[i] == _code ? _newline : masked.codeUnitAt(i),
    ]);
    for (var i = 0; i < flags.length; i++) {
      if (flags[i] == _code) flags[i] = 0;
    }
    var start = 0;
    for (var i = 0; i <= lines.length; i++) {
      if (i < lines.length && lines.codeUnitAt(i) != _newline) continue;
      if (i > start) _emphasis(lines, start, i, flags);
      start = i + 1;
    }
    for (final i in indents) {
      flags[i] |= hidden;
    }
    return ProseMarkup._(flags);
  }

  /// A Markdown marker or, with `trimIndent`, an indent: not shown.
  static const hidden = 1;

  /// Dialogue, quote marks included.
  static const quote = 2;
  static const italic = 4, bold = 8, underline = 16;

  /// Marks code while parsing; never left in the result.
  static const _code = 128;
  static const _newline = 0x0a;

  final Uint8List _flags;

  /// The flags of the character at [index].
  int operator [](int index) =>
      index >= 0 && index < _flags.length ? _flags[index] : 0;

  /// Code spans and fences (kept as they are), else one kind of quote pair.
  static final _quoted = RegExp(
    '(```[\\s\\S]*?```|~~~[\\s\\S]*?~~~|``[\\s\\S]*?``|`[\\s\\S]*?`)'
    '|".*?"|“.*?”|«.*?»|「.*?」'
    '|『.*?』|＂.*?＂',
  );
  static final _tag = RegExp('<([^>]+)>');

  /// What a browser reads as a tag or comment. A tag opens with an ASCII
  /// letter (`<主角>` and `a < b` stay text) and ends on its line, since
  /// showdown's `simpleLineBreaks` puts a `<br />` in every newline.
  static final _htmlTag = RegExp(
    r'<!--[\s\S]*?-->|</?[A-Za-z][^\s/>]*(?:[ \t\f/][^>\n]*)?>',
  );

  /// Whitespace that can indent a line, full-width spaces included.
  static final _blank = RegExp('[ \t\u00a0\u2000-\u200b\u202f\u3000\ufeff]');

  /// Showdown's span passes in its order, each with its marker length and
  /// whether the content must end in a non-space (its `/\S$/` check).
  static final _passes = [
    (RegExp(r'\b___(\S[\s\S]*?)___\b'), 3, false, underline),
    (RegExp(r'\b__(\S[\s\S]*?)__\b'), 2, false, underline),
    (RegExp(r'\*\*\*(\S[\s\S]*?)\*\*\*'), 3, true, bold | italic),
    (RegExp(r'\*\*(\S[\s\S]*?)\*\*'), 2, true, bold),
    (RegExp(r'\*([^\s*][\s\S]*?)\*'), 1, true, italic),
    (RegExp(r'\b(?<!_)_(?!_)(.*?)(?<!_)_(?!_)\b'), 1, false, italic),
  ];
  static final _trailingSpace = RegExp(r'\s$');

  /// Runs each pass over the line [start]..[end] of [text]. Markers an
  /// earlier pass hid are out of the text later passes see, as showdown's
  /// earlier passes turn them into tags.
  static void _emphasis(String text, int start, int end, Uint8List flags) {
    for (final (pattern, marker, needsEnd, style) in _passes) {
      final at = [
        for (var i = start; i < end; i++)
          if (flags[i] & hidden == 0) i,
      ];
      final shown = String.fromCharCodes([
        for (final i in at) text.codeUnitAt(i),
      ]);
      for (final m in pattern.allMatches(shown)) {
        if (needsEnd && _trailingSpace.hasMatch(m.group(1)!)) continue;
        for (var k = m.start; k < m.end; k++) {
          final inside = k >= m.start + marker && k < m.end - marker;
          flags[at[k]] |= inside ? style : hidden;
        }
      }
    }
  }
}
