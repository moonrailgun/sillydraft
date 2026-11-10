import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/src/diagnostics/local_error_log.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() => directory = Directory.systemTemp.createTempSync('sd-errors-'));
  tearDown(() => directory.deleteSync(recursive: true));

  List<File> logs() => directory
      .listSync()
      .whereType<File>()
      .where((file) => file.uri.pathSegments.last.startsWith('errors-'))
      .toList();

  test('errors and stacks reach disk before record returns', () {
    final log = LocalErrorLog.open(directory, version: '1.2.2+13');
    expect(
      log.record(
        StateError('无法打开资料库'),
        StackTrace.fromString('openLibrary:42'),
        source: 'startup',
      ),
      isTrue,
    );
    final entries = logs().single
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map)
        .toList();
    expect(entries.first['version'], '1.2.2+13');
    expect(entries.last['source'], 'startup');
    expect(entries.last['type'], 'StateError');
    expect(entries.last['message'], contains('无法打开资料库'));
    expect(entries.last['stack'], 'openLibrary:42');
    expect(DateTime.parse(entries.last['time'] as String).isUtc, isTrue);
  });

  test('a new session preserves the preceding crash evidence', () {
    LocalErrorLog.open(directory, version: 'old').record(
      StateError('previous crash'),
      StackTrace.empty,
      source: 'platform',
    );
    LocalErrorLog.open(directory, version: 'new');
    expect(logs(), hasLength(2));
    expect(
      logs().map((f) => f.readAsStringSync()).join(),
      contains('previous crash'),
    );
  });

  test('rotation bounds UTF-8 bytes and only prunes owned error logs', () {
    final unrelated = File('${directory.path}/keep.txt')
      ..writeAsStringSync('keep');
    final native = File('${directory.path}/native-previous.log')
      ..writeAsStringSync('native crash');
    final log = LocalErrorLog.open(
      directory,
      version: 'test',
      maxFileBytes: 4096,
      maxFiles: 3,
    );
    for (var i = 0; i < 30; i++) {
      log.record(
        StateError('$i ${'错误' * 5000}'),
        StackTrace.fromString('frame\n' * 5000),
        source: 'flutter',
      );
    }
    expect(logs().length, lessThanOrEqualTo(3));
    for (final file in logs()) {
      expect(file.lengthSync(), lessThanOrEqualTo(4096));
      for (final line in file.readAsLinesSync()) {
        expect(jsonDecode(line), isA<Map>());
      }
    }
    expect(unrelated.readAsStringSync(), 'keep');
    expect(native.readAsStringSync(), 'native crash');
    expect(logs().map((f) => f.readAsStringSync()).join(), contains('29 '));
  });

  test('credential patterns and FormatException input are not persisted', () {
    final log = LocalErrorLog.open(directory, version: 'test');
    log.record(
      StateError(
        'Authorization: Bearer SECRET_TOKEN api_key=SECRET_KEY password="SECRET_PASSWORD" https://host/path?token=SECRET_QUERY',
      ),
      StackTrace.empty,
      source: 'platform',
    );
    log.record(
      const FormatException('Invalid JSON', 'PRIVATE_MANUSCRIPT'),
      StackTrace.empty,
      source: 'platform',
    );
    final text = logs().single.readAsStringSync();
    expect(text, isNot(contains('SECRET_')));
    expect(text, isNot(contains('PRIVATE_MANUSCRIPT')));
    expect(text, contains('Invalid JSON'));
  });

  test('a disk failure while handling an error cannot throw another error', () {
    final log = LocalErrorLog.open(directory, version: 'test');
    directory.deleteSync(recursive: true);
    File(directory.path).writeAsStringSync('not a directory');
    try {
      expect(
        log.record(
          StateError('original'),
          StackTrace.empty,
          source: 'platform',
        ),
        isFalse,
      );
    } finally {
      File(directory.path).deleteSync();
      directory.createSync();
    }
  });
}
