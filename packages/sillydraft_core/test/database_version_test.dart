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
  test('a version 9 library is upgraded with its data intact', () async {
    final dir = await Directory.systemTemp.createTemp('v9-library-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/library.sqlite';
    final current = StoryRepository.open(path);
    final novel = await current.createNovel(title: '雾港来信');
    final old = await current.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {'brief': '写下一段'},
    );
    await current.updateTask(
      old.id,
      status: TaskStatus.failed,
      partialText: '旧输出',
    );
    await current.close();
    // Version 9 is version 10 without the table of streamed progress.
    sqlite.sqlite3.open(path)
      ..execute('DROP TABLE task_progress')
      ..execute('PRAGMA user_version = 9')
      ..close();

    final repo = StoryRepository.open(path);
    expect((await repo.listNovels()).single.title, '雾港来信');
    expect((await repo.getTask(old.id)).partialText, '旧输出');
    final running = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {'brief': '再写一段'},
    );
    await repo.updateTask(running.id, status: TaskStatus.running);
    await repo.saveTaskProgress(running.id, partialText: '新', reasoning: '');
    expect((await repo.getTask(running.id)).partialText, '新');
    await repo.close();
    final db = sqlite.sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 10);
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
