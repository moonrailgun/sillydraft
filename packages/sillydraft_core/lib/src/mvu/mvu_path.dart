import 'dart:convert';

/// Path and structure helpers with lodash semantics, which MVU's update
/// commands rely on (`_.get`, `_.set`, `_.has`, `_.unset`, `_.toPath`,
/// `_.merge`). Values are plain JSON data: maps, lists and primitives.
abstract final class MvuPath {
  /// Splits `a.b[0]["c d"]` into `['a', 'b', '0', 'c d']` as `_.toPath`.
  static List<String> toPath(String path) {
    final segments = <String>[];
    var i = 0;
    final buffer = StringBuffer();
    var pending = false;
    void flush() {
      segments.add(buffer.toString());
      buffer.clear();
      pending = false;
    }

    if (path.startsWith('.')) {
      segments.add('');
      i = 1;
    }
    while (i < path.length) {
      final char = path[i];
      if (char == '.') {
        if (pending) flush();
        i++;
        if (i < path.length && path[i] == '.') segments.add('');
        continue;
      }
      if (char == '[') {
        if (pending) flush();
        i++;
        if (i < path.length && (path[i] == '"' || path[i] == "'")) {
          final quote = path[i];
          i++;
          while (i < path.length && path[i] != quote) {
            if (path[i] == r'\' && i + 1 < path.length) {
              buffer.write(path[i + 1]);
              i += 2;
            } else {
              buffer.write(path[i]);
              i++;
            }
          }
          i++; // closing quote
          final close = path.indexOf(']', i);
          i = close < 0 ? path.length : close + 1;
          segments.add(buffer.toString());
          buffer.clear();
        } else {
          final close = path.indexOf(']', i);
          final inner = path.substring(i, close < 0 ? path.length : close);
          segments.add(inner.trim());
          i = close < 0 ? path.length : close + 1;
        }
        continue;
      }
      buffer.write(char);
      pending = true;
      i++;
    }
    if (pending) flush();
    return segments;
  }

  /// A bracket path whose every segment is a quoted literal, as MVU writes
  /// JSON Patch pointers: `["a.b"]["c"]`.
  static String fromSegments(List<String> segments) => segments
      .map((s) => '["${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"]')
      .join();

  static bool _isIndex(String segment) =>
      segment.isNotEmpty && RegExp(r'^\d+$').hasMatch(segment);

  static Object? get(Object? root, String path, [Object? fallback]) {
    if (path.isEmpty) return root ?? fallback;
    Object? current = root;
    for (final segment in toPath(path)) {
      if (current is Map) {
        if (!current.containsKey(segment)) return fallback;
        current = current[segment];
      } else if (current is List && _isIndex(segment)) {
        final index = int.tryParse(segment);
        if (index == null || index >= current.length) return fallback;
        current = current[index];
      } else {
        return fallback;
      }
    }
    return current;
  }

  static bool has(Object? root, String path) {
    if (path.isEmpty) return root != null;
    Object? current = root;
    for (final segment in toPath(path)) {
      if (current is Map) {
        if (!current.containsKey(segment)) return false;
        current = current[segment];
      } else if (current is List && _isIndex(segment)) {
        final index = int.parse(segment);
        if (index >= current.length) return false;
        current = current[index];
      } else {
        return false;
      }
    }
    return true;
  }

  /// Sets [value] at [path], creating intermediate maps (or lists when the
  /// next segment is an index) as `_.set` does. [root] must be a map.
  static void set(Map<String, dynamic> root, String path, Object? value) {
    final segments = toPath(path);
    if (segments.isEmpty) return;
    Object? current = root;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      final last = i == segments.length - 1;
      if (current is Map) {
        if (last) {
          current[segment] = value;
          return;
        }
        Object? next = current[segment];
        if (next is! Map && next is! List) {
          next = _isIndex(segments[i + 1]) ? <Object?>[] : <String, dynamic>{};
          current[segment] = next;
        }
        current = next;
      } else if (current is List) {
        if (!_isIndex(segment)) return;
        final index = int.parse(segment);
        while (current.length <= index) {
          current.add(null);
        }
        if (last) {
          current[index] = value;
          return;
        }
        Object? next = current[index];
        if (next is! Map && next is! List) {
          next = _isIndex(segments[i + 1]) ? <Object?>[] : <String, dynamic>{};
          current[index] = next;
        }
        current = next;
      } else {
        return;
      }
    }
  }

  /// Removes the value at [path]; list elements are spliced out rather than
  /// left as holes. Returns whether anything was removed.
  static bool unset(Object? root, String path) {
    final segments = toPath(path);
    if (segments.isEmpty) return false;
    final parent = segments.length == 1
        ? root
        : get(root, fromSegments(segments.sublist(0, segments.length - 1)));
    final key = segments.last;
    if (parent is Map) {
      if (!parent.containsKey(key)) return false;
      parent.remove(key);
      return true;
    }
    if (parent is List && _isIndex(key)) {
      final index = int.parse(key);
      if (index >= parent.length) return false;
      parent.removeAt(index);
      return true;
    }
    return false;
  }

  static T clone<T>(T value) => switch (value) {
    Map m => Map<String, dynamic>.fromEntries(
      m.entries.map((e) => MapEntry('${e.key}', clone<Object?>(e.value))),
    ) as T,
    List l => l.map(clone<Object?>).toList() as T,
    _ => value,
  };

  static bool equals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final entry in a.entries) {
        if (!b.containsKey(entry.key) || !equals(entry.value, b[entry.key])) {
          return false;
        }
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!equals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is num && b is num) return a == b;
    return a == b;
  }

  /// `_.merge`: recursive for maps, index-wise for lists.
  static Object? merge(Object? target, Object? source) {
    if (target is Map && source is Map) {
      for (final entry in source.entries) {
        final key = '${entry.key}';
        target[key] = merge(target[key], entry.value);
      }
      return target;
    }
    if (target is List && source is List) {
      for (var i = 0; i < source.length; i++) {
        if (i < target.length) {
          target[i] = merge(target[i], source[i]);
        } else {
          target.add(clone(source[i]));
        }
      }
      return target;
    }
    if (source is Map) {
      return merge(<String, dynamic>{}, source);
    }
    if (source is List) return clone(source);
    return source;
  }

  /// MVU's `correctlyMerge`: like [merge], but a list in [source] replaces
  /// the target list instead of merging element by element.
  static Object? mergeReplacingLists(Object? target, Object? source) {
    if (target is Map && source is Map) {
      for (final entry in source.entries) {
        final key = '${entry.key}';
        target[key] = mergeReplacingLists(target[key], entry.value);
      }
      return target;
    }
    if (source is List) return clone(source);
    if (source is Map) return mergeReplacingLists(<String, dynamic>{}, source);
    return source;
  }

  /// Whether [value] is `[value, "description"]`.
  static bool isValueWithDescription(Object? value) =>
      value is List && value.length == 2 && value[1] is String;

  /// `JSON.stringify` of a value, for display strings and macros.
  static String stringify(Object? value) =>
      value == null ? 'null' : jsonEncode(value);
}
