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

  @override
  bool operator ==(Object other) =>
      other is ManuscriptContent && other._encoded == _encoded;

  @override
  int get hashCode => _encoded.hashCode;
}
