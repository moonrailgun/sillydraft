import 'mvu_path.dart';

/// Schema generation and template rules of MagVarUpdate: a schema mirrors
/// `stat_data`, marks which containers may grow (`$meta.extensible`, the
/// `$__META_EXTENSIBLE__$` marker, `$arrayMeta`) and which keys are
/// required, and carries templates applied to inserted elements.
abstract final class MvuSchema {
  static const extensibleMarker = r'$__META_EXTENSIBLE__$';

  static Map<String, dynamic> emptyObject() => {
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  /// Generates a schema for [data], reading and removing `$meta` markers in
  /// place, inheriting metadata from [old].
  static Map<String, dynamic> generate(
    Object? data, [
    Map<String, dynamic>? old,
    bool parentRecursive = false,
  ]) {
    // A card's own schema script replaced MVU's checks: keep them off.
    if (old != null && old['type'] == 'any') return {'type': 'any'};
    if (data is List) {
      var extensible = false;
      var recursive = parentRecursive;
      Map<String, dynamic>? oldElement;
      Object? template;
      if (old != null && old['type'] == 'array') {
        extensible = old['extensible'] == true;
        recursive = old['recursiveExtensible'] == true || parentRecursive;
        oldElement = old['elementType'] is Map
            ? (old['elementType'] as Map).cast<String, dynamic>()
            : null;
        template = old['template'];
      }
      final metaIndex = data.indexWhere(
        (item) =>
            item is Map &&
            item[r'$arrayMeta'] == true &&
            item.containsKey(r'$meta'),
      );
      if (metaIndex >= 0) {
        final meta = (data[metaIndex] as Map)[r'$meta'];
        if (meta is Map) {
          if (meta['extensible'] != null) {
            extensible = meta['extensible'] == true;
          }
          if (meta['template'] != null) template = meta['template'];
        }
        data.removeAt(metaIndex);
      }
      final markerIndex = data.indexOf(extensibleMarker);
      if (markerIndex >= 0) {
        extensible = true;
        data.removeAt(markerIndex);
      }
      final node = <String, dynamic>{
        'type': 'array',
        'extensible': extensible || parentRecursive,
        'recursiveExtensible': recursive,
        'elementType': data.isNotEmpty
            ? generate(data.first, oldElement, recursive)
            : {'type': 'any'},
      };
      if (template != null) node['template'] = template;
      return node;
    }
    if (data is Map) {
      var oldExtensible = false;
      var oldRecursive = parentRecursive;
      Map<String, dynamic>? oldProperties;
      if (old != null && old['type'] == 'object') {
        oldExtensible = old['extensible'] == true;
        oldRecursive = old['recursiveExtensible'] == true || parentRecursive;
        oldProperties = old['properties'] is Map
            ? (old['properties'] as Map).cast<String, dynamic>()
            : null;
      }
      final meta = data[r'$meta'] is Map
          ? (data[r'$meta'] as Map).cast<String, dynamic>()
          : null;
      final node = <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'extensible':
            oldExtensible ||
            meta?['extensible'] == true ||
            meta?['recursiveExtensible'] == true ||
            parentRecursive,
        'recursiveExtensible':
            oldRecursive || meta?['recursiveExtensible'] == true,
      };
      if (meta?['template'] != null) {
        node['template'] = meta!['template'];
      } else if (old != null &&
          old['type'] == 'object' &&
          old['template'] != null) {
        node['template'] = old['template'];
      }
      data.remove(r'$meta');
      final properties = node['properties'] as Map<String, dynamic>;
      for (final key in data.keys.map((k) => '$k').toList()) {
        final oldChild = oldProperties?[key] is Map
            ? (oldProperties![key] as Map).cast<String, dynamic>()
            : null;
        final childRecursive =
            node['extensible'] != false && node['recursiveExtensible'] == true;
        final child = generate(data[key], oldChild, childRecursive);
        var required = node['extensible'] != true;
        final requiredList = meta?['required'];
        if (requiredList is List && requiredList.contains(key)) {
          required = true;
        }
        if (oldChild?['required'] == false) {
          required = false;
        } else if (oldChild?['required'] == true) {
          required = true;
        }
        properties[key] = {...child, 'required': required};
      }
      return node;
    }
    return {
      'type': switch (data) {
        String() => 'string',
        num() => 'number',
        bool() => 'boolean',
        _ => 'any',
      },
    };
  }

