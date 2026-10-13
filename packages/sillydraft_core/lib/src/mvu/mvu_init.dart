import 'mvu_data.dart';
import 'mvu_path.dart';
import 'mvu_schema.dart';
import 'mvu_value.dart';

/// A world book entry that seeds variables: its comment contains
/// `[InitVar]` (any case), enabled or not.
final class MvuInitEntry {
  const MvuInitEntry({
    required this.book,
    required this.comment,
    required this.content,
  });
  final String book, comment, content;

  static bool matches(String comment) =>
      comment.toLowerCase().contains('[initvar]');
}

/// Initial variable loading, as MagVarUpdate's `variable_init`.
abstract final class MvuInit {
  /// The YAML or JSON payload of an entry: an `<initvar>` wrapper and a
  /// code fence are removed first.
  static String payload(String content) {
    var text = content.trim();
    final xml = RegExp(
      r'.*<initvar>.*\n([\s\S]*)\n.*</initvar>.*',
      multiLine: true,
    ).firstMatch(text);
    if (xml != null) text = xml.group(1)!;
    final fence = RegExp(
      r'```.*\n([\s\S]*)\n```',
      multiLine: true,
    ).firstMatch(text.trim());
    if (fence != null) text = fence.group(1)!;
    return text;
  }

  /// Merges every `[InitVar]` entry of books not yet initialised into
  /// [data]. Existing top-level keys of `stat_data` win over the entries.
  /// Returns whether any book was loaded; parse failures are reported in
  /// [errors] and skip that book.
  static bool load(
    MvuData data,
    List<MvuInitEntry> entries, {
    String Function(String)? substitute,
    List<String>? errors,
  }) {
    var updated = false;
    final books = <String, List<MvuInitEntry>>{};
    for (final entry in entries) {
      books.putIfAbsent(entry.book, () => []).add(entry);
    }
    for (final book in books.entries) {
      if (data.initializedLorebooks.containsKey(book.key)) continue;
      data.initializedLorebooks[book.key] = <Object?>[];
      try {
        final merged = <String, dynamic>{};
        for (final entry in book.value) {
          if (!MvuInitEntry.matches(entry.comment)) continue;
          final text = payload(entry.content);
          final content = substitute == null ? text : substitute(text);
          final parsed = MvuValue.parseStructured(content);
          if (parsed is Map) {
            MvuPath.mergeReplacingLists(merged, parsed);
          } else if (parsed != null) {
            throw FormatException('条目 ${entry.comment} 不是对象');
          }
        }
        data.statData = {...merged, ...data.statData};
        updated = true;
      } on FormatException catch (error) {
        errors?.add('初始变量条目解析失败（${book.key}）：${error.message}');
      }
    }
    return updated;
  }

  /// Builds the schema from the freshly loaded data and strips metadata,
  /// as `initCheck` does once all books are loaded.
  static void finalizeSchema(MvuData data) {
    final forSchema = MvuPath.clone(data.statData);
    final generated = MvuSchema.generate(forSchema, data.schema);
    if (generated['type'] == 'object') {
      final meta = data.statData[r'$meta'];
      if (meta is Map) {
        for (final key in const [
          'strictTemplate',
          'concatTemplateArray',
          'strictSet',
        ]) {
          if (meta.containsKey(key)) generated[key] = meta[key];
        }
      }
      data.schema = generated;
    }
    MvuSchema.cleanUpMetadata(data.statData);
  }

  /// `<initvar>` blocks inside an opening greeting replace the world book
  /// values entirely; returns the merged object, or null when absent.
  static Map<String, dynamic>? openingOverride(
    String opening, {
    String Function(String)? substitute,
    List<String>? errors,
  }) {
    final matches = RegExp(
      r'<(initvar)>(?:\s*```.*)?([\s\S]*?)(?:```\s*)?</\1>',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(opening);
    Map<String, dynamic>? result;
    for (final match in matches) {
      try {
        final text = match.group(2)!;
        final parsed = MvuValue.parseStructured(
          substitute == null ? text : substitute(text),
        );
        if (parsed is Map) {
          result ??= <String, dynamic>{};
          MvuPath.mergeReplacingLists(result, parsed);
        }
      } on FormatException catch (error) {
        errors?.add('开场中的 <initvar> 解析失败：${error.message}');
      }
    }
    return result;
  }
}
