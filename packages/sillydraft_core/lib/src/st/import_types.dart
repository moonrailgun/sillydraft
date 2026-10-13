import 'dart:convert';

enum DiagnosticSeverity { info, warning, error }

final class CompatibilityDiagnostic {
  const CompatibilityDiagnostic(
    this.code,
    this.message, {
    this.path = '',
    this.severity = DiagnosticSeverity.warning,
  });
  final String code;
  final String message;
  final String path;
  final DiagnosticSeverity severity;
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'path': path,
    'severity': severity.name,
  };
}

/// Keeps a deep, immutable snapshot while permitting callers to edit a copy.
class JsonSource {
  JsonSource(Map<String, dynamic> value) : _json = jsonEncode(value);
  final String _json;
  Map<String, dynamic> get raw => jsonDecode(_json) as Map<String, dynamic>;
  Map<String, dynamic> exportJson() => redactCredentials(raw);
}

const credentialKeys = {
  'api_key',
  'apikey',
  'api-key',
  'api_secret',
  'secret',
  'secret_key',
  'proxy_password',
  'password',
  'authorization',
  'access_token',
  'refresh_token',
  'custom_headers',
  'custom_include_headers',
  'headers',
  'custom_include_body',
};

Map<String, dynamic> redactCredentials(Map<String, dynamic> input) {
  Object? clean(Object? value) {
    if (value is Map<String, dynamic>) {
      return {
        for (final e in value.entries)
          if (!credentialKeys.contains(e.key.toLowerCase()) ||
              e.value == '' ||
              e.value == null)
            e.key: clean(e.value),
      };
    }
    if (value is List) return value.map(clean).toList();
    return value;
  }

  return clean(input)! as Map<String, dynamic>;
}

Map<String, dynamic> jsonObject(Object? value, String path) {
  if (value is! Map<String, dynamic>) {
    throw FormatException('$path 必须是 JSON 对象');
  }
  return value;
}

/// The name SillyTavern shows for a resource file that has no name of its
/// own: the file name without folders or its resource extension
/// (`Reborn2.3.json` → `Reborn2.3`).
String nameFromFilename(String filename) {
  final base = filename.split(RegExp(r'[/\\]')).last;
  final extension = RegExp(
    r'\.(json|png|charx)$',
    caseSensitive: false,
  ).firstMatch(base);
  return (extension == null ? base : base.substring(0, extension.start)).trim();
}

String stringField(
  Map<String, dynamic> map,
  String key, {
  String fallback = '',
}) {
  final value = map[key];
  if (value == null) return fallback;
  if (value is! String) throw FormatException('$key 必须是字符串');
  return value;
}

List<String> stringList(Object? value, String path) {
  if (value == null) return const [];
  if (value is! List || value.any((e) => e is! String)) {
    throw FormatException('$path 必须是字符串数组');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

int intField(Map<String, dynamic> map, String key, int fallback) {
  final value = map[key];
  if (value == null) return fallback;
  if (value is! num || !value.isFinite || value.toInt() != value) {
    throw FormatException('$key 必须是整数');
  }
  return value.toInt();
}
