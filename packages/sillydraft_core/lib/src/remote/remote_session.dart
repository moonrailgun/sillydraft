import 'dart:async';
import 'dart:convert';
import 'dart:io';

// drift 2.35.2 is pinned by the lock file; both ends ship the same build.
// ignore: experimental_member_use
import 'package:drift/remote.dart';

import '../providers/provider.dart';
import '../storage/story_repository.dart';
import 'links.dart';
import 'reconnecting_executor.dart';
import 'remote_host.dart';
import 'tls.dart';
import 'wire.dart';

/// What a desktop answers a phone that connects.
final class RemoteHello {
  RemoteHello(Map<String, dynamic> json)
    : name = json['name'] as String,
      appVersion = json['appVersion'] as String,
      resourceKey = base64Decode(json['resourceKey'] as String);
  final String name, appVersion;
  final List<int> resourceKey;
}

/// drift's remote protocol and the library schema both need the same build
/// on both devices.
final class RemoteVersionMismatch implements Exception {
  const RemoteVersionMismatch({required this.desktop, required this.phone});
  final String desktop, phone;
  @override
  String toString() => '桌面 $desktop，手机 $phone，请升级到同一版本';
}

/// A request the desktop refused, with its reason.
final class RemoteRequestFailed implements Exception {
  const RemoteRequestFailed(this.status, this.message);
  final int status;
  final String message;

  static Future<RemoteRequestFailed> of(HttpClientResponse response) async {
    final text = await utf8.decodeStream(response);
    try {
      final error = (jsonDecode(text) as Map)['error'];
      if (error is String) {
        return RemoteRequestFailed(response.statusCode, error);
      }
    } on FormatException {
      // Not one of the host's answers.
    }
    return RemoteRequestFailed(
      response.statusCode,
      'HTTP ${response.statusCode}',
    );
  }

  @override
  String toString() => message;
}

/// Whether the desktop is reachable, and why not when it is not.
typedef RemoteStatus = ({bool connected, String? problem});

/// A phone's link to a desktop's library. [repository] lives as long as the
/// session: a dropped connection is retried underneath it.
final class RemoteSession {
  RemoteSession._(
    this.link,
    this.appVersion,
    this.hello,
    this._client,
    this._firstRetry,
  );

  static Future<RemoteSession> connect(
    ConnectLink link, {
    required String appVersion,
    Duration firstRetry = const Duration(seconds: 1),
  }) async {
    final client = pinnedClient(link.fingerprint);
    try {
      final hello = await _hello(client, link, appVersion);
      final session = RemoteSession._(
        link,
        appVersion,
        hello,
        client,
        firstRetry,
      );
      await session._open();
      return session;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  final ConnectLink link;
  final String appVersion;
  final RemoteHello hello;
  final HttpClient _client;
  final Duration _firstRetry;
  final executor = ReconnectingExecutor();
  late final StoryRepository repository = StoryRepository.connect(executor);
  final _statuses = StreamController<RemoteStatus>.broadcast();
  RemoteStatus _status = (connected: false, problem: null);
  WebSocket? _db, _events;
  StreamSubscription<bool>? _writes;
  bool _closed = false;

  RemoteStatus get status => _status;

  /// [status] now, then each change.
  Stream<RemoteStatus> get statuses async* {
    yield _status;
    yield* _statuses.stream;
  }

  Future<HttpClientResponse> send(
    String method,
    String path, {
    Object? json,
    List<int>? bytes,
    GenerationCancellation? cancellation,
  }) => _send(
    _client,
    link,
    method,
    path,
    json: json,
    bytes: bytes,
    cancellation: cancellation,
  );

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Object? json,
    GenerationCancellation? cancellation,
  }) async {
    final response = await send(
      method,
      path,
      json: json,
      cancellation: cancellation,
    );
    if (response.statusCode != 200) {
      throw await RemoteRequestFailed.of(response);
    }
    return jsonDecode(await utf8.decodeStream(response))
        as Map<String, dynamic>;
  }

