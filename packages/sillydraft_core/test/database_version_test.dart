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
    // Version 9 is version 11 without the tables of streamed progress and
    // request usage.
    sqlite.sqlite3.open(path)
      ..execute('DROP TABLE task_progress')
      ..execute('DROP TABLE usage_records')
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
    await repo.recordUsage(
      connection: ModelConnection(
        id: 'c',
        name: '网关',
        baseUrl: 'https://gateway.example/v1',
        model: 'm',
      ),
      kind: 'text',
      source: CostSource.unknown,
    );
    expect((await repo.usageByMonth()).single.requests, 1);
    await repo.close();
    final db = sqlite.sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 11);
    db.close();
  });
  test('a version 10 library gains the table of request usage', () async {
    final dir = await Directory.systemTemp.createTemp('v10-library-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/library.sqlite';
    final current = StoryRepository.open(path);
    await current.createNovel(title: '雾港来信');
    await current.close();
    sqlite.sqlite3.open(path)
      ..execute('DROP TABLE usage_records')
      ..execute('PRAGMA user_version = 10')
      ..close();

    final repo = StoryRepository.open(path);
    expect((await repo.listNovels()).single.title, '雾港来信');
    await repo.recordUsage(
      connection: ModelConnection(
        id: 'c',
        name: '网关',
        baseUrl: 'https://gateway.example/v1',
        model: 'm',
      ),
      kind: 'text',
      source: CostSource.unknown,
    );
    expect((await repo.usageByMonth()).single.requests, 1);
    await repo.close();
    final db = sqlite.sqlite3.open(path);
    expect(db.select('PRAGMA user_version').single.values.single, 11);
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
