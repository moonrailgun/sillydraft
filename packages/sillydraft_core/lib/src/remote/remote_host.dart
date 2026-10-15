import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
// drift 2.35.2 is pinned by the lock file; both ends ship the same build.
// ignore: experimental_member_use
import 'package:drift/remote.dart';

import '../assets/asset_library.dart';
import '../model/task.dart';
import '../providers/image_provider.dart';
import '../providers/provider.dart';
import '../st/import_types.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';
import 'remote_providers.dart';
import 'share.dart';
import 'tls.dart';
import 'wire.dart';

/// The port a desktop shares its library on unless the author picks another.
const defaultRemotePort = 8790;

/// The WebSocket close code a host sends when the author turns sharing off.
const stoppedCloseCode = 4001;

/// What a desktop shares with paired phones.
final class LibraryAccess {
  LibraryAccess({
    required this.accessKey,
    required this.repository,
    required this.tasks,
    required this.assets,
    required this.resourceKey,
    required this.connections,
    required this.providerFactory,
    required this.imageProviderFactory,
  });
  final String accessKey;
  final StoryRepository repository;
  final TaskControl tasks;
  final AssetLibrary assets;
  final Future<List<int>> Function() resourceKey;

  /// The desktop's saved connections: the only endpoints its keys go to.
  final Future<List<ModelConnection>> Function() connections;
  final ProviderFactory providerFactory;
  final ImageProviderFactory imageProviderFactory;
}

final class _ApiError implements Exception {
  const _ApiError(this.status, this.message);
  final int status;
  final String message;
}

/// A device's HTTPS endpoint: its library for paired phones when [library]
/// is set, and the shares it hands out.
final class RemoteHost {
  RemoteHost._(this._http, this.name, this.appVersion, this.library)
    : _keyHash = library == null
          ? null
          : sha256.convert(utf8.encode(library.accessKey)).bytes,
      _server = library?.repository.remoteServer();

  static Future<RemoteHost> start({
    required TlsIdentity identity,
    required String name,
    required String appVersion,
    LibraryAccess? library,
    int port = defaultRemotePort,
    InternetAddress? address,
  }) async {
    final http = await HttpServer.bindSecure(
      address ?? InternetAddress.anyIPv4,
      port,
      identity.serverContext,
    );
    final host = RemoteHost._(http, name, appVersion, library);
    host._writes = library?.repository.localWrites.listen(host._broadcast);
    http.listen((request) => unawaited(host._handle(request)));
    return host;
  }

  final HttpServer _http;
  final String name, appVersion;
  final LibraryAccess? library;
  final List<int>? _keyHash;
  final DriftServer? _server;
  StreamSubscription<bool>? _writes;

  /// What this host hands out to devices that scan a share code.
  final shares = ShareRegistry();
  final _sockets = <WebSocket>{};
  final _events = <WebSocket>{};
  final _failures = <String, List<DateTime>>{};
  final _lockedUntil = <String, DateTime>{};

  int get port => _http.port;

  Future<void> close() async {
    await _writes?.cancel();
    for (final socket in [..._sockets]) {
      await socket.close(stoppedCloseCode, 'stopped');
    }
    await _server?.shutdown();
    await _http.close(force: true);
  }

  bool _locked(String ip) => _lockedUntil[ip]?.isAfter(DateTime.now()) ?? false;

