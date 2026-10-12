import 'dart:convert';

/// Canonical, complete Quill document. Patch operations are not documents.
final class ManuscriptContent {
  ManuscriptContent._(this._encoded);

  factory ManuscriptContent.plainText(String text) =>
      ManuscriptContent.fromDelta([
        {'insert': text},
      ]);

  factory ManuscriptContent.fromDelta(List<Map<String, dynamic>> delta) {
    final copy = <Map<String, dynamic>>[];
    for (final operation in delta) {
      if (!operation.containsKey('insert') ||
          operation.keys.any((key) => key != 'insert' && key != 'attributes')) {
        throw const FormatException('正文必须包含完整内容，不能保存增量编辑指令。');
      }
      final insert = operation['insert'];
      if (insert is! String && insert is! Map<String, dynamic>) {
        throw const FormatException('无效的正文内容。');
      }
      if (insert is Map &&
          (insert.length != 1 || insert.values.single is! String)) {
        throw const FormatException('无效的正文附件。');
      }
      final attributes = operation['attributes'];
      if (attributes != null && attributes is! Map<String, dynamic>) {
        throw const FormatException('无效的文字格式。');
      }
      if (insert == '') continue;
      copy.add(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(operation)) as Map<String, dynamic>,
        ),
      );
    }
    final last = copy.isEmpty ? null : copy.last['insert'];
    if (last is! String || !last.endsWith('\n')) {
      copy.add({'insert': '\n'});
    }
    return ManuscriptContent._(jsonEncode({'version': 1, 'delta': copy}));
  }

  factory ManuscriptContent.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['delta'] is! List) {
      throw const FormatException('不支持的正文格式版本。');
    }
    final operations = (json['delta'] as List).map((value) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('无效的正文操作。');
      }
      return value;
    }).toList();
    return ManuscriptContent.fromDelta(operations);
  }

  factory ManuscriptContent.decode(String encoded) {
    final data = jsonDecode(encoded);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('无效的正文文档。');
    }
    return ManuscriptContent.fromJson(data);
  }

  final String _encoded;

  String get encoded => _encoded;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  List<Map<String, dynamic>> get delta =>
      (toJson()['delta'] as List).cast<Map<String, dynamic>>();

  String get text => delta.map((op) {
    final insert = op['insert'];
    return insert is String ? insert : '\uFFFC';
  }).join();

  void validateRange(int start, int end) {
    final value = text;
    if (start < 0 || end < start || end > value.length - 1) {
      throw RangeError('选区超出正文范围');
    }
    for (final index in [start, end]) {
      if (index > 0 &&
          index < value.length &&
          value.codeUnitAt(index) >= 0xdc00 &&
          value.codeUnitAt(index) <= 0xdfff &&
          value.codeUnitAt(index - 1) >= 0xd800 &&
          value.codeUnitAt(index - 1) <= 0xdbff) {
        throw ArgumentError('选区不能拆分完整字符');
      }
    }
  }

  ManuscriptContent replaceRange(int start, int end, String replacement) {
    validateRange(start, end);
    List<Map<String, dynamic>> slice(int from, int to) {
      final result = <Map<String, dynamic>>[];
      var position = 0;
      for (final op in delta) {
        final insert = op['insert'];
        final length = insert is String ? insert.length : 1;
        final a = (from - position).clamp(0, length),
            b = (to - position).clamp(0, length);
        if (b > a) {
          result.add({
            ...op,
            'insert': insert is String ? insert.substring(a, b) : insert,
          });
        }
        position += length;
      }
      return result;
    }

    return ManuscriptContent.fromDelta([
      ...slice(0, start),
      if (replacement.isNotEmpty) {'insert': replacement},
      ...slice(end, text.length),
    ]);
  }

  ManuscriptContent insertImage(int offset, String assetId) {
    validateRange(offset, offset);
    // Quill stores paragraph formatting on its terminating newline. Splitting
    // that paragraph with a block image must retain the first part's format.
    Map<String, dynamic>? paragraphAttributes;
    var scanPosition = 0;
    for (final op in delta) {
      final value = op['insert'];
      final length = value is String ? value.length : 1;
      if (value is String &&
          value.indexOf('\n', (offset - scanPosition).clamp(0, length)) >= 0 &&
          scanPosition + length > offset) {
        paragraphAttributes = op['attributes'] as Map<String, dynamic>?;
        break;
      }
      scanPosition += length;
    }
    final operations = <Map<String, dynamic>>[];
    var position = 0, inserted = false;
    for (final op in delta) {
      final value = op['insert'],
          length = op['insert'] is String ? (op['insert'] as String).length : 1;
      if (!inserted && offset >= position && offset <= position + length) {
        final cut = offset - position;
        if (cut > 0) {
          operations.add({
            ...op,
            'insert': value is String ? value.substring(0, cut) : value,
          });
        }
        // Block images occupy their own paragraph in Quill and the reader.
        if (offset > 0 && text[offset - 1] != '\n') {
          operations.add({'insert': '\n', 'attributes': ?paragraphAttributes});
        }
        operations.add({
          'insert': {'image': 'asset:$assetId'},
        });
        operations.add({'insert': '\n'});
        if (cut < length) {
          operations.add({
            ...op,
            'insert': value is String ? value.substring(cut) : value,
          });
        }
        inserted = true;
      } else {
        operations.add(op);
      }
      position += length;
    }
    return ManuscriptContent.fromDelta(operations);
  }

  @override
  bool operator ==(Object other) =>
      other is ManuscriptContent && other._encoded == _encoded;

  @override
  int get hashCode => _encoded.hashCode;
}
