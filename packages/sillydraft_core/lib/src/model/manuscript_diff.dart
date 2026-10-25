import 'package:diff_match_patch/diff_match_patch.dart' as dmp;

enum ParagraphChangeKind { unchanged, removed, added }

class ParagraphChange {
  const ParagraphChange(this.kind, this.paragraphs);

  final ParagraphChangeKind kind;
  final List<String> paragraphs;
}

/// Compares whole paragraphs, retaining their original newline separators.
List<ParagraphChange> compareParagraphs(String before, String after) {
  final dictionary = <String>[];
  final ids = <String, int>{};

  String encode(String text) {
    final tokens = <int>[];
    var start = 0;
    while (start < text.length) {
      final newline = text.indexOf('\n', start);
      var end = newline < 0 ? text.length : newline + 1;
      var paragraph = text.substring(start, end);
      // shortcut: beyond 65534 unique paragraphs, group the tail; use a
      // sequence diff if chapter-sized comparisons ever need finer matching.
      if (dictionary.length >= 0xfffe && !ids.containsKey(paragraph)) {
        end = text.length;
        paragraph = text.substring(start);
      }
      tokens.add(
        ids.putIfAbsent(paragraph, () {
          dictionary.add(paragraph);
          return dictionary.length - 1;
        }),
      );
      start = end;
    }
    return String.fromCharCodes(tokens);
  }

  final oldTokens = encode(before), newTokens = encode(after);
  return [
    for (final change in dmp.diff(
      oldTokens,
      newTokens,
      checklines: false,
      timeout: .1,
    ))
      ParagraphChange(
        switch (change.operation) {
          dmp.DIFF_DELETE => ParagraphChangeKind.removed,
          dmp.DIFF_INSERT => ParagraphChangeKind.added,
          _ => ParagraphChangeKind.unchanged,
        },
        [
          for (final token in change.text.codeUnits)
            for (final match in RegExp(
              r'[^\n]*\n|[^\n]+$',
            ).allMatches(dictionary[token]))
              match.group(0)!,
        ],
      ),
  ];
}
