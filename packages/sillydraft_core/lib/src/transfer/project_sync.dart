import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../model/story.dart';
import '../storage/story_repository.dart';
import 'project_backup.dart';
import 'project_snapshot.dart';

final class RemoteSnapshot {
  RemoteSnapshot({required this.etag, required Uint8List bytes})
    : _bytes = Uint8List.fromList(bytes);
  final String etag;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
}

abstract interface class SnapshotTransport {
  Future<RemoteSnapshot?> read();
  Future<String> write(Uint8List bytes, {required String? expectedEtag});
  void close();
}

/// A single encrypted object on an HTTP/WebDAV service implementing RFC 9110
/// conditional PUT. Redirects never forward credentials to a different host.
final class HttpSnapshotTransport implements SnapshotTransport {
  HttpSnapshotTransport({
    required this.url,
    String authorization = '',
    bool allowInsecureHttp = false,
    Dio? dio,
  }) : _dio = dio ?? Dio(),
       _authorization = authorization {
    if (!['http', 'https'].contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      throw const FormatException('同步地址须是无账号、查询参数的完整 HTTP 文件地址');
    }
    if (url.scheme == 'http' &&
        !['localhost', '127.0.0.1', '::1'].contains(url.host) &&
        !allowInsecureHttp) {
      throw const FormatException('远程同步需要 HTTPS；仅本地测试可直接使用 HTTP');
    }
    if (authorization.contains('\n') || authorization.contains('\r')) {
      throw const FormatException('同步认证无效');
    }
  }
  final Uri url;
  final Dio _dio;
  final String _authorization;
  final _tokens = <CancelToken>{};
  bool _closed = false;
  Future<Response<ResponseBody>> _request(
    String method, {
    Uint8List? bytes,
    Map<String, String> headers = const {},
  }) async {
    if (_closed) throw StateError('同步连接已关闭');
    final token = CancelToken();
    _tokens.add(token);
    try {
      return await _dio.requestUri<ResponseBody>(
        url,
        data: bytes == null ? null : Stream.value(bytes),
        cancelToken: token,
        options: Options(
          method: method,
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
          sendTimeout: const Duration(minutes: 3),
          receiveTimeout: const Duration(minutes: 3),
          headers: {
            if (_authorization.isNotEmpty) 'Authorization': _authorization,
            ...headers,
            if (bytes != null) ...{
              'Content-Type': 'application/octet-stream',
              'Content-Length': '${bytes.length}',
            },
          },
        ),
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw const FormatException('同步已取消');
      }
      throw const FormatException('同步连接失败，请检查地址和网络');
    } finally {
      _tokens.remove(token);
    }
  }

  String _etag(Response response) {
    final tag = response.headers.value('etag');
    if (tag == null || !RegExp(r'^"[^"\r\n]+"$').hasMatch(tag)) {
      throw const FormatException('同步服务须返回强 ETag 并支持条件写入');
    }
    return tag;
  }

  Future<void> _discard(Response<ResponseBody> response) async =>
      response.data?.stream.listen((_) {}).cancel();
  @override
  Future<RemoteSnapshot?> read() async {
    final response = await _request('GET');
    if (response.statusCode == 404) {
      await _discard(response);
      return null;
    }
    if (response.statusCode != 200) {
      await _discard(response);
      throw FormatException('同步读取失败（HTTP ${response.statusCode}）');
    }
    String tag;
    try {
      tag = _etag(response);
    } catch (_) {
      await _discard(response);
      rethrow;
    }
    final length = int.tryParse(response.headers.value('content-length') ?? '');
    if (length != null && length > ProjectBackup.maxBytes) {
      await _discard(response);
      throw const FormatException('远端备份超过 128 MB');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream.timeout(
      const Duration(minutes: 3),
    )) {
      if (buffer.length + chunk.length > ProjectBackup.maxBytes) {
        throw const FormatException('远端备份超过 128 MB');
      }
      buffer.add(chunk);
    }
    return RemoteSnapshot(etag: tag, bytes: buffer.takeBytes());
  }

