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
    this.allowNsfwImages = true,
  });
  final RemoteSession session;
  @override
  final bool allowNsfwImages;
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
    _checkImagePolicy(kind, input);
    final reply = await session.request(
      'POST',
      '/v1/tasks/start',
      json: {
        'branchId': branchId,
        'kind': kind.name,
        'input': {...input, if (!allowNsfwImages) 'allowNsfwImages': false},
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

  void _checkImagePolicy(TaskKind kind, Map<String, dynamic> input) {
    final hasImages =
        kind == TaskKind.illustration ||
        (kind == TaskKind.agent &&
            (input['image'] != null ||
                (input['pendingAgent'] as Map?)?['imageConnection'] != null));
    if (!allowNsfwImages && hasImages) _requireImagePolicy();
  }

  void _requireImagePolicy() {
    if (!session.hello.imageContentPolicy) {
      throw const FormatException('桌面版本尚不支持 iOS 生图内容限制，请先升级桌面');
    }
  }

  @override
  Future<GenerationTask> reconnectRemote(String id) async {
    if (!allowNsfwImages) {
      final task = await _repository.getTask(id);
      _checkImagePolicy(task.kind, task.input);
      if ((task.kind == TaskKind.illustration && task.input['nsfw'] != false) ||
          (task.kind == TaskKind.agent &&
              task.input['allowNsfwImages'] != false)) {
        throw const FormatException('此任务未通过 iOS 生图内容限制，请重新发起');
      }
    }
    return _repository.getTask(
      (await session.request(
            'POST',
            '/v1/tasks/$id/reconnect',
            json: const {},
          ))['id']
          as String,
    );
  }

  @override
  Future<GenerationTask> resume(String id) async {
    if (!allowNsfwImages) {
      final old = await _repository.getTask(id);
      if (old.isActive || old.status == TaskStatus.completed) {
        throw StateError('此任务无需重新生成');
      }
      return start(
        branchId: old.branchId,
        kind: old.kind,
        input: old.input,
        chapterId: old.chapterId,
        baseRevisionId: old.baseRevisionId,
        retryOf: old.id,
      );
    }
    return _repository.getTask(
      (await session.request(
            'POST',
            '/v1/tasks/$id/resume',
            json: const {},
          ))['id']
          as String,
    );
  }

  @override
  Future<bool> respondToImageConfirmation(
    String taskId,
    String confirmationId, {
    required bool approved,
  }) async {
    if (approved && !allowNsfwImages) {
      _requireImagePolicy();
      final task = await _repository.getTask(taskId);
      final confirmation = task.result['imageConfirmation'] as Map?;
      final images = confirmation?['images'] as List? ?? [?confirmation];
      final references = confirmation?['newReferences'] as List? ?? [];
      if (images.isEmpty ||
          [
            ...images,
            ...references,
          ].any((p) => p is! Map || p['nsfw'] != false)) {
        throw const FormatException('此请求未通过 iOS 生图内容限制，请从当前设备重新发起');
      }
      for (final preview in [...images, ...references]) {
        for (final id in (preview as Map)['references'] as List? ?? []) {
          if (id is! String ||
              (await _repository.getAsset(id)).metadata['nsfw'] == true) {
            throw const FormatException('此任务不允许使用 NSFW 图片作为参考图');
          }
        }
      }
    }
    return (await session.request(
          'POST',
          '/v1/tasks/$taskId/confirm',
          json: {'confirmationId': confirmationId, 'approved': approved},
        ))['accepted'] ==
        true;
  }

  /// The session belongs to the app's services, which close it.
  @override
  Future<void> close() async {}
}
