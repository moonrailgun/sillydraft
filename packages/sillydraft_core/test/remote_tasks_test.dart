import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show QueryExecutor, QueryExecutorUser;
// ignore: implementation_imports
import 'package:drift/src/remote/communication.dart'
    show ConnectionClosedException;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/fake.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

class _Dropped extends Fake implements QueryExecutor {
  _Dropped(this.error);
  final Object error;
  @override
  Future<List<Map<String, Object?>>> runSelect(String s, List<Object?> a) =>
      Future.error(error);
}

/// Rewrites the stored task before handing over, as a phone's write over
/// /v1/db could land between the host's check and the run.
final class _RewriteFirst extends Fake implements TaskControl {
  _RewriteFirst(this.runner, this.rewrite);
  final TaskRunner runner;
  final void Function() rewrite;

  @override
  Future<GenerationTask> resume(String id) async {
    rewrite();
    return runner.resume(id);
  }

  @override
  Future<GenerationTask> start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? chapterId,
    String? baseRevisionId,
    String? retryOf,
  }) async {
    rewrite();
    return runner.start(
      branchId: branchId,
      kind: kind,
      input: input,
      chapterId: chapterId,
      baseRevisionId: baseRevisionId,
      retryOf: retryOf,
    );
  }
}

class _User extends Fake implements QueryExecutorUser {}

const _wait = Duration(seconds: 10);