  Future<void> _open() async {
    final db = await _socket('/v1/db');
    WebSocket? events;
    try {
      events = await _socket('/v1/events');
      final connection = await connectToRemoteAndInitialize(driftChannel(db));
      await executor.attach(connection.executor);
      // Closed meanwhile: these sockets are this call's alone to hang up.
      if (_closed) {
        executor.detach();
        throw const RemoteUnavailable();
      }
    } catch (_) {
      await db.close();
      await events?.close();
      rethrow;
    }
    final live = events;
    _db = db;
    _events = live;
    _writes ??= repository.localWrites.listen(
      (tasksOnly) => _events?.add(jsonEncode({'tasksOnly': tasksOnly})),
    );
    live.listen(
      (frame) => repository.notifyExternal(
        (jsonDecode(frame as String) as Map)['tasksOnly'] == true,
      ),
      onDone: () => _lost(live),
      onError: (Object _) {},
    );
    unawaited(db.done.whenComplete(() => _lost(db)));
    _setStatus((connected: true, problem: null));
  }

  Future<WebSocket> _socket(String path) async => (await WebSocket.connect(
    link.endpoint(path).replace(scheme: 'wss').toString(),
    headers: {HttpHeaders.authorizationHeader: 'Bearer ${link.key}'},
    customClient: _client,
  ))..pingInterval = const Duration(seconds: 10);

  /// [socket] closed: unless it belongs to an earlier connection, every call
  /// now fails until a reconnect succeeds.
  void _lost(WebSocket socket) {
    if (_closed || (socket != _db && socket != _events)) return;
    final problem = socket.closeCode == stoppedCloseCode
        ? '桌面已停止共享'
        : '与桌面断开，正在重连';
    executor.detach(problem);
    unawaited(_db?.close());
    unawaited(_events?.close());
    _db = _events = null;
    _setStatus((connected: false, problem: problem));
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    var delay = _firstRetry;
    while (!_closed) {
      await Future<void>.delayed(delay);
      if (_closed) return;
      try {
        await _hello(_client, link, appVersion);
        if (_closed) return;
        await _open();
        // Whatever the desktop wrote meanwhile never reached this device.
        repository.notifyExternal(false);
        return;
      } catch (e) {
        // Retrying cannot help until one side is updated or the phone scans
        // the desktop's new link. A link merely cut mid-handshake is a
        // HandshakeException too, but not a refused certificate.
        final fatal = switch (e) {
          RemoteVersionMismatch() => '$e',
          RemoteRequestFailed(status: 401, :final message) => message,
          HandshakeException(:final osError?)
              when osError.message.contains('CERTIFICATE_VERIFY_FAILED') =>
            '桌面证书已更换，请重新扫码配对',
          _ => null,
        };
        if (fatal != null) {
          executor.detach(fatal);
          _setStatus((connected: false, problem: fatal));
          return;
        }
        delay = delay * 2 > const Duration(seconds: 15)
            ? const Duration(seconds: 15)
            : delay * 2;
      }
    }
  }

  void _setStatus(RemoteStatus status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _writes?.cancel();
    final db = _db, events = _events;
    _db = _events = null;
    await db?.close();
    await events?.close();
    // An open transaction died with the socket; never wait on it.
    executor.detach();
    await repository.close();
    _client.close(force: true);
    await _statuses.close();
  }
}

Future<RemoteHello> _hello(
  HttpClient client,
  ConnectLink link,
  String appVersion,
) async {
  final response = await _send(client, link, 'GET', '/v1/hello');
  if (response.statusCode != 200) throw await RemoteRequestFailed.of(response);
  final hello = RemoteHello(
    jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>,
  );
  if (hello.appVersion != appVersion) {
    throw RemoteVersionMismatch(desktop: hello.appVersion, phone: appVersion);
  }
  return hello;
}

Future<HttpClientResponse> _send(
  HttpClient client,
  ConnectLink link,
  String method,
  String path, {
  Object? json,
  List<int>? bytes,
  GenerationCancellation? cancellation,
}) async {
  final request = await client.openUrl(method, link.endpoint(path))
    ..followRedirects = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${link.key}');
  // Hanging up is how the desktop learns a call was cancelled.
  cancellation?.onCancel(() => request.abort(const GenerationCancelled()));
  if (json != null) {
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(json)));
  } else if (bytes != null) {
    request.headers.contentType = ContentType.binary;
    request.add(bytes);
  }
  return request.close();
}
