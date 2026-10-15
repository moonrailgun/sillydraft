import 'dart:async';

import '../assets/asset_library.dart';
import '../model/task.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';
import 'reconnecting_executor.dart';
import 'remote_session.dart';

/// Tasks of a remote library run on the desktop; this side only asks and
/// watches the task rows.
final class RemoteTaskControl implements TaskControl {
  RemoteTaskControl(
    this.session, {
    required this.providerFactory,
    this.imageProviderFactory,
    this.assetLibrary,
  });
  final RemoteSession session;
  @override
  final ProviderFactory providerFactory;
  @override
  final ImageProviderFactory? imageProviderFactory;
  @override
  final AssetLibrary? assetLibrary;

  StoryRepository get _repository => session.repository;

  /// The desktop's tasks are the desktop's: a phone never marks them.
  @override
  Future<int> recoverInterrupted() async => 0;

  @override
  Future<GenerationTask> start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? chapterId,
    String? baseRevisionId,
    String? retryOf,
  }) async {
    final reply = await session.request(
      'POST',
      '/v1/tasks/start',
      json: {
        'branchId': branchId,
        'kind': kind.name,
        'input': input,
        'chapterId': ?chapterId,
        'baseRevisionId': ?baseRevisionId,
        'retryOf': ?retryOf,
      },
    );
    return _repository.getTask(reply['id'] as String);
  }

  /// Re-reads the task's status on every change, one read at a time: the
  /// desktop's progress arrives as write notifications, a few a second
  /// while a chapter streams, and a reconnect sends one too.
  @override
  Future<GenerationTask> wait(String id) async {
    final done = Completer<GenerationTask>();
    var reading = false, changed = false;
    Future<void> check() async {
      if (reading) {
        changed = true;
        return;
      }
      reading = true;
      try {
        do {
          changed = false;
          try {
            // The trimmed row: the frozen snapshots are read once, at the end.
            if (!(await _repository.getTask(id, snapshots: false)).isActive) {
              final task = await _repository.getTask(id);
              if (!done.isCompleted) done.complete(task);
              return;
            }
          } on RemoteUnavailable {
            // Checked again once the link is back.
          }
        } while (changed);
      } catch (e, s) {
        if (!done.isCompleted) done.completeError(e, s);
      } finally {
        reading = false;
      }
    }

    final subscription = _repository.changes.listen((_) => check());
    try {
      await check();
      return await done.future;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> cancel(String id) async {
    await session.request('POST', '/v1/tasks/$id/cancel', json: const {});
  }

  @override
  Future<GenerationTask> reconnectRemote(String id) async =>
      _repository.getTask(
        (await session.request(
              'POST',
              '/v1/tasks/$id/reconnect',
              json: const {},
            ))['id']
            as String,
      );

  @override
  Future<GenerationTask> resume(String id) async => _repository.getTask(
    (await session.request(
          'POST',
          '/v1/tasks/$id/resume',
          json: const {},
        ))['id']
        as String,
  );

  @override
  Future<bool> respondToImageConfirmation(
    String taskId,
    String confirmationId, {
    required bool approved,
  }) async =>
      (await session.request(
        'POST',
        '/v1/tasks/$taskId/confirm',
        json: {'confirmationId': confirmationId, 'approved': approved},
      ))['accepted'] ==
      true;

  /// The session belongs to the app's services, which close it.
  @override
  Future<void> close() async {}
}
