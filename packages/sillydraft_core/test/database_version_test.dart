import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  test('a database from a newer app is refused and left untouched', () async {
    final dir = await Directory.systemTemp.createTemp('downgrade-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/library.sqlite';
    sqlite.sqlite3.open(path)
      ..execute('PRAGMA user_version = 1000')
      ..close();
    final repo = StoryRepository.open(path);
    await expectLater(
      repo.listNovels(),
      // Background databases wrap the StateError; startup shows its text.
      throwsA(predicate((e) => '$e'.contains('较新版本'))),
    );
    await repo.close();
    final db = sqlite.sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 1000);
    db.close();
  });
  test('a database from an older app is refused and left untouched', () async {
    final dir = await Directory.systemTemp.createTemp('old-library-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/library.sqlite';
    final current = StoryRepository.open(path);
    await current.createNovel(title: '雾港来信');
    await current.close();
    sqlite.sqlite3.open(path)
      ..execute('PRAGMA user_version = 8')
      ..close();
    final repo = StoryRepository.open(path);
    await expectLater(
      repo.listNovels(),
      throwsA(predicate((e) => '$e'.contains('旧版本'))),
    );
    await repo.close();
    final db = sqlite.sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 8);
    db.close();
  });
}