  @override
  Future<String> write(Uint8List bytes, {required String? expectedEtag}) async {
    if (bytes.isEmpty || bytes.length > ProjectBackup.maxBytes) {
      throw const FormatException('同步备份大小无效');
    }
    if (expectedEtag != null &&
        !RegExp(r'^"[^"\r\n]+"$').hasMatch(expectedEtag)) {
      throw const FormatException('同步版本无效');
    }
    final response = await _request(
      'PUT',
      bytes: bytes,
      headers: expectedEtag == null
          ? {'If-None-Match': '*'}
          : {'If-Match': expectedEtag},
    );
    await _discard(response);
    if (response.statusCode == 412 || response.statusCode == 409) {
      throw const ProjectConflict();
    }
    if (![200, 201, 204].contains(response.statusCode)) {
      throw FormatException('同步上传失败（HTTP ${response.statusCode}）');
    }
    return _etag(response);
  }

  @override
  void close() {
    _closed = true;
    for (final token in _tokens.toList()) {
      token.cancel();
    }
    _dio.close(force: true);
  }
}

enum SyncAction { unchanged, uploaded, downloaded, conflict }

final class SyncResult {
  const SyncResult(this.action, {this.conflictNovelId, this.remoteEtag});
  final SyncAction action;
  final String? conflictNovelId, remoteEtag;
}

