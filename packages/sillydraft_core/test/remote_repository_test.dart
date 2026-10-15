import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
// drift 2.35.2 is pinned by the lock file; both ends ship the same build.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

final class _User implements QueryExecutorUser {
  @override
  int get schemaVersion => 9;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

void main() {
  late Directory dir;
  late StoryRepository desktop;
  late DriftServer server;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sd-remote-repo');
    desktop = StoryRepository.open('${dir.path}/library.sqlite');
    // The desktop opens and migrates its file before anyone connects.
    await desktop.listNovels();
    server = desktop.remoteServer();
  });
  tearDown(() async {
    await server.shutdown();
    await desktop.close();
    await dir.delete(recursive: true);
  });

  Future<(DatabaseConnection, StreamChannelController<Object?>)>
  connect() async {
    final pipe = StreamChannelController<Object?>();
    unawaited(server.serve(pipe.local));
    return (await connectToRemoteAndInitialize(pipe.foreign), pipe);
  }

  test('a connected repository reads and writes the served library', () async {
    await desktop.createNovel(title: '桌面作品');
    final (connection, _) = await connect();
    final phone = StoryRepository.connect(connection.executor);
    expect((await phone.listNovels()).map((n) => n.title), ['桌面作品']);
    await phone.setSetting('from-phone', {'v': 1});
    expect(await desktop.getSetting('from-phone'), {'v': 1});
  });

  test('own writes are announced; external ones only refresh', () async {
    final local = <bool>[], changes = <bool>[], content = <bool>[];
    desktop.localWrites.listen(local.add);
    desktop.changes.listen((_) => changes.add(true));
    desktop.contentChanges.listen((_) => content.add(true));
    await desktop.setSetting('probe', {'v': 1});
    desktop.notifyExternal(true);
    desktop.notifyExternal(false);
    await pumpEventQueue();
    expect(local, [false]);
    expect(changes, hasLength(3));
    expect(content, hasLength(2));
  });

  test('statements that reach beyond the library are refused', () async {
    final (connection, _) = await connect();
    final executor = connection.executor;
    await executor.ensureOpen(_User());
    final outside = File('${dir.path}/outside.db');
    Future<void> refused(Future<void> run, String sql) => expectLater(
      run,
      throwsA(
        isA<DriftRemoteException>().having(
          (e) => '${e.remoteCause}',
          'cause',
          contains('远程连接不能执行此语句'),
        ),
      ),
      reason: sql,
    );
    for (final sql in [
      "ATTACH DATABASE '${outside.path}' AS x",
      'PRAGMA writable_schema = 1',
      'pragma main.table_info(novels)',
      "SELECT load_extension('x')",
      'VACUUM',
      // A quote inside an identifier opens no string, nor a dash a comment.
      "SELECT \"a'\"; ATTACH '${outside.path}' AS y; --'",
      'SELECT 1 AS "--"; DETACH x',
    ]) {
      await refused(executor.runCustom(sql), sql);
    }
    await refused(
      executor.runBatched(
        BatchedStatements(['VACUUM'], [ArgumentsForBatchedStatement(0, [])]),
      ),
      'batched VACUUM',
    );
    final tx = executor.beginTransaction();
    await tx.ensureOpen(_User());
    await refused(
      tx.runSelect('PRAGMA writable_schema', []),
      'in a transaction',
    );
    await tx.rollback();
    expect(outside.existsSync(), isFalse);
    // Words in strings and comments are no statements; the repository's
    // own pragmas still run.
    expect(await executor.runSelect("SELECT 'attach' AS v -- vacuum", []), [
      {'v': 'attach'},
    ]);
    for (final sql in [
      'PRAGMA defer_foreign_keys = ON',
      'PRAGMA foreign_key_check',
      'PRAGMA table_info(novels)',
    ]) {
      await executor.runSelect(sql, []);
    }
  });

  test(
    'a device that drops mid-transaction leaves the library writable',
    () async {
      final (connection, pipe) = await connect();
      final executor = connection.executor;
      await executor.ensureOpen(_User());
      final tx = executor.beginTransaction();
      await tx.ensureOpen(_User());
      await tx.runSelect('SELECT 1', []);
      final blocked = desktop.setSetting('during', {'ok': true});
      final finishedEarly = await blocked
          .then((_) => true)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
      expect(
        finishedEarly,
        isFalse,
        reason: 'the open transaction holds the db',
      );
      await pipe.foreign.sink.close();
      await blocked.timeout(const Duration(seconds: 5));
      expect(await desktop.getSetting('during'), {'ok': true});
    },
  );
}
