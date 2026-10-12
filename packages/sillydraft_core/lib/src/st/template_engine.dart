final class UnsupportedTemplate implements Exception {
  const UnsupportedTemplate(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The noEscape Handlebars subset used by official context templates.
/// Unknown helpers fail explicitly; missing value expressions yield empty text.
final class TemplateEngine {
  String render(String template, Map<String, Object?> values) =>
      _render(template, values, 0);
  String _render(String source, Map<String, Object?> values, int level) {
    if (level > 32) throw const UnsupportedTemplate('模板嵌套过深');
    final out = StringBuffer();
    var cursor = 0;
    final tags = RegExp(r'\{\{\{?[\s\S]*?\}\}\}?').allMatches(source).toList();
    for (var index = 0; index < tags.length; index++) {
      final tag = tags[index];
      if (tag.start < cursor) continue;
      out.write(source.substring(cursor, tag.start));
      final token = tag.group(0)!;
      final body = token
          .replaceFirst(RegExp(r'^\{\{\{?'), '')
          .replaceFirst(RegExp(r'\}\}\}?$'), '')
          .trim();
      cursor = tag.end;
      if (body.startsWith('!')) continue;
      if (body.startsWith('#')) {
        final parts = body.substring(1).split(RegExp(r'\s+'));
        if (!['if', 'unless', 'each', 'with'].contains(parts.first) ||
            parts.length != 2) {
          throw UnsupportedTemplate('未支持的 Handlebars helper：$body');
        }
        var depth = 0;
        RegExpMatch? otherwise, close;
        for (var j = index + 1; j < tags.length; j++) {
          final inner = tags[j]
              .group(0)!
              .replaceAll(RegExp(r'^\{\{|\}\}$'), '')
              .trim();
          if (inner.startsWith('#')) depth++;
          if (inner.startsWith('/')) {
            if (depth == 0) {
              if (inner != '/${parts.first}') {
                throw const UnsupportedTemplate('模板块未配对');
              }
              close = tags[j];
              index = j;
              break;
            }
            depth--;
          }
          if (depth == 0 && inner == 'else') otherwise = tags[j];
        }
        if (close == null) throw const UnsupportedTemplate('模板缺少结束块');
        final yes = source.substring(tag.end, otherwise?.start ?? close.start);
        final no = otherwise == null
            ? ''
            : source.substring(otherwise.end, close.start);
        final value = _lookup(values, parts[1]);
        if (parts.first == 'each' && value is List && value.isNotEmpty) {
          for (final (i, item) in value.indexed) {
            out.write(
              _render(yes, {
                ...values,
                'this': item,
                '@index': i,
                '@first': i == 0,
                '@last': i == value.length - 1,
                if (item is Map<String, Object?>) ...item,
              }, level + 1),
            );
          }
        } else {
          var truth =
              value != null &&
              value != false &&
              value != '' &&
              value != 0 &&
              !(value is Iterable && value.isEmpty);
          if (parts.first == 'unless') truth = !truth;
          out.write(
            _render(truth ? yes : no, {
              ...values,
              if (parts.first == 'with' && value is Map<String, Object?>)
                ...value,
            }, level + 1),
          );
        }
        cursor = close.end;
      } else if (body.startsWith('/') || body == 'else') {
        throw const UnsupportedTemplate('模板块未配对');
      } else if (body.contains(RegExp(r'\s|[()>]'))) {
        throw UnsupportedTemplate('未支持的 Handlebars 表达式：$body');
      } else {
        out.write(_lookup(values, body) ?? '');
      }
    }
    out.write(source.substring(cursor));
    return out.toString();
  }

  Object? _lookup(Map<String, Object?> values, String path) {
    Object? value = values;
    for (final key in path.split('.')) {
      if (value is! Map<String, Object?>) return null;
      value = value[key];
    }
    return value;
  }
}