  /// The schema node for a data path, stepping into `elementType` for
  /// numeric segments; null when the path is not described.
  static Map<String, dynamic>? forPath(
    Map<String, dynamic>? schema,
    String path,
  ) {
    if (schema == null) return null;
    if (path.isEmpty) return schema;
    Map<String, dynamic>? current = schema;
    for (final segment in MvuPath.toPath(path)) {
      if (current == null) return null;
      if (RegExp(r'^\d+$').hasMatch(segment)) {
        if (current['type'] != 'array') return null;
        current = current['elementType'] is Map
            ? (current['elementType'] as Map).cast<String, dynamic>()
            : null;
      } else if (current['type'] == 'object' &&
          current['properties'] is Map &&
          (current['properties'] as Map)[segment] is Map) {
        current = ((current['properties'] as Map)[segment] as Map)
            .cast<String, dynamic>();
      } else {
        return null;
      }
    }
    return current;
  }

  /// Regenerates the schema from [statData] keeping the old metadata and
  /// root options; [statData] is left untouched.
  static Map<String, dynamic> reconcile(
    Map<String, dynamic> statData,
    Map<String, dynamic>? old,
  ) {
    if (old != null && old['type'] == 'any') return old;
    final clone = MvuPath.clone(statData);
    final next = generate(clone, old);
    if (next['type'] != 'object') return old ?? emptyObject();
    for (final key in const [
      'strictTemplate',
      'strictSet',
      'concatTemplateArray',
    ]) {
      if (old?[key] != null) next[key] = old![key];
      final meta = statData[r'$meta'];
      if (meta is Map && meta.containsKey(key)) next[key] = meta[key];
    }
    return next;
  }

  /// Removes `$meta`, `$arrayMeta` elements and the extensible marker.
  static void cleanUpMetadata(Object? data) {
    if (data is List) {
      for (var i = data.length - 1; i >= 0; i--) {
        final item = data[i];
        if (item == extensibleMarker ||
            (item is Map &&
                item[r'$arrayMeta'] == true &&
                item.containsKey(r'$meta'))) {
          data.removeAt(i);
        } else {
          cleanUpMetadata(item);
        }
      }
    } else if (data is Map) {
      data.remove(r'$meta');
      for (final value in data.values) {
        cleanUpMetadata(value);
      }
    }
  }

  /// Applies a template to an inserted value; the value's own fields win.
  static Object? applyTemplate(
    Object? value,
    Object? template, {
    bool strictArrayCast = false,
    bool concatArrays = true,
  }) {
    if (template == null) return value;
    final valueIsObject = value is Map;
    final valueIsArray = value is List;
    final templateIsArray = template is List;
    if (valueIsObject && !templateIsArray) {
      if (template is! Map) return value;
      final merged = MvuPath.merge(<String, dynamic>{}, template);
      return MvuPath.merge(merged, value);
    }
    if (valueIsArray && templateIsArray) {
      if (concatArrays) return [...value, ...MvuPath.clone(template)];
      return MvuPath.merge(MvuPath.clone(template), value);
    }
    if ((valueIsObject || valueIsArray) && templateIsArray != valueIsArray) {
      return value;
    }
    if (!valueIsObject && !valueIsArray && template is Map) return value;
    if (!valueIsObject && !valueIsArray && templateIsArray) {
      if (strictArrayCast) return value;
      if (concatArrays) return [value, ...MvuPath.clone(template)];
      return MvuPath.merge(MvuPath.clone(template), [value]);
    }
    return value;
  }
}
