import 'dart:convert';

/// Variable values are stored as strings, as SillyTavern macros see them.
/// Pages and MVU work with objects, arrays, numbers and booleans, which
/// round-trip as JSON text.
Map<String, dynamic> decodeVariables(Map<String, String> stored) => {
  for (final entry in stored.entries) entry.key: decodeVariable(entry.value),
};

Map<String, String> encodeVariables(Map<String, dynamic> variables) => {
  for (final entry in variables.entries)
    entry.key: entry.value is String
        ? entry.value as String
        : jsonEncode(entry.value),
};

Object? decodeVariable(String value) {
  if (value.isEmpty) return value;
  final first = value[0];
  if (first == '{' ||
      first == '[' ||
      first == '-' ||
      first == 't' ||
      first == 'f' ||
      first == 'n' ||
      (first.codeUnitAt(0) ^ 0x30) < 10) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is String) return value;
      return decoded;
    } on FormatException {
      return value;
    }
  }
  return value;
}
