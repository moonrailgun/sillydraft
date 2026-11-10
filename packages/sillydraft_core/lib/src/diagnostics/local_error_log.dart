import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Bounded, local-only diagnostics. Synchronous flushes preserve the last error
/// when the process exits immediately after an uncaught exception.
final class LocalErrorLog {
  LocalErrorLog._(
    this.directory,
    this.version,
    this.maxFileBytes,
    this.maxFiles,
  ) : _session = max(DateTime.now().microsecondsSinceEpoch, _lastSession + 1) {
    _lastSession = _session;
  }

  factory LocalErrorLog.open(
    Directory directory, {
    required String version,
    int maxFileBytes = 512 * 1024,
    int maxFiles = 10,
  }) {
    if (maxFileBytes < 4096 || maxFiles < 1) {
      throw ArgumentError(
        'Log limits must be at least 4096 bytes and one file',
      );
    }
    directory.createSync(recursive: true);
    final log = LocalErrorLog._(directory, version, maxFileBytes, maxFiles);
    log._rotate();
    return log;
  }

  static int _lastSession = 0;
  final Directory directory;
  final String version;
  final int maxFileBytes, maxFiles, _session;
  int _sequence = 0;
  late File _file;

  /// Never masks the original failure, even if storage or error.toString fails.
  bool record(Object error, StackTrace? stack, {required String source}) {
    try {
      // FormatException.toString includes its source (often a whole response or
      // manuscript). Its message is sufficient for diagnostics.
      final message = error is FormatException
          ? error.message
          : error.toString();
      final entry = <String, Object>{
        'time': DateTime.now().toUtc().toIso8601String(),
        'source': _limit(source, 100),
        'type': _limit(error.runtimeType.toString(), 100),
        'message': _limit(_redact(message), 8192),
        'stack': _limit(_redact(stack?.toString() ?? ''), 32768),
      };
      var bytes = utf8.encode('${jsonEncode(entry)}\n');
      while (bytes.length > maxFileBytes ~/ 2) {
        for (final key in ['message', 'stack']) {
          final value = entry[key] as String;
          entry[key] = _limit(value, value.length ~/ 2);
        }
        bytes = utf8.encode('${jsonEncode(entry)}\n');
      }
      if (_file.lengthSync() + bytes.length > maxFileBytes) _rotate();
      _file.writeAsBytesSync(bytes, mode: FileMode.append, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _rotate() {
    final suffix = (_sequence++).toString().padLeft(6, '0');
    _file = File('${directory.path}/errors-$_session-$pid-$suffix.log');
    _file.writeAsStringSync(
      '${jsonEncode({'time': DateTime.now().toUtc().toIso8601String(), 'source': 'session', 'version': _limit(version, 100), 'os': Platform.operatingSystem, 'osVersion': _limit(Platform.operatingSystemVersion, 200), 'dart': _limit(Platform.version, 200), 'pid': pid})}\n',
      flush: true,
    );
    final ownedName = RegExp(r'^errors-\d+-\d+-\d+\.log$');
    final files =
        directory
            .listSync(followLinks: false)
            .whereType<File>()
            .where((file) => ownedName.hasMatch(file.uri.pathSegments.last))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files.take(max(0, files.length - maxFiles))) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Another running process may still own the file on Windows.
      }
    }
  }
}

String _limit(String value, int count) {
  if (value.length <= count) return value;
  var end = count;
  if (end > 0 &&
      value.codeUnitAt(end - 1) >= 0xd800 &&
      value.codeUnitAt(end - 1) <= 0xdbff) {
    end--;
  }
  return '${value.substring(0, end)}…';
}

String _redact(String text) => text
    .replaceAll(
      RegExp(r'\b(?:Bearer|Basic)\s+[^\s,;"\x27]+', caseSensitive: false),
      '[REDACTED]',
    )
    .replaceAllMapped(
      RegExp(
        r'''(["']?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|secret|authorization)["']?\s*[:=]\s*)(?:"[^"]*"|'[^']*'|[^\s,;&}\]]+)''',
        caseSensitive: false,
      ),
      (match) => '${match[1]}[REDACTED]',
    )
    .replaceAll(RegExp(r'https?://[^\s/@]+:[^\s/@]+@'), 'https://[REDACTED]@');