final class ProjectSync {
  ProjectSync({
    required this.repository,
    required this.backup,
    required this.transport,
    required this.passphrase,
  });
  final StoryRepository repository;
  final ProjectBackup backup;
  final SnapshotTransport transport;
  final String passphrase;
  bool _busy = false;
  Future<T> _run<T>(Future<T> Function() action) async {
    if (_busy) throw StateError('此同步正在进行');
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<Novel> connect() => _run(() async {
    final remote = await transport.read();
    if (remote == null) throw const FormatException('远端还没有作品备份，请先从另一设备上传');
    final content = await backup.read(remote.bytes, passphrase: passphrase);
    final known = await repository.listNovels(includeArchived: true);
    if (known.any((n) => n.id == content.snapshot.novelId)) {
      throw const ProjectConflict();
    }
    return backup.restoreContents(
      content,
      asCopy: false,
      syncState: {'remoteEtag': remote.etag},
    );
  });

  Future<SyncResult> synchronize(String novelId) =>
      _run(() => _synchronize(novelId));
  Future<SyncResult> _synchronize(String novelId) async {
    final local = await repository.exportProject(novelId);
    final state = await repository.getSetting('syncState/$novelId') ?? {};
    final remote = await transport.read();
    if (remote == null) {
      if (state['remoteEtag'] != null) {
        throw const FormatException('远端备份已被移除，保留本机作品；请检查同步地址');
      }
      try {
        return await _upload(local, null);
      } on ProjectConflict {
        return _conflict(novelId, await _requireRemote(), state);
      }
    }
    if (remote.etag == state['remoteEtag']) {
      if (local.fingerprint == state['localFingerprint']) {
        return SyncResult(SyncAction.unchanged, remoteEtag: remote.etag);
      }
      try {
        return await _upload(local, remote.etag);
      } on ProjectConflict {
        return _conflict(novelId, await _requireRemote(), state);
      }
    }
    final content = await backup.read(remote.bytes, passphrase: passphrase);
    if (content.snapshot.novelId != novelId) {
      throw const FormatException('此同步地址属于另一部作品');
    }
    // A successful PUT whose response was lost is already present remotely.
    if (content.snapshot.fingerprint == local.fingerprint) {
      await _record(local, remote.etag);
      return SyncResult(SyncAction.unchanged, remoteEtag: remote.etag);
    }
    if (local.fingerprint == state['localFingerprint']) {
      try {
        await backup.restoreContents(
          content,
          asCopy: false,
          expectedFingerprint: local.fingerprint,
          syncState: {'remoteEtag': remote.etag},
        );
        return SyncResult(SyncAction.downloaded, remoteEtag: remote.etag);
      } on ProjectConflict {
        return _conflict(novelId, remote, state, content: content);
      }
    }
    return _conflict(novelId, remote, state, content: content);
  }

  Future<RemoteSnapshot> _requireRemote() async =>
      await transport.read() ?? (throw const ProjectConflict());
  Future<SyncResult> _conflict(
    String id,
    RemoteSnapshot remote,
    Map<String, dynamic> state, {
    BackupContents? content,
  }) async {
    if (state['conflictEtag'] == remote.etag &&
        state['conflictNovelId'] is String) {
      final copies = await repository.listNovels(includeArchived: true);
      if (copies.any((n) => n.id == state['conflictNovelId'])) {
        return SyncResult(
          SyncAction.conflict,
          conflictNovelId: state['conflictNovelId'] as String,
          remoteEtag: remote.etag,
        );
      }
    }
    content ??= await backup.read(remote.bytes, passphrase: passphrase);
    if (content.snapshot.novelId != id) {
      throw const FormatException('此同步地址属于另一部作品');
    }
    final copy = await backup.restoreContents(
      content,
      title: '${content.snapshot.title}（远端冲突副本）',
    );
    await repository.setSetting('syncState/$id', {
      ...state,
      'conflictEtag': remote.etag,
      'conflictNovelId': copy.id,
    });
    return SyncResult(
      SyncAction.conflict,
      conflictNovelId: copy.id,
      remoteEtag: remote.etag,
    );
  }

  Future<void> _record(ProjectSnapshot snapshot, String etag) =>
      repository.setSetting('syncState/${snapshot.novelId}', {
        'remoteEtag': etag,
        'localFingerprint': snapshot.fingerprint,
      });
  Future<SyncResult> _upload(
    ProjectSnapshot local,
    String? expectedEtag,
  ) async {
    final bytes = await backup.createSnapshot(local, passphrase: passphrase);
    final etag = await transport.write(bytes, expectedEtag: expectedEtag);
    await _record(local, etag);
    return SyncResult(SyncAction.uploaded, remoteEtag: etag);
  }

  Future<SyncResult> resolveWithLocal(
    String id, {
    required String observedEtag,
  }) => _run(() async {
    final state = await repository.getSetting('syncState/$id') ?? {};
    if (state['conflictEtag'] != observedEtag ||
        state['conflictNovelId'] is! String) {
      throw const ProjectConflict();
    }
    await repository.getNovel(state['conflictNovelId'] as String);
    // Conditional PUT must still match the remote revision shown to the author.
    return _upload(await repository.exportProject(id), observedEtag);
  });
  Future<SyncResult> resolveWithRemote(
    String id, {
    required String observedEtag,
  }) => _run(() async {
    final state = await repository.getSetting('syncState/$id') ?? {};
    if (state['conflictEtag'] != observedEtag) throw const ProjectConflict();
    final remote = await _requireRemote();
    if (remote.etag != observedEtag) throw const ProjectConflict();
    final content = await backup.read(remote.bytes, passphrase: passphrase);
    if (content.snapshot.novelId != id) throw const FormatException('远端作品不匹配');
    final local = await repository.exportProject(id);
    final localBytes = await backup.createSnapshot(
      local,
      passphrase: passphrase,
    );
    final copy = await backup.restore(
      localBytes,
      passphrase: passphrase,
      title: '${local.title}（本机冲突副本）',
    );
    await backup.restoreContents(
      content,
      asCopy: false,
      expectedFingerprint: local.fingerprint,
      syncState: {'remoteEtag': remote.etag},
    );
    return SyncResult(
      SyncAction.downloaded,
      conflictNovelId: copy.id,
      remoteEtag: remote.etag,
    );
  });
}
