import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

final class _ApiError implements Exception {
  const _ApiError(this.status, this.message);
  final int status;
  final String message;
}

/// Personal, authenticated execution service. Only configured upstream profiles
/// can be called; clients cannot supply an upstream URL, credential or tool code.
final class RunnerServer {
  RunnerServer._(
    this._http,
    this._db,
    this._lock,
    this._directory,
    this._tokenHash,
    this.profiles,
    this.providerFactory,
    this.imageProviderFactory,
    this.imageDownloadHosts,
    this.maxConcurrent,
    this.maxRequestBytes,
  );

  static final _openDirectories = <String>{};
  static final _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,100}$');
  static const _active = ['queued', 'running'];
  final HttpServer _http;
  final sql.Database _db;
  final RandomAccessFile _lock;
  final String _directory;
  final List<int> _tokenHash;
  final Map<String, ModelConnection> profiles;
  final ProviderFactory providerFactory;
  final ImageProviderFactory? imageProviderFactory;
  final Map<String, List<String>> imageDownloadHosts;
  final int maxConcurrent, maxRequestBytes;
  final _running = <String, Future<void>>{};
  final _cancel = <String, GenerationCancellation>{};
  bool _closing = false;
  Future<void>? _closeFuture;
  Uri get uri => Uri(
    scheme: 'http',
    host: _http.address.address,
    port: _http.port,
    path: '/',
  );

  static Future<RunnerServer> open({
    required Directory directory,
    required String token,
    required Map<String, ModelConnection> profiles,
    required ProviderFactory providerFactory,
    ImageProviderFactory? imageProviderFactory,
    Map<String, List<String>> imageDownloadHosts = const {},
    InternetAddress? address,
    int port = 0,
    int maxConcurrent = 2,
    int maxRequestBytes = 48 * 1024 * 1024,
  }) async {
    if (token.length < 16 ||
        token.length > 1024 ||
        token.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('服务访问令牌须为 16–1024 个字符');
    }
    if (profiles.isEmpty ||
        profiles.keys.any((k) => !_idPattern.hasMatch(k)) ||
        profiles.values.any(
          (c) =>
              c.protocol != ModelProtocol.openAICompatible ||
              c.maxOutputTokens < 1 ||
              c.maxOutputTokens > 131072,
        )) {
      throw const FormatException('请配置有效的直连上游模型及输出上限');
    }
    if (maxConcurrent < 1 ||
        maxConcurrent > 16 ||
        maxRequestBytes < 1024 ||
        maxRequestBytes > 64 * 1024 * 1024) {
      throw const FormatException('服务容量配置无效');
    }
    await directory.create(recursive: true);
    final path = await directory.resolveSymbolicLinks();
    if (!_openDirectories.add(path)) throw StateError('该任务目录已被执行器使用');
    RandomAccessFile? lock;
    sql.Database? db;
    try {
      lock = File('$path/runner.lock').openSync(mode: FileMode.append);
      lock.lockSync(FileLock.exclusive);
      db = sql.sqlite3.open('$path/runner.sqlite');
      db.execute('PRAGMA busy_timeout = 5000');
      db.execute('PRAGMA journal_mode = WAL');
      final version =
          db.select('PRAGMA user_version').single.values.single as int;
      if (version > 1) throw StateError('服务数据版本较新，请升级执行器');
      db.execute('''CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, profile TEXT NOT NULL,
        kind TEXT NOT NULL, input_json TEXT NOT NULL, connection_json TEXT NOT NULL,
        status TEXT NOT NULL, text TEXT NOT NULL DEFAULT '', reasoning TEXT NOT NULL DEFAULT '',
        result_json TEXT NOT NULL DEFAULT '{}', error TEXT NOT NULL DEFAULT '',
        image BLOB, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
      )''');
      db.execute('PRAGMA user_version = 1');
      // A process restart cannot prove whether an upstream accepted a request.
      // Preserve work and require a new explicit job rather than retry billing.
      db.execute(
        "UPDATE jobs SET status = 'interrupted', error = '服务进程中断，已有结果已保留', updated_at = ? WHERE status IN ('queued','running')",
        [DateTime.now().millisecondsSinceEpoch],
      );
      final http = await HttpServer.bind(
        address ?? InternetAddress.loopbackIPv4,
        port,
      );
      final server = RunnerServer._(
        http,
        db,
        lock,
        path,
        sha256.convert(utf8.encode(token)).bytes,
        Map.unmodifiable(profiles),
        providerFactory,
        imageProviderFactory,
        {
          for (final entry in imageDownloadHosts.entries)
            entry.key: List.unmodifiable(entry.value),
        },
        maxConcurrent,
        maxRequestBytes,
      );
      http.idleTimeout = const Duration(seconds: 30);
      http.listen((request) {
        unawaited(server._handle(request));
      });
      return server;
    } catch (_) {
      db?.close();
      lock?.closeSync();
      _openDirectories.remove(path);
      rethrow;
    }
  }

  bool _authorized(HttpRequest request) {
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth == null || !auth.startsWith('Bearer ') || auth.length > 1031) {
      return false;
    }
    final candidate = sha256.convert(utf8.encode(auth.substring(7))).bytes;
    var difference = 0;
    for (var i = 0; i < candidate.length; i++) {
      difference |= candidate[i] ^ _tokenHash[i];
    }
    return difference == 0;
  }

  Map<String, dynamic> _row(String id) {
    final rows = _db.select('SELECT * FROM jobs WHERE id = ?', [id]);
    if (rows.isEmpty) throw const _ApiError(404, '任务不存在');
    return Map<String, dynamic>.from(rows.single);
  }

  Map<String, dynamic> _packet(Map<String, dynamic> row) => {
    'id': row['id'],
    'kind': row['kind'],
    'profile': row['profile'],
    'status': row['status'],
    'text': row['text'],
    'reasoning': row['reasoning'],
    'error': row['error'],
    'createdAt': row['created_at'],
    'updatedAt': row['updated_at'],
    ...jsonDecode(row['result_json'] as String) as Map<String, dynamic>,
  };
  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, dynamic> data,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.write(jsonEncode(data));
    await response.close();
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    if (request.contentLength > maxRequestBytes) {
      throw const _ApiError(413, '请求过大');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > maxRequestBytes) {
        throw const _ApiError(413, '请求过大');
      }
      bytes.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw const _ApiError(400, '请求须为 JSON 对象');
    }
    return decoded;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (!_authorized(request)) throw const _ApiError(401, '认证失败');
      if (_closing) throw const _ApiError(503, '服务正在关闭');
      final parts = request.uri.pathSegments;
      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        await _json(request.response, 200, {
          'data': [
            for (final entry in profiles.entries)
              {
                'id': entry.key,
                'name': entry.value.name,
                'contextWindow': entry.value.contextWindow,
                'maxOutputTokens': entry.value.maxOutputTokens,
              },
          ],
        });
      } else if (request.method == 'POST' && request.uri.path == '/v1/jobs') {
        final body = await _body(request);
        final id = body['id'];
        if (id is! String || !_idPattern.hasMatch(id)) {
          throw const _ApiError(400, '任务标识无效');
        }
        final canonical = _canonical(body),
            fingerprint = sha256
                .convert(utf8.encode(_canonical(body)))
                .toString();
        final old = _db.select('SELECT * FROM jobs WHERE id = ?', [id]);
        if (old.isNotEmpty) {
          if (old.single['fingerprint'] != fingerprint) {
            throw const _ApiError(409, '同一任务标识不能更换输入');
          }
          await _json(
            request.response,
            200,
            _packet(Map<String, dynamic>.from(old.single)),
          );
          return;
        }
        _validate(body);
        final count =
            _db.select('SELECT count(*) AS count FROM jobs').single['count']
                as int;
        final pending =
            _db
                    .select(
                      "SELECT count(*) AS count FROM jobs WHERE status IN ('queued','running')",
                    )
                    .single['count']
                as int;
        if (count >= 1000 || pending >= 64) {
          throw const _ApiError(429, '任务容量已满');
        }
        _checkStorage(utf8.encode(canonical).length);
        final now = DateTime.now().millisecondsSinceEpoch;
        _db.execute(
          '''INSERT INTO jobs(id,fingerprint,profile,kind,input_json,connection_json,status,created_at,updated_at)
          VALUES(?,?,?,?,?,?,'queued',?,?)''',
          [
            id,
            fingerprint,
            body['profile'],
            body['kind'],
            canonical,
            jsonEncode(profiles[body['profile']]!.raw),
            now,
            now,
          ],
        );
        _pump();
        await _json(request.response, 202, _packet(_row(id)));
      } else if (parts.length >= 3 &&
          parts[0] == 'v1' &&
          parts[1] == 'jobs' &&
          _idPattern.hasMatch(parts[2])) {
        final id = parts[2], row = _row(id);
        if (request.method == 'GET' && parts.length == 3) {
          await _json(request.response, 200, _packet(row));
        } else if (request.method == 'DELETE' && parts.length == 3) {
          if (row['status'] == 'completed') {
            throw const _ApiError(409, '任务已完成，请获取结果');
          }
          _update(id, status: 'cancelled');
          _cancel[id]?.cancel();
          await _json(request.response, 200, _packet(_row(id)));
          _pump();
        } else if (request.method == 'GET' &&
            parts.length == 4 &&
            parts[3] == 'image' &&
            row['status'] == 'completed' &&
            row['kind'] == 'image') {
          final bytes = row['image'] as Uint8List;
          request.response.headers.contentType = ContentType.binary;
          request.response.headers.set('Cache-Control', 'no-store');
          request.response.headers.set('X-Content-Type-Options', 'nosniff');
          request.response.contentLength = bytes.length;
          request.response.add(bytes);
          await request.response.close();
        } else {
          throw const _ApiError(404, '接口不存在');
        }
      } else {
        throw const _ApiError(404, '接口不存在');
      }
    } on _ApiError catch (e) {
      request.response.persistentConnection = false;
      await _json(request.response, e.status, {
        'error': e.message,
      }).catchError((Object _) {});
    } on FormatException {
      await _json(request.response, 400, {
        'error': '请求格式无效',
      }).catchError((Object _) {});
    } on TypeError {
      await _json(request.response, 400, {
        'error': '请求字段类型无效',
      }).catchError((Object _) {});
    } on TimeoutException {
      request.response.persistentConnection = false;
      await _json(request.response, 408, {
        'error': '请求读取超时',
      }).catchError((Object _) {});
    } catch (_) {
      // Never return upstream URLs, response bodies, environment values or keys.
      await _json(request.response, 500, {
        'error': '服务暂时无法处理请求',
      }).catchError((Object _) {});
    }
  }

  void _validate(Map<String, dynamic> body) {
    if (body.keys.any(
      (key) =>
          !['id', 'profile', 'kind', 'request', 'references'].contains(key),
    )) {
      throw const _ApiError(400, '包含未知请求字段');
    }
    final profile = profiles[body['profile']];
    if (profile == null) throw const _ApiError(400, '模型配置不存在');
    final request = jsonObject(body['request'], 'request');
    if (body['kind'] == 'text') {
      final text = ProviderRequest.fromJson(request);
      if (text.tools.isNotEmpty ||
          text.messages.length > 256 ||
          (text.messages.isEmpty && (text.completionText ?? '').isEmpty)) {
        throw const _ApiError(400, '远程文本请求无效；编辑工具在客户端执行');
      }
      for (final key in ['max_tokens', 'max_completion_tokens']) {
        final value = text.parameters[key];
        if (value != null &&
            (value is! int || value < 1 || value > profile.maxOutputTokens)) {
          throw const _ApiError(400, '输出长度超过服务端配置上限');
        }
      }
      if (request.containsKey('executionId') ||
          body.containsKey('references')) {
        throw const _ApiError(400, '请求包含不支持的字段');
      }
    } else if (body['kind'] == 'image' && imageProviderFactory != null) {
      final image = ImageRequest.fromJson(request);
      final allowed = imageDownloadHosts[body['profile']] ?? const <String>[];
      if (image.allowedDownloadHosts.any((host) => !allowed.contains(host))) {
        throw const _ApiError(400, '图片下载主机必须由服务端配置');
      }
      final references = body['references'] as List? ?? [];
      if (references.length > 4) throw const _ApiError(400, '最多使用四张参考图片');
      for (final raw in references) {
        final ref = jsonObject(raw, 'reference');
        if (![
              'image/png',
              'image/jpeg',
              'image/webp',
            ].contains(ref['mimeType']) ||
            base64Decode(ref['data'] as String).length > 32 * 1024 * 1024) {
          throw const _ApiError(400, '参考图片格式或大小无效');
        }
      }
    } else {
      throw const _ApiError(400, '不支持的远程任务类型');
    }
  }

  void _checkStorage(int additional) {
    final used =
        _db
                .select(
                  "SELECT coalesce(sum(length(input_json)+length(text)+length(reasoning)+coalesce(length(image),0)),0) AS bytes FROM jobs",
                )
                .single['bytes']
            as int;
    if (used + additional > 1024 * 1024 * 1024) {
      throw const _ApiError(507, '任务资料容量已满');
    }
  }

  void _update(
    String id, {
    String? status,
    String? text,
    String? reasoning,
    Map<String, dynamic>? result,
    String? error,
    Uint8List? image,
  }) {
    final old = _row(id);
    if (!_active.contains(old['status'])) return;
    _db.execute(
      '''UPDATE jobs SET status=?,text=?,reasoning=?,result_json=?,error=?,image=?,updated_at=?
      WHERE id=? AND status IN ('queued','running')''',
      [
        status ?? old['status'],
        text ?? old['text'],
        reasoning ?? old['reasoning'],
        result == null ? old['result_json'] : jsonEncode(result),
        error ?? old['error'],
        image ?? old['image'],
        DateTime.now().millisecondsSinceEpoch,
        id,
      ],
    );
  }

  void _pump() {
    if (_closing) return;
    final queued = _db.select(
      "SELECT id FROM jobs WHERE status='queued' ORDER BY created_at,id LIMIT ?",
      [maxConcurrent - _running.length],
    );
    for (final row in queued) {
      final id = row['id'] as String, cancel = GenerationCancellation();
      _cancel[id] = cancel;
      final future = _execute(id, cancel);
      _running[id] = future;
      unawaited(
        future.whenComplete(() {
          _running.remove(id);
          _cancel.remove(id);
          _pump();
        }),
      );
    }
  }

  Future<void> _execute(String id, GenerationCancellation cancel) async {
    ModelProvider? provider;
    ImageProvider? imageProvider;
    try {
      final row = _row(id);
      if (row['status'] != 'queued') return;
      _update(id, status: 'running');
      final input =
          jsonDecode(row['input_json'] as String) as Map<String, dynamic>;
      final config = ModelConnection.fromJson(
        jsonDecode(row['connection_json'] as String) as Map<String, dynamic>,
      );
      cancel.check();
      if (row['kind'] == 'image') {
        imageProvider = await imageProviderFactory!(config);
        final raw = jsonObject(input['request'], 'request');
        final request = ImageRequest.fromJson({
          ...raw,
          'allowedDownloadHosts':
              imageDownloadHosts[row['profile']] ?? <String>[],
        });
        final refs = [
          for (final r in input['references'] as List? ?? [])
            ImageReference(
              bytes: base64Decode(r['data'] as String),
              mimeType: r['mimeType'] as String,
            ),
        ];
        final output = await imageProvider.generate(
          request,
          references: refs,
          cancellation: cancel,
        );
        cancel.check();
        final bytes = output.bytes;
        if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
          throw const FormatException('图片大小无效');
        }
        _checkStorage(bytes.length);
        _update(
          id,
          status: 'completed',
          image: bytes,
          result: {
            'revisedPrompt': output.revisedPrompt,
            'usage': output.usage,
          },
        );
      } else {
        provider = await providerFactory(config);
        final request = ProviderRequest.fromJson(
          jsonObject(input['request'], 'request'),
        );
        final diagnostics = provider.validateParameters(request);
        if (diagnostics.isNotEmpty) {
          _update(
            id,
            status: 'failed',
            error: '服务端模型配置不支持当前参数',
            result: {
              'diagnostics': diagnostics.map((d) => d.toJson()).toList(),
            },
          );
          return;
        }
        final text = StringBuffer(), reasoning = StringBuffer();
        GenerationFinished? finish;
        await for (final event in provider.generate(
          request,
          cancellation: cancel,
        )) {
          cancel.check();
          switch (event) {
            case TextDelta():
              text.write(event.text);
            case ReasoningDelta():
              reasoning.write(event.text);
            case ToolCallReady():
              throw const FormatException('远程文本任务不能执行编辑工具');
            case GenerationFinished():
              finish = event;
          }
          if (text.length > 1024 * 1024 || reasoning.length > 1024 * 1024) {
            throw const FormatException('输出过大');
          }
          _update(id, text: text.toString(), reasoning: reasoning.toString());
        }
        cancel.check();
        if (finish == null ||
            !finish.isComplete ||
            text.toString().trim().isEmpty) {
          throw const FormatException('模型未完整结束');
        }
        _update(
          id,
          status: 'completed',
          result: {
            'finish': {'reason': finish.reason, 'usage': finish.usage},
          },
        );
      }
    } on GenerationCancelled {
      _update(id, status: _closing ? 'interrupted' : 'cancelled');
    } catch (_) {
      _update(id, status: 'failed', error: '模型执行未完成，请检查服务端模型配置；已有输出已保留');
    } finally {
      provider?.close();
      imageProvider?.close();
    }
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    await _http.close(force: true);
    _db.execute(
      "UPDATE jobs SET status='interrupted',error='服务进程关闭，已有结果已保留',updated_at=? WHERE status IN ('queued','running')",
      [DateTime.now().millisecondsSinceEpoch],
    );
    for (final cancel in _cancel.values.toList()) {
      cancel.cancel();
    }
    await Future.wait(_running.values.toList());
    _db.close();
    _lock.closeSync();
    _openDirectories.remove(_directory);
  }
}

String _canonical(Object? value) => jsonEncode(_ordered(value));
Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return value.map(_ordered).toList();
  return value;
}