void main() {
  final connection = ModelConnection(
    id: 'local',
    name: 'Test',
    baseUrl: 'http://localhost:1234/v1',
    model: 'fiction-model',
  );
  final cli = ModelConnection(
    id: 'cli',
    name: 'Claude Code',
    baseUrl: '',
    model: 'sonnet',
    protocol: ModelProtocol.claudeCode,
  );
  late Desktop desktop;
  late RemoteSession phone;
  late RemoteTaskControl tasks;
  late WritingService writing;
  late Novel novel;
  late Chapter chapter;
  late Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  var calls = 0;

  setUp(() async {
    calls = 0;
    script = (_, _) async* {
      yield const TextDelta('新正文');
      yield const GenerationFinished('stop');
    };
    desktop = await Desktop.start(
      connections: [connection, cli],
      providerFactory: (c) async {
        calls++;
        return ScriptProvider(c, (r, cancel) => script(r, cancel));
      },
    );
    novel = await desktop.repository.createNovel(title: '远程生成');
    chapter = await desktop.repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('原文'),
    );
    phone = await desktop.phone();
    tasks = RemoteTaskControl(
      phone,
      providerFactory: (_) async =>
          throw StateError('the phone calls no model'),
    );
    writing = WritingService(repository: phone.repository, runner: tasks);
  });
  tearDown(() async {
    await phone.close();
    await desktop.close();
  });

  Future<GenerationTask> generate([ModelConnection? using]) => writing.generate(
    branchId: novel.activeBranchId,
    chapterId: chapter.id,
    connection: using ?? connection,
    brief: '写下一段',
    append: true,
  );

  test(
    'phone queues assistant turns and refreshes frozen task inputs',
    () async {
      final conversation = await desktop.repository.createConversation(
        branchId: novel.activeBranchId,
      );
      final entered = Completer<void>(), release = Completer<void>();
      final seen = <String>[];
      script = (request, cancel) async* {
        final text = request.messages.last['content'] as String;
        seen.add(text);
        if (text == '第一条') {
          entered.complete();
          final cancelled = Completer<void>();
          final remove = cancel.onCancel(() => cancelled.complete());
          try {
            await Future.any([release.future, cancelled.future]);
            cancel.check();
          } finally {
            remove();
          }
        } else {
          expect(request.messages.map((m) => m['content']), contains('第一条的回复'));
        }
        yield TextDelta('$text的回复');
        yield const GenerationFinished('stop');
      };
      final agent = EditorAgent(repository: phone.repository, runner: tasks);
      await agent.send(
        conversationId: conversation,
        connection: connection,
        message: '第一条',
      );
      await entered.future.timeout(_wait);
      final second = await agent.send(
        conversationId: conversation,
        connection: connection,
        message: '第二条',
      );
      final queued = (await phone.repository.listTasks()).firstWhere(
        (t) => t.id == second.id,
      );
      expect(queued.status, TaskStatus.queued);
      expect(queued.input['agentMessage'], '第二条');
      expect(seen, ['第一条']);
      release.complete();
      expect(
        (await tasks.wait(second.id).timeout(_wait)).status,
        TaskStatus.completed,
      );
      final completed = (await phone.repository.listTasks()).firstWhere(
        (t) => t.id == second.id,
      );
      expect(completed.input['agentMessage'], isNull);
      expect(completed.input['editChapterId'], chapter.id);
    },
  );

  test('a phone\'s task runs on the desktop', () async {
    final task = await generate();
    expect(
      (await tasks.wait(task.id).timeout(_wait)).status,
      TaskStatus.completed,
    );
    expect(calls, 1);
    expect(
      (await desktop.repository.getTask(task.id)).status,
      TaskStatus.completed,
    );
  });

  test('cancelling on the phone stops the desktop run', () async {
    final started = Completer<void>();
    script = (_, cancel) async* {
      yield const TextDelta('开头');
      started.complete();
      final stopped = Completer<void>();
      cancel.onCancel(stopped.complete);
      await stopped.future;
      throw const GenerationCancelled();
    };
    final task = await generate();
    await started.future.timeout(_wait);
    await tasks.cancel(task.id);
    expect(
      (await tasks.wait(task.id).timeout(_wait)).status,
      TaskStatus.cancelled,
    );
  });

  test('a task keeps running after the phone hangs up', () async {
    final gate = Completer<void>();
    script = (_, _) async* {
      await gate.future;
      yield const TextDelta('后来');
      yield const GenerationFinished('stop');
    };
    final task = await generate();
    await phone.close();
    gate.complete();
    expect(
      (await desktop.runner.wait(task.id).timeout(_wait)).status,
      TaskStatus.completed,
    );
  });

  test('a connection that differs from the desktop\'s is refused', () async {
    final forged = ModelConnection(
      id: 'local',
      name: 'Test',
      baseUrl: 'https://elsewhere.example/v1',
      model: 'fiction-model',
    );
    await expectLater(
      generate(forged),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403),
      ),
    );
    expect(calls, 0);
    expect(await desktop.repository.listTasks(), isEmpty);
  });

  test('local subscriptions stay on the desktop', () async {
    final refused = throwsA(
      isA<RemoteRequestFailed>()
          .having((e) => e.status, 'status', 403)
          .having((e) => e.message, 'message', '本地订阅只能在桌面上使用'),
    );
    await expectLater(generate(cli), refused);
    await expectLater(
      DesktopModelProvider(phone, cli).generate(ProviderRequest()).toList(),
      refused,
    );
    expect(calls, 0);
    expect(await desktop.repository.listTasks(), isEmpty);
  });

  test('a connection without a protocol is refused', () async {
    // fromJson defaults a missing protocol, so this still builds a connection.
    final forged = {
      'id': 'local',
      'name': 'x',
      'baseUrl': 'https://elsewhere.example/v1',
      'model': 'm',
    };
    await expectLater(
      tasks.start(
        branchId: novel.activeBranchId,
        kind: TaskKind.writing,
        input: {'connection': forged},
      ),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403),
      ),
    );
    expect(calls, 0);
  });

  test('resuming a forged task row is refused', () async {
    final forged = await phone.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {
        'connection': {
          'id': 'local',
          'protocol': 'openAICompatible',
          'baseUrl': 'https://elsewhere.example/v1',
        },
      },
    );
    await phone.repository.updateTask(forged.id, status: TaskStatus.failed);
    await expectLater(
      tasks.resume(forged.id),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403),
      ),
    );
    expect(calls, 0);
  });

  test('resume runs the input it checked, not a later rewrite', () async {
    final task = await phone.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {'connection': connection.raw},
    );
    await phone.repository.updateTask(task.id, status: TaskStatus.failed);
    await desktop.stopHost();
    await desktop.startHost(
      tasks: _RewriteFirst(desktop.runner, () {
        final db = sqlite.sqlite3.open(
          '${desktop.directory.path}/library.sqlite',
        );
        db.execute('UPDATE generation_tasks SET input_json = ? WHERE id = ?', [
          jsonEncode({
            'connection': {
              ...connection.raw,
              'baseUrl': 'https://elsewhere.example/v1',
            },
          }),
          task.id,
        ]);
        db.close();
      }),
    );
    final reply = await phone.request(
      'POST',
      '/v1/tasks/${task.id}/resume',
      json: const {},
    );
    final retried = await desktop.runner
        .wait(reply['id'] as String)
        .timeout(_wait);
    expect((retried.input['connection'] as Map)['baseUrl'], connection.baseUrl);
  });

  test('wait hands back the whole task', () async {
    final task = await generate();
    final done = await tasks.wait(task.id).timeout(_wait);
    expect(done.status, TaskStatus.completed);
    expect(done.input, (await desktop.repository.getTask(task.id)).input);
    expect(
      done.input,
      isNot((await phone.repository.getTask(task.id, snapshots: false)).input),
    );
  });

  test('wait survives the link dropping mid-run', () async {
    script = (_, _) async* {
      for (var i = 0; i < 40; i++) {
        yield TextDelta('段$i');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      yield const GenerationFinished('stop');
    };
    final task = await generate();
    final waiting = tasks.wait(task.id);
    // Drop while deltas (and so the phone's re-reads) are flowing.
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration(milliseconds: 130 + i * 7));
      await desktop.stopHost();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await desktop.startHost();
    }
    expect((await waiting.timeout(_wait)).status, TaskStatus.completed);
  });

  test('closed-channel errors read as the link being down', () async {
    for (final error in [
      const ConnectionClosedException(),
      StateError('Tried to send x, but the connection was closed!'),
    ]) {
      final executor = ReconnectingExecutor();
      await executor.attach(_Dropped(error));
      await expectLater(
        executor.runSelect('select 1', const []),
        throwsA(isA<RemoteUnavailable>()),
      );
    }
  });

  test('a transaction cut off mid-way reads as the link being down', () async {
    final transaction = phone.executor.beginTransaction();
    await transaction.ensureOpen(_User());
    await transaction.runSelect('SELECT 1', const []);
    await desktop.stopHost();
    await expectLater(
      transaction
          .runInsert(
            'INSERT INTO app_settings (key, value_json) VALUES (?, ?)',
            ['cut', '{}'],
          )
          .timeout(_wait),
      throwsA(isA<RemoteUnavailable>()),
    );
    // Waits out the desktop rolling the abandoned transaction back, which
    // holds its database until then.
    await desktop.repository.listNovels().timeout(_wait);
  });

  test('cancel checks the input the runner reads, not the row', () async {
    final forged = await phone.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {
        'connection': {
          'id': 'evil',
          'protocol': 'sillyDraftRunner',
          'baseUrl': 'https://elsewhere.example',
        },
      },
    );
    // Listing fills the desktop's cache of trimmed inputs; the stored input
    // is then rewritten so the full row looks harmless.
    await desktop.repository.listTasks();
    final db = sqlite.sqlite3.open('${desktop.directory.path}/library.sqlite');
    db.execute('UPDATE generation_tasks SET input_json = ? WHERE id = ?', [
      '{}',
      forged.id,
    ]);
    db.close();
    await expectLater(
      tasks.cancel(forged.id),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403),
      ),
    );
    expect(calls, 0);
  });

  test('cancelling a local task works without its saved connection', () async {
    final started = Completer<void>();
    script = (_, cancel) async* {
      started.complete();
      final stopped = Completer<void>();
      cancel.onCancel(stopped.complete);
      await stopped.future;
      throw const GenerationCancelled();
    };
    final task = await generate();
    await started.future.timeout(_wait);
    desktop.connections.clear();
    await tasks.cancel(task.id);
    expect(
      (await tasks.wait(task.id).timeout(_wait)).status,
      TaskStatus.cancelled,
    );
  });

  test('an unknown image confirmation is declined', () async {
    expect(
      await tasks.respondToImageConfirmation('missing', 'x', approved: true),
      isFalse,
    );
  });
}
