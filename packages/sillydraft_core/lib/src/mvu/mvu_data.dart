import 'dart:convert';

import 'mvu_commands.dart';
import 'mvu_path.dart';
import 'mvu_schema.dart';
import 'mvu_value.dart';

/// The marker MVU appends to every reply. A card's display regex turns it
/// into the status bar; prompts never carry it.
const mvuStatusPlaceholder = '<StatusPlaceHolderImpl/>';

/// Text without the placeholder (and the line breaks around it) and
/// without the model's own copy of the state listing, as MVU strips both
/// from the saved message.
String stripMvuMarkup(String text) =>
    text.replaceAll(_statusListing, '').replaceAll(_placeholderRun, '');

/// Whether [stripMvuMarkup] would change [text].
bool hasMvuMarkup(String text) =>
    _placeholderRun.hasMatch(text) || _statusListing.hasMatch(text);

/// The state listing cards show the model (`status_current_variable`,
/// also written in the plural), echoed back by some replies.
final _statusListing = RegExp(
  r'<(status_current_variables?)>(?:(?!<\1>).)*</\1?>',
  caseSensitive: false,
  dotAll: true,
);
final _placeholderRun = RegExp(
  r'\n*<StatusPlaceHolderImpl/>\n*',
  caseSensitive: false,
);

/// The variable record MagVarUpdate keeps on every message: the current
/// values, a display copy where changed paths read `old->new (reason)`,
/// the changes of the latest update, the structure schema and which world
/// books initialised it. Stored as the `stat_data`, `display_data`,
/// `delta_data`, `schema` and `initialized_lorebooks` variables of a scene.
final class MvuData {
  MvuData({
    Map<String, dynamic>? statData,
    Map<String, dynamic>? displayData,
    Map<String, dynamic>? deltaData,
    Map<String, dynamic>? schema,
    Map<String, dynamic>? initializedLorebooks,
  }) : statData = statData ?? <String, dynamic>{},
       displayData = displayData ?? <String, dynamic>{},
       deltaData = deltaData ?? <String, dynamic>{},
       schema = schema ?? MvuSchema.emptyObject(),
       initializedLorebooks = initializedLorebooks ?? <String, dynamic>{};

  Map<String, dynamic> statData, displayData, deltaData, schema;
  Map<String, dynamic> initializedLorebooks;

  static const keys = [
    'stat_data',
    'display_data',
    'delta_data',
    'schema',
    'initialized_lorebooks',
  ];

  /// Whether a variable table carries MVU data.
  static bool present(Map<String, dynamic> variables) =>
      variables['stat_data'] is Map;

  /// Whether a stored (string-valued) variable table carries MVU data.
  static bool presentIn(Map<String, String> stored) =>
      stored['stat_data'] != null && stored['stat_data']!.startsWith('{');

  factory MvuData.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic>? map(String key) => json[key] is Map
        ? MvuPath.clone((json[key] as Map).cast<String, dynamic>())
        : null;
    final books = json['initialized_lorebooks'];
    return MvuData(
      statData: map('stat_data'),
      displayData: map('display_data'),
      deltaData: map('delta_data'),
      schema: map('schema'),
      initializedLorebooks: books is List
          ? {for (final name in books) '$name': <Object?>[]}
          : map('initialized_lorebooks'),
    );
  }

  /// Reads the record out of stored variables; null when absent.
  static MvuData? fromStored(Map<String, String> stored) {
    if (!presentIn(stored)) return null;
    Map<String, dynamic>? decode(String key) {
      final raw = stored[key];
      if (raw == null) return null;
      try {
        final value = jsonDecode(raw);
        return value is Map ? value.cast<String, dynamic>() : null;
      } on FormatException {
        return null;
      }
    }

    return MvuData.fromJson({for (final key in keys) key: ?decode(key)});
  }

  Map<String, dynamic> toJson() => {
    'stat_data': statData,
    'display_data': displayData,
    'delta_data': deltaData,
    'schema': schema,
    'initialized_lorebooks': initializedLorebooks,
  };

  /// The record as stored variables, to merge into a scene's local table.
  Map<String, String> toStored() => {
    for (final entry in toJson().entries) entry.key: jsonEncode(entry.value),
  };

  MvuData clone() => MvuData.fromJson(MvuPath.clone(toJson()));
}