  /// Ten failures within a minute lock [ip] out for five minutes.
  void _failed(String ip) {
    final now = DateTime.now();
    final recent = (_failures[ip] ??= [])
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))
      ..add(now);
    if (recent.length >= 10) {
      _lockedUntil[ip] = now.add(const Duration(minutes: 5));
      recent.clear();
    }
  }

  bool _authorized(HttpRequest request) {
    final hash = _keyHash;
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (hash == null || auth == null || !auth.startsWith('Bearer ')) {
      return false;
    }
    final candidate = sha256.convert(utf8.encode(auth.substring(7))).bytes;
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate[i] ^ hash[i];
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    final ip = request.connectionInfo?.remoteAddress.address ?? '';
    try {
      if (_locked(ip)) throw const _ApiError(429, '尝试次数过多，请五分钟后再试');
      if (request.uri.path.startsWith('/v1/share/')) {
        final parts = request.uri.pathSegments;
        final payload = request.method == 'GET' && parts.length == 3
            ? shares.take(parts[2])
            : null;
        if (payload == null) {
          _failed(ip);
          throw const _ApiError(404, '分享已失效，请让对方重新打开分享');
        }
        return await _json(request.response, 200, payload.toJson());
      }
      if (!_authorized(request)) {
        _failed(ip);
        throw const _ApiError(401, '访问密钥无效，请重新扫码配对');
      }
      await _route(request, request.uri.path);
    } on _ApiError catch (e) {
      await _reply(request, e.status, e.message);
    } on FileSystemException {
      await _reply(request, 404, '文件不存在');
    } on FormatException catch (e) {
      await _reply(request, 400, e.message);
    } on StateError catch (e) {
      await _reply(request, 409, e.message);
    } catch (e) {
      await _reply(request, 500, '$e');
    }
  }

  Future<void> _route(HttpRequest request, String path) async {
    switch ((request.method, path)) {
      case ('GET', '/v1/hello'):
        await _json(request.response, 200, {
          'name': name,
          'appVersion': appVersion,
          'resourceKey': base64Encode(await library!.resourceKey()),
        });
      case ('GET', '/v1/db'):
        await _server!.serve(driftChannel(await _upgrade(request)));
      case ('GET', '/v1/events'):
        await _eventStream(await _upgrade(request));
      case ('POST', '/v1/tasks/start'):
        await _json(
          request.response,
          200,
          await _startTask(await _body(request)),
        );
      case ('POST', _) when path.startsWith('/v1/tasks/'):
        await _json(
          request.response,
          200,
          await _taskAction(request.uri.pathSegments, await _body(request)),
        );
      case ('POST', '/v1/provider/text'):
        final body = await _body(request);
        final connection = await _savedConnection(body['connection']);
        await _lines(request, (emit, cancel) async {
          final provider = await library!.providerFactory(connection);
          try {
            await for (final event in provider.generate(
              ProviderRequest.fromJson(jsonObject(body['request'], 'request')),
              cancellation: cancel,
            )) {
              emit(encodeProviderEvent(event));
            }
          } finally {
            provider.close();
          }
        });
      case ('POST', '/v1/provider/image'):
        final body = await _body(request);
        final connection = await _savedConnection(body['connection']);
        await _lines(request, (emit, cancel) async {
          final provider = await library!.imageProviderFactory(connection);
          try {
            final image = await provider.generate(
              ImageRequest.fromJson(jsonObject(body['request'], 'request')),
              references: [
                for (final r in (body['references'] as List? ?? []).cast<Map>())
                  ImageReference(
                    bytes: base64Decode(r['data'] as String),
                    mimeType: r['mimeType'] as String,
                  ),
              ],
              cancellation: cancel,
            );
            emit({
              'e': 'image',
              'image': base64Encode(image.bytes),
              'revisedPrompt': image.revisedPrompt,
              'usage': image.usage,
            });
          } finally {
            provider.close();
          }
        });
      case ('POST', '/v1/provider/workflow'):
        final body = await _body(request);
        final connection = await _savedConnection(body['connection']);
        final provider = await library!.imageProviderFactory(connection);
        try {
          if (provider is! WorkflowSource) {
            throw const _ApiError(400, '此连接无法读取 ComfyUI 工作流');
          }
          final source = provider as WorkflowSource;
          await _json(request.response, 200, {
            'nodes': await source.readWorkflow(body['filename'] as String),
          });
        } finally {
          provider.close();
        }
      case ('GET', _) when path.startsWith('/v1/assets/'):
        final match =
            _assetName.firstMatch(request.uri.pathSegments.last) ??
            (throw const _ApiError(404, '文件不存在'));
        final bytes = await library!.assets.readHash(
          match[1]!,
          thumbnail: match[2] == 'jpg',
        );
        request.response.headers.contentType = ContentType.binary;
        request.response.add(bytes);
        await request.response.close();
      case ('PUT', _) when path.startsWith('/v1/assets/'):
        await library!.assets.installBackupFile(
          request.uri.pathSegments.last,
          await _bytes(request, AssetLibrary.maxBytes),
        );
        await _json(request.response, 200, {});
      default:
        throw const _ApiError(404, '接口不存在');
    }
  }

  static const _maxBody = 64 * 1024 * 1024;
  static final _assetName = RegExp(r'^([a-f0-9]{64})\.(png|jpg)$');

  Future<ModelConnection> _savedConnection(Object? raw) async {
    final connection = ModelConnection.fromJson(jsonObject(raw, 'connection'));
    await _checkEndpoints(connection.raw);
    return connection;
  }

  /// Answers [request] as JSON lines while [work] runs, with an empty line
  /// every two seconds: a phone that hung up is noticed at the next write
  /// and its upstream call cancelled.
  Future<void> _lines(
    HttpRequest request,
    Future<void> Function(
      void Function(Map<String, Object?> line) emit,
      GenerationCancellation cancel,
    )
    work,
  ) async {
    final response = request.response
      ..headers.contentType = ContentType(
        'application',
        'x-ndjson',
        charset: 'utf-8',
      )
      ..bufferOutput = false;
    final cancel = GenerationCancellation();
    var finished = false;
    unawaited(
      response.done.then((_) {}, onError: (Object _) {}).whenComplete(() {
        if (!finished) cancel.cancel();
      }),
    );
    void emit(Map<String, Object?> line) => response.writeln(jsonEncode(line));
    final heartbeat = Timer.periodic(
      const Duration(seconds: 2),
      (_) => response.writeln(),
    );
    try {
      await work(emit, cancel);
    } on ProviderException catch (e) {
      emit({
        'e': 'error',
        'code': e.code,
        'message': e.message,
        'status': e.statusCode,
      });
    } on FormatException catch (e) {
      emit({'e': 'error', 'code': 'invalid', 'message': e.message});
    } catch (e) {
      // The answer has begun, so _handle can no longer send a status.
      emit({'e': 'error', 'code': 'desktop', 'message': '$e'});
    } finally {
      heartbeat.cancel();
      finished = true;
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<Uint8List> _bytes(HttpRequest request, int limit) async {
    if (request.contentLength > limit) throw const _ApiError(413, '请求过大');
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(const Duration(seconds: 60))) {
      if (bytes.length + chunk.length > limit) {
        throw const _ApiError(413, '请求过大');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final decoded = jsonDecode(utf8.decode(await _bytes(request, _maxBody)));
    if (decoded is! Map<String, dynamic>) {
      throw const _ApiError(400, '请求须为 JSON 对象');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _startTask(Map<String, dynamic> body) async {
    final input = jsonObject(body['input'], 'input');
    await _checkEndpoints(input);
    final task = await library!.tasks.start(
      branchId: body['branchId'] as String,
      kind: TaskKind.values.byName(body['kind'] as String),
      input: input,
      chapterId: body['chapterId'] as String?,
      baseRevisionId: body['baseRevisionId'] as String?,
      retryOf: body['retryOf'] as String?,
    );
    return {'id': task.id};
  }

  Future<Map<String, dynamic>> _taskAction(
    List<String> parts,
    Map<String, dynamic> body,
  ) async {
    if (parts.length != 4) throw const _ApiError(404, '接口不存在');
    final id = parts[2], tasks = library!.tasks;
    // The phone can write task rows over /v1/db, so check the stored input
    // exactly as the action will read it. Cancel reads the trimmed, cached
    // row, and only a remote task's cancel calls the provider.
    if (parts[3] == 'cancel') {
      final task = await library!.repository.getTask(id, snapshots: false);
      if (task.isRemote) await _checkEndpoints(task.input);
    } else if (parts[3] == 'reconnect') {
      await _checkEndpoints((await library!.repository.getTask(id)).input);
    }
    switch (parts[3]) {
      case 'cancel':
        await tasks.cancel(id);
        return {};
      case 'resume':
        // TaskRunner.resume, from this one read: a re-read could see a row
        // the phone rewrote after the check.
        final old = await library!.repository.getTask(id);
        if (old.isActive || old.status == TaskStatus.completed) {
          throw StateError('此任务无需重新生成');
        }
        await _checkEndpoints(old.input);
        final task = await tasks.start(
          branchId: old.branchId,
          kind: old.kind,
          input: old.input,
          chapterId: old.chapterId,
          baseRevisionId: old.baseRevisionId,
          retryOf: old.id,
        );
        return {'id': task.id};
      case 'reconnect':
        return {'id': (await tasks.reconnectRemote(id)).id};
      case 'confirm':
        return {
          'accepted': await tasks.respondToImageConfirmation(
            id,
            body['confirmationId'] as String,
            approved: body['approved'] == true,
          ),
        };
      default:
        throw const _ApiError(404, '接口不存在');
    }
  }

  /// Refuses any connection in [value] whose endpoint differs from the one
  /// this desktop saved under its id: the desktop's keys go nowhere else.
  /// Local subscriptions are refused outright: a phone-written prompt or
  /// argument would reach a CLI that can read this desktop's files.
  Future<void> _checkEndpoints(Object? value) async {
    final saved = {for (final c in await library!.connections()) c.id: c};
    void visit(Object? node) {
      if (node is Map) {
        // Shaped by what ModelConnection.fromJson requires: a missing
        // protocol defaults there, so it must not exempt a connection.
        if (node['id'] is String && node.containsKey('baseUrl')) {
          if (ModelProtocol.values.asNameMap()[node['protocol']]?.isLocalCli ??
              false) {
            throw const _ApiError(403, '本地订阅只能在桌面上使用');
          }
          final mine = saved[node['id']];
          if (mine == null ||
              connectionEndpointKeys.any((key) => mine.raw[key] != node[key])) {
            throw const _ApiError(403, '连接与桌面保存的不一致，已拒绝');
          }
        }
        node.values.forEach(visit);
      } else if (node is List) {
        node.forEach(visit);
      }
    }

    visit(value);
  }

  Future<WebSocket> _upgrade(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      throw const _ApiError(400, '需要 WebSocket 连接');
    }
    final socket = await WebSocketTransformer.upgrade(request)
      ..pingInterval = const Duration(seconds: 10);
    _sockets.add(socket);
    unawaited(socket.done.whenComplete(() => _sockets.remove(socket)));
    return socket;
  }

  /// Writes from [socket]'s phone reach this desktop and every other phone.
  Future<void> _eventStream(WebSocket socket) async {
    _events.add(socket);
    try {
      await for (final frame in socket) {
        final tasksOnly =
            (jsonDecode(frame as String) as Map)['tasksOnly'] == true;
        library!.repository.notifyExternal(tasksOnly);
        _broadcast(tasksOnly, except: socket);
      }
    } finally {
      _events.remove(socket);
    }
  }

  void _broadcast(bool tasksOnly, {WebSocket? except}) {
    final frame = jsonEncode({'tasksOnly': tasksOnly});
    for (final socket in _events) {
      if (socket != except) socket.add(frame);
    }
  }

  /// An error answer, unless the request already became a WebSocket or
  /// started streaming.
  Future<void> _reply(HttpRequest request, int status, String message) async {
    try {
      await _json(request.response, status, {'error': message});
    } catch (_) {}
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, dynamic> data,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    response.write(jsonEncode(data));
    await response.close();
  }
}
