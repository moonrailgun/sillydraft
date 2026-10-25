import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sillydraft-open-');
    await File('${directory.path}/secrets.json')
        .writeAsString('{"version":1,"migrated":true,"values":{}}');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return directory.path;
      }
      throw MissingPluginException(call.method);
    });
  });
  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test('a second app cannot recover the first app\'s live tasks', () async {
    final first = await AppServices.open(checkUpdates: false);
    addTearDown(first.close);
    final novel = await first.repository.createNovel(title: '仍在生成');
    final task = await first.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {},
    );
    await first.repository.updateTask(task.id, status: TaskStatus.running);

    await expectLater(
      AppServices.open(checkUpdates: false).then((second) {
        addTearDown(second.close);
        return second;
      }),
      throwsStateError,
    );
    expect(
      (await first.repository.getTask(task.id)).status,
      TaskStatus.running,
    );
    await first.close();

    final reopened = await AppServices.open(checkUpdates: false);
    addTearDown(reopened.close);
    expect(
      (await reopened.repository.getTask(task.id)).status,
      TaskStatus.interrupted,
    );
  });

  test('a failed database open releases the library for retry', () async {
    final database = File('${directory.path}/library.sqlite');
    await database.writeAsString('not a database');
    await expectLater(
      AppServices.open(checkUpdates: false),
      throwsA(isA<Exception>()),
    );
    await database.delete();

    final services = await AppServices.open(checkUpdates: false);
    addTearDown(services.close);
    expect(await services.repository.listNovels(), isEmpty);
  });

  test('a failed lock file open does not leave an in-process owner', () async {
    final lock = await Directory('${directory.path}/library.lock').create();
    await expectLater(
      AppServices.open(checkUpdates: false),
      throwsA(isA<FileSystemException>()),
    );
    await lock.delete();

    final services = await AppServices.open(checkUpdates: false);
    addTearDown(services.close);
    expect(await services.repository.listNovels(), isEmpty);
  });

  test(
    'the library lock excludes other processes and releases on close',
    () async {
      final script = File('${directory.path}/hold_lock.dart');
      await script.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final file = File(args.first).openSync(mode: FileMode.append);
  try {
    file.lockSync(FileLock.exclusive);
  } on FileSystemException {
    file.closeSync();
    exit(2);
  }
  stdout.writeln('locked');
  if (args.length == 1) await stdin.first;
  file.closeSync();
}
''');
      final args = [script.path, '${directory.path}/library.lock'];
      final child = await Process.start(
        'dart',
        args,
        runInShell: Platform.isWindows,
      );
      final errors = child.stderr.transform(utf8.decoder).join();
      var childStopped = false;
      addTearDown(() async {
        if (!childStopped) child.stdin.writeln();
        await child.stdin.close();
        await child.exitCode;
      });
      expect(
        await child.stdout.transform(utf8.decoder).first,
        contains('locked'),
      );
      await expectLater(
        AppServices.open(checkUpdates: false).then((services) {
          addTearDown(services.close);
          return services;
        }),
        throwsStateError,
      );
      child.stdin.writeln();
      expect(await child.exitCode, 0, reason: await errors);
      childStopped = true;

      final services = await AppServices.open(checkUpdates: false);
      addTearDown(services.close);
      final blocked = await Process.run('dart', [
        ...args,
        'probe',
      ], runInShell: Platform.isWindows);
      expect(blocked.exitCode, 2);
      await services.close();
      final released = await Process.run('dart', [
        ...args,
        'probe',
      ], runInShell: Platform.isWindows);
      expect(released.exitCode, 0, reason: '${released.stderr}');
    },
  );
}