/// The outcome of applying a message to a record.
final class MvuUpdateResult {
  const MvuUpdateResult({
    required this.modified,
    required this.commands,
    required this.errors,
  });
  final bool modified;
  final List<MvuCommand> commands;

  /// Commands that were skipped, with why; the rest still applied.
  final List<String> errors;
}

/// Applies the update commands of a reply to an [MvuData] in place, with
/// MagVarUpdate's rules: `set` only on existing paths and through
/// `[value, description]` pairs; `insert` honouring the schema's extensible
/// flags and templates; `delete` by path, index, key or value; `add` for
/// numeric deltas and ISO date milliseconds; `move` from JSON Patch.
abstract final class MvuUpdater {
  static MvuUpdateResult apply(
    String message,
    MvuData data, {
    String Function(String)? substitute,
  }) {
    final before = data.clone();
    final outStatus = MvuPath.clone(data.statData);
    final delta = <String, dynamic>{};
    final content = substitute == null ? message : substitute(message);
    final commands = MvuCommandParser.extract(content);
    final errors = <String>[];
    final schema = data.schema;
    final strictTemplate = schema['strictTemplate'] == true;
    final concatArrays = schema['concatTemplateArray'] != false;
    final strictSet = schema['strictSet'] == true;

    for (final command in commands) {
      command.type = switch (command.type) {
        'remove' || 'unset' => 'delete',
        'assign' => 'insert',
        final other => other,
      };
      if (!command.fromJsonPatch && command.args.isNotEmpty) {
        command.args[0] = MvuValue.pathFix(
          MvuValue.trimQuotesAndBackslashes(command.args[0]),
        );
      }
    }

    for (final command in commands) {
      final path = command.args.isEmpty ? '' : command.args[0];
      final reasonText = command.reason.isEmpty ? '' : '(${command.reason})';
      String? display;
      void fail(String why) => errors.add('${command.fullMatch}\n$why');
      final stat = data.statData;

      switch (command.type) {
        case 'set':
          if (path.isNotEmpty && !MvuPath.has(stat, path)) {
            fail('路径 $path 不存在，未执行 set $reasonText');
            continue;
          }
          Object? oldValue = path.isEmpty
              ? MvuPath.clone(stat)
              : MvuPath.get(stat, path);
          final newValue = MvuValue.parseCommandValue(command.args.last);
          var pathIsVwd = false;
          if (!strictSet &&
              oldValue is List &&
              oldValue.length == 2 &&
              oldValue[1] is String &&
              oldValue[0] is! List) {
            final pair = oldValue;
            final previous = MvuPath.clone(pair[0]);
            pair[0] = pair[0] is num && newValue != null
                ? _toNumber(newValue)
                : newValue;
            oldValue = previous;
            pathIsVwd = true;
          } else if (oldValue is num && newValue is String) {
            MvuPath.set(stat, path, _toNumber(newValue));
          } else if (path.isNotEmpty) {
            MvuPath.set(stat, path, newValue);
          } else if (newValue is Map) {
            data.statData = newValue.cast<String, dynamic>();
          } else {
            fail('根路径只能设置为对象 $reasonText');
            continue;
          }
          Object? finalValue = path.isEmpty
              ? data.statData
              : MvuPath.get(data.statData, path);
          if (pathIsVwd && finalValue is List) finalValue = finalValue[0];
          if (!strictSet &&
              MvuPath.isValueWithDescription(oldValue) &&
              finalValue is List) {
            display =
                '${_show((oldValue as List)[0])}->${_show(finalValue[0])} $reasonText';
          } else {
            display = '${_show(oldValue)}->${_show(finalValue)} $reasonText';
          }

        case 'insert':
          final existing = path.isEmpty ? stat : MvuPath.get(stat, path);
          final targetSchema = MvuSchema.forPath(schema, path);
          if (existing != null && existing is! List && existing is! Map) {
            fail('路径 $path 是基本类型，不能插入 $reasonText');
            continue;
          }
          if (targetSchema != null) {
            if (targetSchema['type'] == 'object' &&
                targetSchema['extensible'] == false) {
              if (command.args.length == 2) {
                fail('对象 $path 不可扩展，不能合并 $reasonText');
                continue;
              }
              if (command.args.length >= 3) {
                final newKey = '${MvuValue.parseCommandValue(command.args[1])}';
                final properties = targetSchema['properties'];
                if (properties is! Map || !properties.containsKey(newKey)) {
                  fail('对象 $path 不可扩展，不能新增键 $newKey $reasonText');
                  continue;
                }
              }
            } else if (targetSchema['type'] == 'array' &&
                targetSchema['extensible'] != true) {
              fail('数组 $path 不可扩展 $reasonText');
              continue;
            }
          } else if (path.isNotEmpty) {
            final parts = MvuPath.toPath(path);
            final parent = MvuPath.fromSegments(
              parts.sublist(0, parts.length - 1),
            );
            if (parts.length > 1 && MvuPath.get(stat, parent) == null) {
              fail('路径 $path 的父级不存在 $reasonText');
              continue;
            }
          }
          var successful = false;
          final template = targetSchema?['template'];
          if (command.args.length == 2) {
            var value = MvuValue.parseCommandValue(command.args[1]);
            Object? collection = path.isEmpty ? stat : MvuPath.get(stat, path);
            if (collection is! List && collection is! Map) {
              collection = value is List ? <Object?>[] : <String, dynamic>{};
              MvuPath.set(stat, path, collection);
            }
            if (collection is List) {
              value = MvuSchema.applyTemplate(
                value,
                template,
                strictArrayCast: strictTemplate,
                concatArrays: concatArrays,
              );
              collection.add(value);
              display =
                  'ASSIGNED ${_json(value)} into array \'$path\' $reasonText';
              successful = true;
            } else if (collection is Map) {
              if (value is Map) {
                MvuPath.merge(collection, value);
                display =
                    'MERGED object ${_json(value)} into object \'$path\' $reasonText';
                successful = true;
              } else {
                fail(value is List ? '不能把数组合并进对象 $path' : '不能把非对象合并进对象 $path');
                continue;
              }
            }
          } else if (command.args.length >= 3) {
            var value = MvuValue.parseCommandValue(command.args[2]);
            final keyOrIndex = MvuValue.parseCommandValue(command.args[1]);
            Object? collection = path.isEmpty ? stat : MvuPath.get(stat, path);
            if (collection is List &&
                (keyOrIndex is num || keyOrIndex == '-')) {
              final index = keyOrIndex == '-'
                  ? collection.length
                  : (keyOrIndex as num).toInt().clamp(0, collection.length);
              final label = keyOrIndex == '-' || keyOrIndex == -1
                  ? 'tail'
                  : '$keyOrIndex';
              value = MvuSchema.applyTemplate(
                value,
                template,
                strictArrayCast: strictTemplate,
                concatArrays: concatArrays,
              );
              collection.insert(index, value);
              display =
                  'ASSIGNED ${_json(value)} into \'$path\' at index $label $reasonText';
              successful = true;
            } else if (collection is Map) {
              value = MvuSchema.applyTemplate(
                value,
                template,
                strictArrayCast: strictTemplate,
                concatArrays: concatArrays,
              );
              collection['$keyOrIndex'] = value;
              display =
                  'ASSIGNED key \'$keyOrIndex\' with value ${_json(value)} into object \'$path\' $reasonText';
              successful = true;
            } else {
              collection = <String, dynamic>{};
              MvuPath.set(stat, path, collection);
              value = MvuSchema.applyTemplate(
                value,
                template,
                strictArrayCast: strictTemplate,
                concatArrays: concatArrays,
              );
              collection['$keyOrIndex'] = value;
              display =
                  'CREATED object at \'$path\' and ASSIGNED key \'$keyOrIndex\' $reasonText';
              successful = true;
            }
          }
          if (!successful) {
            fail('insert 参数无效：$path');
            continue;
          }
          final newValue = path.trim().isEmpty ? stat : MvuPath.get(stat, path);
          if (targetSchema != null) {
            try {
              final generated = MvuSchema.generate(
                MvuPath.clone(newValue),
                targetSchema,
              );
              MvuPath.merge(targetSchema, generated);
              MvuSchema.cleanUpMetadata(newValue);
            } catch (error) {
              fail('模板解析失败：$path：$error');
            }
          }

        case 'delete':
          final parts = MvuPath.toPath(path);
          final last = parts.isEmpty ? '' : parts.last;
          final isArrayElementPath = RegExp(r'^\d+$').hasMatch(last);
          if (command.args.length == 1 && isArrayElementPath) {
            final containerPath = MvuPath.fromSegments(
              parts.sublist(0, parts.length - 1),
            );
            final container = MvuPath.get(stat, containerPath);
            final index = int.parse(last);
            if (container is List && index < container.length) {
              container.removeAt(index);
              display =
                  'REMOVED item from \'$containerPath\' at index $index $reasonText';
              break;
            }
          }
          if (!MvuPath.has(stat, path)) {
            fail('路径 $path 不存在，未执行删除');
            continue;
          }
          var containerPath = path;
          Object? keyOrIndex;
          if (command.args.length > 1) {
            keyOrIndex = MvuValue.parseCommandValue(command.args[1]);
            if (keyOrIndex is String) {
              keyOrIndex = MvuValue.trimQuotesAndBackslashes(keyOrIndex);
            }
          } else if (parts.isNotEmpty) {
            keyOrIndex = isArrayElementPath ? int.parse(last) : last;
            containerPath = MvuPath.fromSegments(
              parts.sublist(0, parts.length - 1),
            );
          }
          if (keyOrIndex == null) {
            fail('无法确定要删除的目标：$path $reasonText');
            continue;
          }
          if (containerPath.isNotEmpty && !MvuPath.has(stat, containerPath)) {
            fail('容器路径 $containerPath 不存在 $reasonText');
            continue;
          }
          final containerSchema = MvuSchema.forPath(schema, containerPath);
          if (containerSchema != null) {
            if (containerSchema['type'] == 'array' &&
                containerSchema['extensible'] != true) {
              fail('数组 $containerPath 不可扩展，不能删除元素 $reasonText');
              continue;
            }
            if (containerSchema['type'] == 'object') {
              final properties = containerSchema['properties'];
              final key = '$keyOrIndex';
              if (properties is Map &&
                  properties[key] is Map &&
                  (properties[key] as Map)['required'] == true) {
                fail('键 $key 是 $containerPath 的必需属性，不能删除 $reasonText');
                continue;
              }
            }
          }
          final target = command.args.length > 1
              ? MvuValue.parseCommandValue(command.args[1])
              : null;
          var removed = false;
          if (command.args.length <= 1) {
            MvuPath.unset(stat, path);
            display = 'REMOVED path \'$path\' $reasonText';
            removed = true;
          } else {
            final collection = MvuPath.get(stat, path);
            if (collection is! List && collection is! Map) {
              fail('路径 $path 不是集合，不能删除元素 $reasonText');
              continue;
            }
            if (collection is List) {
              var index = -1;
              if (target is num) {
                index = target.toInt();
              } else {
                index = collection.indexWhere(
                  (item) => MvuPath.equals(item, target),
                );
              }
              if (index >= 0 && index < collection.length) {
                collection.removeAt(index);
                removed = true;
                display = 'REMOVED item from \'$path\' $reasonText';
              }
            } else if (collection is Map) {
              if (target is num) {
                final keys = collection.keys.toList();
                final index = target.toInt();
                if (index >= 0 && index < keys.length) {
                  final key = keys[index];
                  collection.remove(key);
                  removed = true;
                  display =
                      'REMOVED ${index + 1}th entry (\'$key\') from object \'$path\' $reasonText';
                }
              } else {
                final key = '$target';
                if (collection.containsKey(key)) {
                  collection.remove(key);
                  removed = true;
                  display =
                      'REMOVED key \'$key\' from object \'$path\' $reasonText';
                }
              }
            }
          }
          if (!removed) {
            fail('删除失败：$path');
            continue;
          }

        case 'add':
          if (!MvuPath.has(stat, path)) {
            fail('路径 $path 不存在，未执行 add $reasonText');
            continue;
          }
          final initial = MvuPath.clone(MvuPath.get(stat, path));
          final oldValue = MvuPath.get(stat, path);
          final pair =
              oldValue is List &&
                  MvuPath.isValueWithDescription(oldValue) &&
                  oldValue[0] is! Map &&
                  oldValue[0] is! List
              ? oldValue
              : null;
          final isVwd = pair != null;
          final current = pair != null ? pair[0] : oldValue;
          DateTime? date;
          if (current is String && num.tryParse(current) == null) {
            date = DateTime.tryParse(current);
          }
          if (command.args.length != 2) {
            fail('add 参数无效：$path $reasonText');
            continue;
          }
          final deltaValue = MvuValue.parseCommandValue(command.args[1]);
          if (date != null) {
            if (deltaValue is! num) {
              fail('日期增量 ${command.args[1]} 不是数字 $reasonText');
              continue;
            }
            final next = date
                .add(Duration(milliseconds: deltaValue.toInt()))
                .toUtc()
                .toIso8601String();
            if (pair != null) {
              pair[0] = next;
            } else {
              MvuPath.set(stat, path, next);
            }
          } else if (current is num) {
            if (deltaValue is! num) {
              fail('增量 ${command.args[1]} 不是数字 $reasonText');
              continue;
            }
            final sum = _precise(current + deltaValue);
            if (pair != null) {
              pair[0] = sum;
            } else {
              MvuPath.set(stat, path, sum);
            }
          } else {
            fail('路径 $path 的值不能做加法 $reasonText');
            continue;
          }
          final finalValue = MvuPath.get(stat, path);
          display = isVwd
              ? '${_show((initial as List)[0])}->${_show((finalValue as List)[0])} $reasonText'
              : '${_show(initial)}->${_show(finalValue)} $reasonText';

        case 'move':
          final from = path,
              to = command.args.length > 1 ? command.args[1] : '';
          if (from.isEmpty || to.isEmpty || !MvuPath.has(stat, from)) {
            fail('move 的来源 $from 不存在 $reasonText');
            continue;
          }
          final value = MvuPath.clone(MvuPath.get(stat, from));
          MvuPath.unset(stat, from);
          MvuPath.set(stat, to, value);
          display = 'MOVED \'$from\' to \'$to\' $reasonText';
          MvuPath.set(outStatus, from, display);
          MvuPath.set(delta, from, display);
          MvuPath.set(outStatus, to, display);
          MvuPath.set(delta, to, display);
          display = null;
      }

      if (display != null) {
        MvuPath.set(outStatus, path, display);
        MvuPath.set(delta, path, display);
      }
    }
    data.displayData = outStatus;
    data.deltaData = delta;
    final modified = !MvuPath.equals(data.statData, before.statData);
    if (modified) {
      data.schema = MvuSchema.reconcile(data.statData, data.schema);
    }
    return MvuUpdateResult(
      modified: modified,
      commands: commands,
      errors: errors,
    );
  }

  static num _toNumber(Object? value) {
    if (value is num) return value;
    final parsed = num.tryParse('$value'.trim());
    return parsed ?? 0;
  }

  static num _precise(num value) {
    if (value is int) return value;
    final rounded = double.parse(value.toStringAsPrecision(12));
    return rounded == rounded.truncateToDouble() && rounded.abs() < 1e15
        ? rounded.toInt()
        : rounded;
  }

  static String _json(Object? value) => MvuPath.stringify(value);
  static String _show(Object? value) =>
      MvuValue.trimQuotesAndBackslashes(MvuPath.stringify(value));
}
