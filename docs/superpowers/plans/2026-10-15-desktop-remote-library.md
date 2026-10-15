# 桌面远程作品库与扫码传输 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 桌面端一个开关把作品库共享给手机（手机扫码后书架、正文、资料、任务全部读写桌面那一份，生成在桌面执行），并让资源、技能、人设、模型连接能扫码在设备间传一份副本。

**Architecture:** 核心包新增 `src/remote/`：桌面的 `RemoteHost` 在一个 HTTPS 端口上提供 drift 远程协议（`WS /v1/db`）、写入通知（`WS /v1/events`）、任务控制、模型代理、文件与分享接口；手机的 `RemoteSession` 用证书指纹锁定连接，数据库执行器可在断线后换连接而仓库对象不变。服务层把 `TaskRunner` 抽象为 `TaskControl`，远程实现把任务交给桌面；`AssetLibrary` 增加按哈希上传下载的镜像。界面层用 `LibraryHost` 在本机与桌面两套 `AppServices` 之间切换，重建 `ProviderScope`。

**Tech Stack:** Flutter 3.47.7 / Dart 3.13.5，Riverpod，forui，drift 2.35.2（`package:drift/remote.dart`），`dart:io` HttpServer/WebSocket，`basic_utils`（自签证书），`qr_flutter`，`mobile_scanner`，`package:test` 与 `flutter_test`。

**Spec:** `docs/superpowers/specs/2026-10-15-desktop-remote-library-design.md`

## Global Constraints

- 基线 Flutter 3.47.7 / Dart 3.13.5。只新增 `basic_utils`（核心包）、`qr_flutter` 与 `mobile_scanner`（应用）；核心包把锁文件里已有的 `stream_channel` 改为直接依赖。新增依赖用 `dart pub add` / `flutter pub add` 更新锁文件，之后的安装照常用 `--enforce-lockfile`。
- 文档与界面中文，代码与注释英文；注释密度与周围代码一致。
- 测试使用本地脚本 provider、本地回环地址上的真实服务，不调用付费模型。
- 不提交：这个工作区有其他会话同时修改，按作者要求不执行 `git commit`。每个任务以格式化、静态检查和相关测试收尾。
- 格式检查（仓库根目录）：`dart format --output=none --set-exit-if-changed lib test integration_test test_driver tool packages/sillydraft_core/lib packages/sillydraft_core/test server/lib server/bin server/test`
- 核心包命令在 `packages/sillydraft_core` 下运行：`dart analyze`、`dart test …`；界面命令在仓库根目录：`flutter analyze`、`flutter test …`。
- 默认端口 `8790`（`defaultRemotePort`）；WebSocket 心跳 10 秒；分享有效期 10 分钟、取用一次即失效；同一 IP 一分钟内失败 10 次后封锁 5 分钟；桌面主动停止共享的关闭码 `4001`（`stoppedCloseCode`）。
- 本机密钥文件键：`remote/tls`（证书与私钥 JSON）、`remote/access-key`、`remote/paired`（手机已配对桌面的链接列表）。库内设置键：`remoteHost` = `{enabled: bool, port: int}`。
- 两端应用版本字符串 `'<version>+<build>'` 必须完全相同才能连接。
- 只有手机（`defaultTargetPlatform` 为 Android / iOS）显示作品库切换入口；只有非手机平台显示“手机连接”设置页。

## Review Focus

- 已配对的桌面重新生成了密钥：手机用旧链接切换时应报“访问密钥无效”并留在本机作品库，不应白屏或丢掉本机数据。测试在 Task 10。
- 使用中桌面升级了版本并重启：手机应停止重试并显示两端版本，不能一直转圈重连。测试在 Task 6。
- 打开“允许手机连接”时端口被占用：应显示原因，开关保持关闭，下次启动不再尝试。测试在 Task 10。
- 桌面重新生成密钥后手机重新扫码：配对列表按证书指纹替换旧条目，不出现两个同名桌面。测试在 Task 13。
- 很长的章节（数 MB 的正文 JSON）经 WebSocket 读写：应完整往返。测试在 Task 5。

---

### Task 1: 仓库的跨设备写入通知与 drift 服务端

**Files:**
- Modify: `packages/sillydraft_core/pubspec.yaml`
- Modify: `packages/sillydraft_core/lib/src/storage/story_repository.dart:1-90`
- Test: `packages/sillydraft_core/test/remote_repository_test.dart`

**Interfaces:**
- Produces:
  - `factory StoryRepository.connect(QueryExecutor executor)`：在另一台设备打开并迁移好的库上建仓库，本端从不迁移。
  - `Stream<bool> get localWrites`：本仓库 `_write` 提交的写入（值为 `tasksOnly`）。
  - `void notifyExternal(bool tasksOnly)`：把别处的写入并入 `changes` / `contentChanges`，不进入 `localWrites`。
  - `DriftServer remoteServer()`：把本仓库的数据库执行器提供给远程客户端，关闭服务端不关闭数据库。

- [ ] **Step 1: 把 `stream_channel` 改为直接依赖**

在 `packages/sillydraft_core` 下运行：

```sh
dart pub add stream_channel
```

Expected: `pubspec.yaml` 的 `dependencies` 出现 `stream_channel: ^2.1.4`（锁文件里该包由 transitive 改为 direct main，版本不变）。

- [ ] **Step 2: 写失败测试**

`packages/sillydraft_core/test/remote_repository_test.dart`：

```dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/remote.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

final class _User implements QueryExecutorUser {
  @override
  int get schemaVersion => 9;
  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
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

  test('a device that drops mid-transaction leaves the library writable', () async {
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
    expect(finishedEarly, isFalse, reason: 'the open transaction holds the db');
    await pipe.foreign.sink.close();
    await blocked.timeout(const Duration(seconds: 5));
    expect(await desktop.getSetting('during'), {'ok': true});
  });
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `dart test test/remote_repository_test.dart`
Expected: 编译失败，`remoteServer`、`StoryRepository.connect`、`localWrites`、`notifyExternal` 未定义。

- [ ] **Step 4: 实现**

`story_repository.dart` 顶部 import 增加：

```dart
import 'package:drift/remote.dart';
```

在 `factory StoryRepository.open(...)` 之后加入：

```dart
  /// A library another device serves: [executor] reaches a database that
  /// device opened and migrated. This side never migrates it.
  factory StoryRepository.connect(QueryExecutor executor) =>
      StoryRepository._(StoryDatabase(executor));
```

在 `final _changes = StreamController<bool>.broadcast();` 之后加入：

```dart
  final _local = StreamController<bool>.broadcast();
```

在 `Stream<void> get contentChanges => …;` 之后加入：

```dart
  /// This repository's own committed writes, as whether they touched only
  /// generation tasks: what a remote link forwards to other devices.
  Stream<bool> get localWrites => _local.stream;

  /// A write another device committed to the same database.
  void notifyExternal(bool tasksOnly) {
    if (!_closed) _changes.add(tasksOnly);
  }

  /// Serves this repository's database to remote devices. Shutting the
  /// server down leaves the database open; [close] closes it.
  DriftServer remoteServer() =>
      DriftServer(_db.executor, closeConnectionAfterShutdown: false);
```

`close()` 中 `await _changes.close();` 之后加入 `await _local.close();`。

`_write` 中 `_changes.add(tasksOnly);` 之后加入：

```dart
    _local.add(tasksOnly);
```

- [ ] **Step 5: 运行测试确认通过**

Run: `dart test test/remote_repository_test.dart`
Expected: PASS（3 个用例）。若第三个用例的 `finishedEarly` 为 true，说明桌面执行器不串行事务，停下来报告，不要删掉这条断言。

- [ ] **Step 6: 静态检查与全量测试**

Run: `dart analyze && dart test`
Expected: 无问题，全部通过。若 `dart analyze` 对 `package:drift/remote.dart` 报 `experimental_member_use`，在 import 上一行加 `// drift 2.35.2 is pinned by the lock file; both ends ship the same build.` 与 `// ignore: experimental_member_use`，其余文件同样处理。

---

### Task 2: 任务控制接口 `TaskControl`

**Files:**
- Modify: `packages/sillydraft_core/lib/src/tasks/task_runner.dart:73-210`
- Modify: `packages/sillydraft_core/lib/src/agent/writing_service.dart:42`
- Modify: `packages/sillydraft_core/lib/src/agent/persona_service.dart:40`
- Modify: `packages/sillydraft_core/lib/src/agent/illustration_service.dart:13`
- Modify: `packages/sillydraft_core/lib/src/agent/editor_agent.dart:21`
- Modify: `packages/sillydraft_core/lib/src/agent/sidecar_agent.dart:132`
- Modify: `packages/sillydraft_core/test/agent_image_test.dart:135-150,246,415`
- Modify: `lib/app/services.dart:214`

**Interfaces:**
- Produces: `abstract interface class TaskControl`（成员见下）；`TaskRunner implements TaskControl`；`respondToImageConfirmation` 改为返回 `Future<bool>`；五个服务的 `runner` 字段类型改为 `TaskControl`；`AppServices.runner` 类型改为 `TaskControl`。
- 旁路整理随之走同一条路：`SidecarAgent` 只用 `start` / `wait` / `cancel`，`lib/features/lore/sidecar.dart` 的 `awaitSidecar` 只用 `services.runner.wait`（3 分钟上限）。远程模式下它们得到 Task 7 的 `RemoteTaskControl`，旁路任务在桌面执行；`result['transcript']` 的裁剪全在 SQL 里，经远程数据库不变。不需要额外改动。

- [ ] **Step 1: 改测试为异步确认（先让它失败）**

`agent_image_test.dart` 第 135–150 行改为：

```dart
      expect(
        await runner.respondToImageConfirmation(
          task.id,
          'stale',
          approved: true,
        ),
        isFalse,
      );
      expect(
        await runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: true,
        ),
        isTrue,
      );
      expect(
        await runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: true,
        ),
        isFalse,
      );
```

第 246 行与第 415 行的 `runner.respondToImageConfirmation(` 前加 `await `。

Run: `dart analyze test/agent_image_test.dart`
Expected: 报 `await_only_futures`（返回值还是 `bool`）。这一步的“失败”以静态检查为准，测试本身仍会通过。

- [ ] **Step 2: 定义接口并让 `TaskRunner` 实现**

在 `task_runner.dart` 的 `final class TaskRunner {` 之前加入：

```dart
/// What services and screens need from task execution. [TaskRunner] runs
/// tasks in this process; a remote library hands them to the desktop.
abstract interface class TaskControl {
  ProviderFactory get providerFactory;
  ImageProviderFactory? get imageProviderFactory;
  AssetLibrary? get assetLibrary;
  Future<int> recoverInterrupted();
  Future<GenerationTask> start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? chapterId,
    String? baseRevisionId,
    String? retryOf,
  });
  Future<GenerationTask> wait(String id);
  Future<void> cancel(String id);
  Future<GenerationTask> reconnectRemote(String id);
  Future<GenerationTask> resume(String id);

  /// An answer applies only to this pending request, never a later tool call.
  Future<bool> respondToImageConfirmation(
    String taskId,
    String confirmationId, {
    required bool approved,
  });
  Future<void> close();
}
```

`final class TaskRunner {` 改为 `final class TaskRunner implements TaskControl {`。给 `repository` 以外的三个字段（`providerFactory`、`imageProviderFactory`、`assetLibrary`）与 `recoverInterrupted`、`start`、`wait`、`cancel`、`reconnectRemote`、`resume`、`close` 加 `@override`。`respondToImageConfirmation` 改为：

```dart
  @override
  Future<bool> respondToImageConfirmation(
    String taskId,
    String confirmationId, {
    required bool approved,
  }) async {
```

（方法体不变，原先文档注释移到接口上，这里删去。）

- [ ] **Step 3: 服务改用接口**

五个文件里 `final TaskRunner runner;` 改为 `final TaskControl runner;`。`lib/app/services.dart` 的 `late final TaskRunner runner;` 改为 `late final TaskControl runner;`。

- [ ] **Step 4: 运行检查与测试**

Run（核心包）: `dart analyze && dart test`
Run（根目录）: `flutter analyze && flutter test test/agent_flow_test.dart`
Expected: 全部通过。若 `flutter analyze` 报 `lib/features/agent/agent_screen.dart:396` 处 `void answer(...) =>` 返回 Future 的问题，改为 `void answer(bool approved) => unawaited(ref.read(servicesProvider).runner.respondToImageConfirmation(task.id, pending['id'] as String, approved: approved));` 并确认文件已 import `dart:async`。

---

### Task 3: 文件库的远程镜像

**Files:**
- Modify: `packages/sillydraft_core/lib/src/assets/asset_library.dart`
- Modify: `lib/features/illustrations/asset_image.dart`
- Modify: `lib/features/personas/persona_editor_screen.dart:290-305`
- Test: `packages/sillydraft_core/test/asset_library_test.dart`

**Interfaces:**
- Produces:
  - `abstract interface class AssetMirror { Future<Uint8List> download(String name); Future<void> upload(String name, Uint8List bytes); }`，`name` 形如 `<64 位哈希>.png|jpg`。
  - `AssetLibrary({required repository, required directory, AssetMirror? mirror})`：有镜像时，本地只是缓存；写入的文件同时上传，缺失的文件先下载。`pruneOrphans` 在有镜像时返回 0。
  - `Future<File> fileForHash(String hash, {bool thumbnail = false})`：按哈希取本地文件，必要时先下载。
  - 界面 `HashImageView({required String hash, bool thumbnail, BoxFit fit, double? width, double? height, String label})`。

- [ ] **Step 1: 写失败测试**

在 `asset_library_test.dart` 末尾 `main` 内加入（文件顶部如无则补 `import 'package:image/image.dart' as img;`、`import 'dart:typed_data';`）：

```dart
  group('mirror', () {
    late Directory root;
    late StoryRepository repository;
    late _Mirror mirror;
    final png = Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));
    setUp(() async {
      root = await Directory.systemTemp.createTemp('sd-mirror');
      repository = StoryRepository.memory();
      mirror = _Mirror();
    });
    tearDown(() async {
      await repository.close();
      await root.delete(recursive: true);
    });
    AssetLibrary device(String name) => AssetLibrary(
      repository: repository,
      directory: Directory('${root.path}/$name'),
      mirror: mirror,
    );

    test('uploads what it prepares and fetches what it lacks', () async {
      final prepared = await device('phone').prepare(png);
      expect(
        mirror.files.keys,
        containsAll(['${prepared.hash}.png', '${prepared.thumbnailHash}.jpg']),
      );
      final other = device('other');
      expect(await other.readHash(prepared.hash), mirror.files['${prepared.hash}.png']);
      final thumb = await other.fileForHash(prepared.thumbnailHash, thumbnail: true);
      expect(thumb.existsSync(), isTrue);
      expect(await other.pruneOrphans(), 0);
    });

    test('refuses a download that does not match its hash', () async {
      final prepared = await device('phone').prepare(png);
      mirror.files['${prepared.hash}.png'] = Uint8List.fromList([1, 2, 3]);
      await expectLater(
        device('other').readHash(prepared.hash),
        throwsA(isA<FormatException>()),
      );
    });
  });
```

文件末尾（`main` 之外）加入：

```dart
final class _Mirror implements AssetMirror {
  final files = <String, Uint8List>{};
  @override
  Future<Uint8List> download(String name) async =>
      files[name] ?? (throw const FormatException('missing'));
  @override
  Future<void> upload(String name, Uint8List bytes) async =>
      files[name] = bytes;
}
```

Run: `dart test test/asset_library_test.dart`
Expected: 编译失败，`AssetMirror`、`mirror`、`fileForHash` 未定义。

- [ ] **Step 2: 实现镜像**

`asset_library.dart`，在 `final class AssetLibrary {` 之前加入：

```dart
/// Where a remote library's files live. This device keeps a copy of each
/// file it reads or writes; the desktop keeps the library's own.
abstract interface class AssetMirror {
  /// `<hash>.png` or `<hash>.jpg`.
  Future<Uint8List> download(String name);
  Future<void> upload(String name, Uint8List bytes);
}
```

构造函数与字段：

```dart
  AssetLibrary({required this.repository, required this.directory, this.mirror});
  final StoryRepository repository;
  final Directory directory;

  /// Set for a remote library: [directory] is then only a cache.
  final AssetMirror? mirror;
```

`pruneOrphans` 开头加入：

```dart
    // ponytail: the cache of a remote library is never trimmed; add an LRU
    // when phones run short of space. The desktop prunes the library itself.
    if (mirror != null) return 0;
```

把现有 `_writeFile` 改名为 `_storeLocal`（方法体不变），并新增：

```dart
  Future<void> _writeFile(
    String hash,
    String extension,
    Uint8List bytes,
  ) async {
    await _storeLocal(hash, extension, bytes);
    await mirror?.upload('$hash.$extension', bytes);
  }

  /// [hash].[extension] on this device, fetched from the mirror first when
  /// only the desktop has it.
  Future<File> _local(String hash, String extension) async {
    final target = _path(hash, extension);
    final mirror = this.mirror;
    if (mirror == null || await target.exists()) return target;
    final bytes = await mirror.download('$hash.$extension');
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('图片文件校验失败');
    }
    await _storeLocal(hash, extension, bytes);
    return target;
  }

  /// A stored file by content hash, fetched first for a remote library.
  Future<File> fileForHash(String hash, {bool thumbnail = false}) =>
      _local(hash, thumbnail ? 'jpg' : 'png');
```

`hashFile` 的文档注释改为 `/// The local path of a file by content hash; [fileForHash] also fetches.`

`readHash` 改为：

```dart
  Future<Uint8List> readHash(String hash, {bool thumbnail = false}) async {
    final bytes = await (await fileForHash(hash, thumbnail: thumbnail))
        .readAsBytes();
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('图片文件已损坏');
    }
    return bytes;
  }
```

`file(String assetId, …)` 中：

```dart
    final target = _path(
      thumbnail ? asset.thumbnailHash : asset.hash,
      thumbnail ? 'jpg' : 'png',
    );
```

改为：

```dart
    final target = await _local(
      thumbnail ? asset.thumbnailHash : asset.hash,
      thumbnail ? 'jpg' : 'png',
    );
```

- [ ] **Step 3: 运行核心测试**

Run: `dart test test/asset_library_test.dart test/persona_service_test.dart test/persona_test.dart`
Expected: PASS。

- [ ] **Step 4: 界面按哈希显示图片**

`lib/features/illustrations/asset_image.dart` 末尾加入：

```dart
final _hashFileProvider =
    FutureProvider.family<File, ({String hash, bool thumbnail})>((
      ref,
      key,
    ) async {
      final library = ref.watch(servicesProvider).assets;
      if (library == null) throw const FormatException('本地图片目录尚未配置');
      return library.fileForHash(key.hash, thumbnail: key.thumbnail);
    });

/// A stored image by content hash, such as a persona's reference picture.
class HashImageView extends ConsumerWidget {
  const HashImageView({
    super.key,
    required this.hash,
    this.thumbnail = false,
    this.fit = BoxFit.contain,
    this.height,
    this.width,
    this.label = '图片',
  });
  final String hash, label;
  final bool thumbnail;
  final BoxFit fit;
  final double? height, width;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_hashFileProvider((hash: hash, thumbnail: thumbnail)))
      .when(
        data: (file) => Image.file(
          file,
          fit: fit,
          height: height,
          width: width,
          semanticLabel: label,
          errorBuilder: (_, _, _) => _missing(),
        ),
        loading: () => SizedBox(
          height: height,
          width: width,
          child: const Center(child: FCircularProgress()),
        ),
        error: (_, _) => _missing(),
      );
  Widget _missing() => SizedBox(
    height: height,
    width: width,
    child: const Center(child: Text('图片暂不可用')),
  );
}
```

`persona_editor_screen.dart` 中：

```dart
                            child: library == null
                                ? missing()
                                : Image.file(
                                    library.hashFile(
                                      image.thumbnailHash,
                                      thumbnail: true,
                                    ),
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.cover,
                                    semanticLabel: '参考图',
                                    errorBuilder: (_, _, _) => missing(),
                                  ),
```

改为：

```dart
                            child: library == null
                                ? missing()
                                : HashImageView(
                                    hash: image.thumbnailHash,
                                    thumbnail: true,
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.cover,
                                    label: '参考图',
                                  ),
```

并 import `'../illustrations/asset_image.dart'`（若尚未导入）。

- [ ] **Step 5: 检查与界面测试**

Run（根目录）: `flutter analyze && flutter test test/persona_flow_test.dart test/illustration_flow_test.dart`
Expected: 通过（若 `test/persona_flow_test.dart` 不存在，运行 `flutter test` 中与人设相关的文件：`grep -l Persona test/*.dart`）。

---

### Task 4: 链接与 TLS 身份

**Files:**
- Modify: `packages/sillydraft_core/pubspec.yaml`
- Create: `packages/sillydraft_core/lib/src/remote/links.dart`
- Create: `packages/sillydraft_core/lib/src/remote/tls.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`
- Test: `packages/sillydraft_core/test/remote_links_test.dart`

**Interfaces:**
- Produces:
  - `sealed class SillyDraftLink { static SillyDraftLink parse(String text); Uri get uri; }`
  - `final class ConnectLink extends SillyDraftLink`：`host`、`port`、`key`、`fingerprint`、`name`；`Uri endpoint(String path)`（https）。
  - `final class ReceiveLink extends SillyDraftLink`：`host`、`port`、`token`、`fingerprint`；`Uri get endpoint`（`/v1/share/<token>`）。
  - `String randomSecret()`：32 随机字节的无填充 base64url（43 字符）。
  - `Future<List<String>> reachableAddresses()`：本机非回环 IPv4，局域网在前，`100.x` 其次。
  - `final class TlsIdentity`：`TlsIdentity.generate()`、`fromJson`/`toJson`、`String get fingerprint`（DER 的 SHA-256 小写十六进制）、`SecurityContext get serverContext`。
  - `HttpClient pinnedClient(String fingerprint)`：不信任系统根证书，只接受该指纹。

- [ ] **Step 1: 添加依赖**

在 `packages/sillydraft_core` 下运行：`dart pub add basic_utils`
Expected: `pubspec.yaml` 增加 `basic_utils: ^<当前版本>`，锁文件更新。

- [ ] **Step 2: 写失败测试**

`packages/sillydraft_core/test/remote_links_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  final identity = TlsIdentity.generate();

  test('links survive a round trip, including a Chinese name', () {
    final link = ConnectLink(
      host: '192.168.1.5',
      port: 8790,
      key: randomSecret(),
      fingerprint: identity.fingerprint,
      name: '书房的 Mac',
    );
    final parsed = SillyDraftLink.parse('$link') as ConnectLink;
    expect(parsed.host, link.host);
    expect(parsed.port, 8790);
    expect(parsed.key, link.key);
    expect(parsed.fingerprint, link.fingerprint);
    expect(parsed.name, '书房的 Mac');
    final receive = ReceiveLink(
      host: '10.0.0.2',
      port: 51000,
      token: randomSecret(),
      fingerprint: identity.fingerprint,
    );
    final back = SillyDraftLink.parse(' ${receive.uri} ') as ReceiveLink;
    expect(back.token, receive.token);
    expect(back.endpoint.path, '/v1/share/${receive.token}');
  });

  test('an IPv6 host is bracketed in endpoints', () {
    final link = ConnectLink(
      host: 'fe80::1',
      port: 8790,
      key: randomSecret(),
      fingerprint: identity.fingerprint,
      name: 'x',
    );
    expect('${link.endpoint('/v1/hello')}', 'https://[fe80::1]:8790/v1/hello');
    expect((SillyDraftLink.parse('$link') as ConnectLink).host, 'fe80::1');
  });

  test('malformed links are refused', () {
    final good = ConnectLink(
      host: '192.168.1.5',
      port: 8790,
      key: randomSecret(),
      fingerprint: identity.fingerprint,
      name: 'x',
    ).uri;
    for (final bad in [
      'https://example.com',
      good.replace(scheme: 'http').toString(),
      good.replace(queryParameters: {...good.queryParameters, 'port': '0'}).toString(),
      good.replace(queryParameters: {...good.queryParameters, 'key': 'short'}).toString(),
      good.replace(queryParameters: {...good.queryParameters, 'fp': 'xyz'}).toString(),
    ]) {
      expect(() => SillyDraftLink.parse(bad), throwsFormatException, reason: bad);
    }
  });

  test('secrets are 43 url-safe characters and never repeat', () {
    final a = randomSecret(), b = randomSecret();
    expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(a, isNot(b));
  });

  test('an identity keeps its fingerprint through JSON', () {
    final copy = TlsIdentity.fromJson(
      jsonDecode(jsonEncode(identity.toJson())) as Map<String, dynamic>,
    );
    expect(copy.fingerprint, identity.fingerprint);
    expect(identity.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
  });

  test('a pinned client reaches only the identity it was given', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.serverContext,
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('ok');
      request.response.close();
    });
    Future<String> get(String fingerprint) async {
      final client = pinnedClient(fingerprint);
      try {
        final request = await client.getUrl(
          Uri.parse('https://127.0.0.1:${server.port}/'),
        );
        return utf8.decodeStream(await request.close());
      } finally {
        client.close(force: true);
      }
    }

    expect(await get(identity.fingerprint), 'ok');
    await expectLater(get('0' * 64), throwsA(isA<HandshakeException>()));
  });
}
```

Run: `dart test test/remote_links_test.dart`
Expected: 编译失败，类型未定义。

- [ ] **Step 3: 实现链接**

`packages/sillydraft_core/lib/src/remote/links.dart`：

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A `sillydraft://` link from a QR code or a paste.
sealed class SillyDraftLink {
  const SillyDraftLink();

  static SillyDraftLink parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'sillydraft') {
      throw const FormatException('不是 SillyDraft 链接');
    }
    return switch (uri.host) {
      'connect' => ConnectLink._parse(uri.queryParameters),
      'receive' => ReceiveLink._parse(uri.queryParameters),
      _ => throw const FormatException('不是 SillyDraft 链接'),
    };
  }

  Uri get uri;
  @override
  String toString() => uri.toString();
}

/// Pairs a phone with a desktop's library: where it is, the access key and
/// the certificate it serves.
final class ConnectLink extends SillyDraftLink {
  const ConnectLink({
    required this.host,
    required this.port,
    required this.key,
    required this.fingerprint,
    required this.name,
  });
  factory ConnectLink._parse(Map<String, String> q) => ConnectLink(
    host: _host(q),
    port: _port(q),
    key: _secret(q, 'key'),
    fingerprint: _fingerprint(q),
    name: (q['name'] ?? '').trim().isEmpty ? '桌面' : q['name']!.trim(),
  );
  final String host, key, fingerprint, name;
  final int port;

  @override
  Uri get uri => Uri(
    scheme: 'sillydraft',
    host: 'connect',
    queryParameters: {
      'host': host,
      'port': '$port',
      'key': key,
      'fp': fingerprint,
      'name': name,
    },
  );

  Uri endpoint(String path) =>
      Uri(scheme: 'https', host: host, port: port, path: path);
}

/// Fetches one shared item, once, from the device showing the code.
final class ReceiveLink extends SillyDraftLink {
  const ReceiveLink({
    required this.host,
    required this.port,
    required this.token,
    required this.fingerprint,
  });
  factory ReceiveLink._parse(Map<String, String> q) => ReceiveLink(
    host: _host(q),
    port: _port(q),
    token: _secret(q, 't'),
    fingerprint: _fingerprint(q),
  );
  final String host, token, fingerprint;
  final int port;

  @override
  Uri get uri => Uri(
    scheme: 'sillydraft',
    host: 'receive',
    queryParameters: {
      'host': host,
      'port': '$port',
      't': token,
      'fp': fingerprint,
    },
  );

  Uri get endpoint =>
      Uri(scheme: 'https', host: host, port: port, path: '/v1/share/$token');
}

String _host(Map<String, String> q) {
  final host = q['host'] ?? '';
  if (InternetAddress.tryParse(host) == null &&
      !RegExp(r'^[A-Za-z0-9.-]{1,253}$').hasMatch(host)) {
    throw const FormatException('链接中的地址无效');
  }
  return host;
}

int _port(Map<String, String> q) {
  final port = int.tryParse(q['port'] ?? '');
  if (port == null || port < 1 || port > 65535) {
    throw const FormatException('链接中的端口无效');
  }
  return port;
}

String _secret(Map<String, String> q, String name) {
  final value = q[name] ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw const FormatException('链接中的密钥无效');
  }
  return value;
}

String _fingerprint(Map<String, String> q) {
  final value = q['fp'] ?? '';
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('链接中的证书指纹无效');
  }
  return value;
}

/// 32 random bytes as unpadded base64url: access keys and share tokens.
String randomSecret() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// This device's IPv4 addresses another device might reach: private LAN
/// ranges first, then Tailscale-style `100.x`, then the rest.
Future<List<String>> reachableAddresses() async {
  final all = [
    for (final face in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final address in face.addresses)
        if (!address.isLoopback) address.address,
  ];
  int rank(String a) =>
      a.startsWith('192.168.') ||
          a.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a)
      ? 0
      : a.startsWith('100.')
      ? 1
      : 2;
  return all..sort((a, b) => rank(a).compareTo(rank(b)));
}
```

- [ ] **Step 4: 实现 TLS 身份**

`packages/sillydraft_core/lib/src/remote/tls.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// The certificate a device serves its links with. Self-signed: links carry
/// its fingerprint, and clients trust nothing else. EC P-256, since an RSA
/// key pair takes seconds to generate in Dart on a phone.
final class TlsIdentity {
  const TlsIdentity({required this.certificatePem, required this.privateKeyPem});

  factory TlsIdentity.generate() {
    final pair = CryptoUtils.generateEcKeyPair();
    final private = pair.privateKey as ECPrivateKey;
    final public = pair.publicKey as ECPublicKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'SillyDraft'},
      private,
      public,
    );
    return TlsIdentity(
      certificatePem: X509Utils.generateSelfSignedCertificate(
        private,
        csr,
        3650,
      ),
      privateKeyPem: CryptoUtils.encodeEcPrivateKeyToPem(private),
    );
  }

  factory TlsIdentity.fromJson(Map<String, dynamic> json) => TlsIdentity(
    certificatePem: json['certificate'] as String,
    privateKeyPem: json['privateKey'] as String,
  );

  final String certificatePem, privateKeyPem;

  Map<String, String> toJson() => {
    'certificate': certificatePem,
    'privateKey': privateKeyPem,
  };

  /// SHA-256 of the certificate's DER bytes, lowercase hex.
  String get fingerprint {
    final body = certificatePem.replaceAll(RegExp(r'-----[^-]+-----|\s'), '');
    return sha256.convert(base64Decode(body)).toString();
  }

  SecurityContext get serverContext => SecurityContext()
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}

/// An HTTP client that accepts only the certificate with [fingerprint]. It
/// trusts no system roots, so even a publicly trusted certificate fails.
HttpClient pinnedClient(String fingerprint) =>
    HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 10)
      ..badCertificateCallback = (certificate, _, _) =>
          sha256.convert(certificate.der).toString() == fingerprint;
```

若 `ECPrivateKey` / `ECPublicKey` 未定义（`basic_utils` 未重新导出），执行 `dart pub add pointycastle` 并加 `import 'package:pointycastle/ecc/api.dart';`。

- [ ] **Step 5: 导出**

`sillydraft_core.dart` 末尾加入：

```dart
export 'src/remote/links.dart';
export 'src/remote/tls.dart';
```

- [ ] **Step 6: 运行测试**

Run: `dart test test/remote_links_test.dart && dart analyze`
Expected: PASS，无问题。

---

### Task 5: drift 报文编码与可重连执行器

**Files:**
- Create: `packages/sillydraft_core/lib/src/remote/wire.dart`
- Create: `packages/sillydraft_core/lib/src/remote/reconnecting_executor.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`
- Test: `packages/sillydraft_core/test/remote_wire_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `StoryRepository.connect`、`remoteServer`。
- Produces:
  - `Object? encodeDriftMessage(Object? message)` / `Object? decodeDriftMessage(Object? message)`。
  - `StreamChannel<Object?> driftChannel(WebSocket socket)`：drift 远程协议跑在 WebSocket 文本帧上。
  - `final class RemoteUnavailable implements Exception { const RemoteUnavailable([String reason]); String reason; }`，默认文案“与桌面断开，正在重连”。
  - `final class ReconnectingExecutor extends QueryExecutor`：`Future<void> attach(QueryExecutor executor)`、`void detach([String? reason])`。

- [ ] **Step 1: 写失败测试**

`packages/sillydraft_core/test/remote_wire_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:drift/remote.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('drift messages survive JSON, bytes included', () {
    final message = [
      1,
      'a',
      Uint8List.fromList([0, 255]),
      [true, null, 2.5, Uint8List(0)],
    ];
    final back = decodeDriftMessage(
      jsonDecode(jsonEncode(encodeDriftMessage(message))),
    );
    expect(back, message);
    expect((back! as List)[2], isA<Uint8List>());
  });

  test('a repository works over a WebSocket, with large rows', () async {
    final dir = await Directory.systemTemp.createTemp('sd-wire');
    final desktop = StoryRepository.open('${dir.path}/library.sqlite');
    addTearDown(() async {
      await desktop.close();
      await dir.delete(recursive: true);
    });
    final big = 'x' * (5 * 1024 * 1024);
    await desktop.setSetting('big', {'text': big});
    final server = desktop.remoteServer();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.shutdown();
      await http.close(force: true);
    });
    http.listen(
      (request) async =>
          server.serve(driftChannel(await WebSocketTransformer.upgrade(request))),
    );
    final socket = await WebSocket.connect('ws://127.0.0.1:${http.port}');
    final connection = await connectToRemoteAndInitialize(driftChannel(socket));
    final phone = StoryRepository.connect(connection.executor);
    expect((await phone.getSetting('big'))!['text'], big);
    await phone.setSetting('back', {'text': big});
    expect((await desktop.getSetting('back'))!['text'], big);
    final rows = await connection.executor.runSelect("SELECT x'00ff' AS b", []);
    expect(rows.single['b'], [0, 255]);
    await socket.close();
  });

  test('a detached executor fails with the reason, then serves again', () async {
    final executor = ReconnectingExecutor();
    final repository = StoryRepository.connect(executor);
    addTearDown(repository.close);
    await expectLater(
      repository.getSetting('x'),
      throwsA(isA<RemoteUnavailable>()),
    );
    await executor.attach(NativeDatabase.memory());
    await repository.setSetting('x', {'v': 1});
    executor.detach('桌面已停止共享');
    await expectLater(
      repository.getSetting('x'),
      throwsA(
        isA<RemoteUnavailable>().having((e) => '$e', 'message', '桌面已停止共享'),
      ),
    );
    // A new connection is opened for the same database user (migrations
    // run here because this stand-in database is empty).
    await executor.attach(NativeDatabase.memory());
    expect(await repository.getSetting('x'), isNull);
  });
}
```

Run: `dart test test/remote_wire_test.dart`
Expected: 编译失败，未定义。

- [ ] **Step 2: 实现报文编码**

`packages/sillydraft_core/lib/src/remote/wire.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';

/// drift's serialized messages hold only bool, int, double, String,
/// Uint8List and lists of them. JSON carries all but the bytes, which
/// travel as `{"b": base64}`; a map never occurs otherwise.
Object? encodeDriftMessage(Object? message) => switch (message) {
  final Uint8List bytes => {'b': base64Encode(bytes)},
  final List<Object?> list => [for (final v in list) encodeDriftMessage(v)],
  _ => message,
};

Object? decodeDriftMessage(Object? message) => switch (message) {
  {'b': final String data} => base64Decode(data),
  final List<Object?> list => [for (final v in list) decodeDriftMessage(v)],
  _ => message,
};

/// [socket] as the channel drift's remote protocol runs on.
StreamChannel<Object?> driftChannel(WebSocket socket) {
  final outgoing = StreamController<Object?>();
  unawaited(
    outgoing.stream
        .map((message) => jsonEncode(encodeDriftMessage(message)))
        .pipe(socket)
        .catchError((Object _) {}),
  );
  return StreamChannel(
    socket.map((frame) => decodeDriftMessage(jsonDecode(frame as String))),
    outgoing.sink,
  );
}
```

- [ ] **Step 3: 实现可重连执行器**

`packages/sillydraft_core/lib/src/remote/reconnecting_executor.dart`：

```dart
import 'package:drift/drift.dart';

/// Thrown while a remote library cannot be reached.
final class RemoteUnavailable implements Exception {
  const RemoteUnavailable([this.reason = '与桌面断开，正在重连']);
  final String reason;
  @override
  String toString() => reason;
}

/// A database executor whose remote connection can be replaced: a phone's
/// repository, and every screen built on it, outlives a dropped link.
final class ReconnectingExecutor extends QueryExecutor {
  QueryExecutor? _current;
  QueryExecutorUser? _user;
  String _reason = const RemoteUnavailable().reason;

  /// Uses [executor] from now on, opened for the database already using
  /// this one.
  Future<void> attach(QueryExecutor executor) async {
    if (_user case final user?) await executor.ensureOpen(user);
    _current = executor;
  }

  /// Fails every call with [reason] until the next [attach].
  void detach([String? reason]) {
    _current = null;
    _reason = reason ?? const RemoteUnavailable().reason;
  }

  QueryExecutor get _live => _current ?? (throw RemoteUnavailable(_reason));

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    _user = user;
    return _live.ensureOpen(user);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async => _live.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) async =>
      _live.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async =>
      _live.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) async =>
      _live.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async =>
      _live.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) async =>
      _live.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _live.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _live.beginExclusive();

  @override
  Future<void> close() async {
    final current = _current;
    _current = null;
    await current?.close();
  }
}
```

- [ ] **Step 4: 导出并运行**

`sillydraft_core.dart` 加入：

```dart
export 'src/remote/reconnecting_executor.dart';
export 'src/remote/wire.dart';
```

Run: `dart test test/remote_wire_test.dart && dart analyze`
Expected: PASS。若 `QueryExecutor` 在 2.35.2 还有其他抽象成员，`dart analyze` 会列出，按同样方式委托给 `_live`。

---

### Task 6: 桌面服务与手机会话（握手、鉴权、数据库、通知、重连）

**Files:**
- Create: `packages/sillydraft_core/lib/src/remote/remote_host.dart`
- Create: `packages/sillydraft_core/lib/src/remote/remote_session.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`
- Create: `packages/sillydraft_core/test/remote_support.dart`
- Test: `packages/sillydraft_core/test/remote_session_test.dart`

**Interfaces:**
- Consumes: Task 1、4、5。
- Produces:
  - `const defaultRemotePort = 8790;`、`const stoppedCloseCode = 4001;`
  - `final class LibraryAccess`：`accessKey`、`repository`、`TaskControl tasks`、`AssetLibrary assets`、`Future<List<int>> Function() resourceKey`、`Future<List<ModelConnection>> Function() connections`、`ProviderFactory providerFactory`、`ImageProviderFactory imageProviderFactory`。
  - `final class RemoteHost`：`static Future<RemoteHost> start({required TlsIdentity identity, required String name, required String appVersion, LibraryAccess? library, int port = defaultRemotePort, InternetAddress? address})`；`int get port`；`Future<void> close()`。后续任务在其私有 `_route` 中加分支。
  - `final class RemoteHello`：`name`、`appVersion`、`List<int> resourceKey`。
  - `final class RemoteVersionMismatch`（`toString` = `桌面 x，手机 y，请升级到同一版本`）、`final class RemoteRequestFailed`（`status`、`message`；`static Future<RemoteRequestFailed> of(HttpClientResponse)`）。
  - `typedef RemoteStatus = ({bool connected, String? problem});`
  - `final class RemoteSession`：`static Future<RemoteSession> connect(ConnectLink link, {required String appVersion, Duration firstRetry = const Duration(seconds: 1)})`；`link`、`hello`、`executor`、`repository`、`status`、`Stream<RemoteStatus> get statuses`（先给当前值）；`Future<HttpClientResponse> send(String method, String path, {Object? json, List<int>? bytes, GenerationCancellation? cancellation})`；`Future<Map<String, dynamic>> request(String method, String path, {Object? json, GenerationCancellation? cancellation})`；`Future<void> close()`。
  - 测试工具 `test/remote_support.dart`：`testIdentity`、`testVersion`、`ScriptProvider`、`Desktop`（`start`、`stopHost`、`startHost({String appVersion})`、`link`、`phone()`、`close`）。

- [ ] **Step 1: 测试工具**

`packages/sillydraft_core/test/remote_support.dart`：

```dart
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';

/// One identity for the whole run: a key pair per test is slow.
final testIdentity = TlsIdentity.generate();
const testVersion = '1.0.0+1';

final class ScriptProvider implements ModelProvider {
  ScriptProvider(this.config, this.script);
  @override
  final ModelConnection config;
  final Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => script(request, cancellation ?? GenerationCancellation());
  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

/// A desktop library served on loopback, as the app's host would serve it.
final class Desktop {
  Desktop._(
    this.directory,
    this.repository,
    this.assets,
    this.runner,
    this.key,
    this.connections,
    this.providers,
    this.images,
  );

  static Future<Desktop> start({
    ProviderFactory? providerFactory,
    ImageProviderFactory? imageProviderFactory,
    List<ModelConnection> connections = const [],
  }) async {
    final directory = await Directory.systemTemp.createTemp('sd-desktop');
    final repository = StoryRepository.open('${directory.path}/library.sqlite');
    await repository.listNovels();
    final assets = AssetLibrary(
      repository: repository,
      directory: Directory('${directory.path}/assets'),
    );
    final ProviderFactory providers =
        providerFactory ?? (_) async => throw StateError('no provider');
    final ImageProviderFactory images =
        imageProviderFactory ?? (_) async => throw StateError('no painter');
    final runner = TaskRunner(
      repository: repository,
      providerFactory: providers,
      imageProviderFactory: images,
      assetLibrary: assets,
    );
    final desktop = Desktop._(
      directory,
      repository,
      assets,
      runner,
      randomSecret(),
      connections,
      providers,
      images,
    );
    await desktop.startHost();
    return desktop;
  }

  final Directory directory;
  final StoryRepository repository;
  final AssetLibrary assets;
  final TaskRunner runner;
  final String key;
  final List<ModelConnection> connections;
  final ProviderFactory providers;
  final ImageProviderFactory images;
  RemoteHost? host;
  int _port = 0;

  Future<void> startHost({String appVersion = testVersion}) async {
    host = await RemoteHost.start(
      identity: testIdentity,
      name: '测试桌面',
      appVersion: appVersion,
      address: InternetAddress.loopbackIPv4,
      port: _port,
      library: LibraryAccess(
        accessKey: key,
        repository: repository,
        tasks: runner,
        assets: assets,
        resourceKey: () async => List.filled(32, 7),
        connections: () async => connections,
        providerFactory: providers,
        imageProviderFactory: images,
      ),
    );
    _port = host!.port;
  }

  Future<void> stopHost() async {
    await host?.close();
    host = null;
  }

  ConnectLink get link => ConnectLink(
    host: '127.0.0.1',
    port: _port,
    key: key,
    fingerprint: testIdentity.fingerprint,
    name: '测试桌面',
  );

  Future<RemoteSession> phone({String appVersion = testVersion}) =>
      RemoteSession.connect(
        link,
        appVersion: appVersion,
        firstRetry: const Duration(milliseconds: 50),
      );

  Future<void> close() async {
    await stopHost();
    await runner.close();
    await repository.close();
    await directory.delete(recursive: true);
  }
}
```

- [ ] **Step 2: 写失败测试**

`packages/sillydraft_core/test/remote_session_test.dart`：

```dart
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

final class _User implements QueryExecutorUser {
  @override
  int get schemaVersion => 9;
  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) async {}
}

const _wait = Duration(seconds: 5);

void main() {
  late Desktop desktop;
  setUp(() async => desktop = await Desktop.start());
  tearDown(() => desktop.close());

  test('a phone reads the desktop library; both hear each other', () async {
    await desktop.repository.setSetting('from-desktop', {'v': 1});
    final phone = await desktop.phone();
    addTearDown(phone.close);
    expect(phone.hello.name, '测试桌面');
    expect(phone.hello.resourceKey, List.filled(32, 7));
    expect(await phone.repository.getSetting('from-desktop'), {'v': 1});

    final heardOnPhone = phone.repository.contentChanges.first;
    await desktop.repository.setSetting('later', {'v': 2});
    await heardOnPhone.timeout(_wait);

    final heardOnDesktop = desktop.repository.contentChanges.first;
    await phone.repository.setSetting('from-phone', {'v': 3});
    await heardOnDesktop.timeout(_wait);
    expect(await desktop.repository.getSetting('from-phone'), {'v': 3});
  });

  test('a second phone hears the first one\'s writes', () async {
    final first = await desktop.phone(), second = await desktop.phone();
    addTearDown(first.close);
    addTearDown(second.close);
    final heard = second.repository.contentChanges.first;
    await first.repository.setSetting('shared', {'v': 1});
    await heard.timeout(_wait);
  });

  test('a wrong key is refused; ten guesses lock the address out', () async {
    final wrong = ConnectLink(
      host: '127.0.0.1',
      port: desktop.host!.port,
      key: randomSecret(),
      fingerprint: testIdentity.fingerprint,
      name: 'x',
    );
    for (var i = 0; i < 10; i++) {
      await expectLater(
        RemoteSession.connect(wrong, appVersion: testVersion),
        throwsA(isA<RemoteRequestFailed>().having((e) => e.status, 'status', 401)),
      );
    }
    await expectLater(
      desktop.phone(),
      throwsA(isA<RemoteRequestFailed>().having((e) => e.status, 'status', 429)),
    );
  });

  test('a certificate other than the link\'s is refused', () async {
    final link = desktop.link;
    final forged = ConnectLink(
      host: link.host,
      port: link.port,
      key: link.key,
      fingerprint: 'a' * 64,
      name: link.name,
    );
    await expectLater(
      RemoteSession.connect(forged, appVersion: testVersion),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('different versions refuse to connect and say which', () async {
    await expectLater(
      desktop.phone(appVersion: '1.0.0+2'),
      throwsA(
        isA<RemoteVersionMismatch>().having(
          (e) => '$e',
          'message',
          '桌面 1.0.0+1，手机 1.0.0+2，请升级到同一版本',
        ),
      ),
    );
  });

  test('a dropped link is retried under the same repository', () async {
    final phone = await desktop.phone();
    addTearDown(phone.close);
    final repository = phone.repository;
    final lost = phone.statuses.firstWhere((s) => !s.connected);
    await desktop.stopHost();
    expect((await lost.timeout(_wait)).problem, '桌面已停止共享');
    await expectLater(
      repository.getSetting('x'),
      throwsA(isA<RemoteUnavailable>()),
    );
    await desktop.repository.setSetting('while-away', {'v': 1});
    final refreshed = repository.contentChanges.first;
    await desktop.startHost();
    await phone.statuses.firstWhere((s) => s.connected).timeout(_wait);
    await refreshed.timeout(_wait);
    expect(identical(phone.repository, repository), isTrue);
    expect(await repository.getSetting('while-away'), {'v': 1});
  });

  test('a desktop upgraded mid-session stops the retries and says why', () async {
    final phone = await desktop.phone();
    addTearDown(phone.close);
    await desktop.stopHost();
    await desktop.startHost(appVersion: '1.0.1+2');
    final status = await phone.statuses
        .firstWhere((s) => s.problem?.contains('1.0.1+2') ?? false)
        .timeout(_wait);
    expect(status.connected, isFalse);
    expect(status.problem, contains(testVersion));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(phone.status.connected, isFalse);
  });

  test('a phone gone mid-transaction leaves the desktop writable', () async {
    final phone = await desktop.phone();
    await phone.repository.getSetting('open');
    final tx = phone.executor.beginTransaction();
    await tx.ensureOpen(_User());
    await tx.runSelect('SELECT 1', []);
    await phone.close();
    await desktop.repository.setSetting('after', {'ok': true}).timeout(_wait);
  });
}
```

Run: `dart test test/remote_session_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现桌面服务**

`packages/sillydraft_core/lib/src/remote/remote_host.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/remote.dart';

import '../assets/asset_library.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';
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

  bool _locked(String ip) =>
      _lockedUntil[ip]?.isAfter(DateTime.now()) ?? false;

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
      default:
        throw const _ApiError(404, '接口不存在');
    }
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
```

- [ ] **Step 4: 实现手机会话**

`packages/sillydraft_core/lib/src/remote/remote_session.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      if (error is String) return RemoteRequestFailed(response.statusCode, error);
    } on FormatException {
      // Not one of the host's answers.
    }
    return RemoteRequestFailed(response.statusCode, 'HTTP ${response.statusCode}');
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
      final session = RemoteSession._(link, appVersion, hello, client, firstRetry);
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
    if (response.statusCode != 200) throw await RemoteRequestFailed.of(response);
    return jsonDecode(await utf8.decodeStream(response)) as Map<String, dynamic>;
  }

  Future<void> _open() async {
    final db = await _socket('/v1/db');
    WebSocket? events;
    try {
      events = await _socket('/v1/events');
      final connection = await connectToRemoteAndInitialize(driftChannel(db));
      await executor.attach(connection.executor);
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
        await _open();
        // Whatever the desktop wrote meanwhile never reached this device.
        repository.notifyExternal(false);
        return;
      } on RemoteVersionMismatch catch (e) {
        // Retrying cannot help until one side is updated.
        executor.detach('$e');
        _setStatus((connected: false, problem: '$e'));
        return;
      } catch (_) {
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
```

- [ ] **Step 5: 导出并运行**

`sillydraft_core.dart` 加入：

```dart
export 'src/remote/remote_host.dart';
export 'src/remote/remote_session.dart';
```

Run: `dart test test/remote_session_test.dart && dart analyze`
Expected: PASS（8 个用例）。若 `ReconnectingExecutor` 在 `repository.close()` 时因 `_current` 为空而被 drift 调用 `ensureOpen`，以 `RemoteUnavailable` 结束：在 `RemoteSession.close` 里把 `await repository.close();` 包在 `try { … } on RemoteUnavailable catch (_) {}` 中。

---

### Task 7: 手机发起、桌面执行的任务

**Files:**
- Modify: `packages/sillydraft_core/lib/src/remote/remote_host.dart`
- Create: `packages/sillydraft_core/lib/src/remote/remote_tasks.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`
- Test: `packages/sillydraft_core/test/remote_tasks_test.dart`

**Interfaces:**
- Consumes: Task 2 `TaskControl`；Task 6 `RemoteSession.request`、`LibraryAccess.connections`。
- Produces:
  - 桌面接口 `POST /v1/tasks/start`（返回 `{id}`）、`POST /v1/tasks/<id>/cancel|resume|reconnect|confirm`。
  - 桌面私有 `_checkEndpoints(Object? value)`：遍历 JSON，凡形如连接（有字符串 `id`、`protocol` 与键 `baseUrl`）的对象，必须与桌面保存的同 ID 连接在 `protocol`、`baseUrl`、`command`、`allowInsecureHttp` 上一致，否则 403。Task 8 复用。
  - `final class RemoteTaskControl implements TaskControl`：`RemoteTaskControl(RemoteSession session, {required ProviderFactory providerFactory, ImageProviderFactory? imageProviderFactory, AssetLibrary? assetLibrary})`。

- [ ] **Step 1: 写失败测试**

`packages/sillydraft_core/test/remote_tasks_test.dart`：

```dart
import 'dart:async';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

const _wait = Duration(seconds: 10);

void main() {
  final connection = ModelConnection(
    id: 'local',
    name: 'Test',
    baseUrl: 'http://localhost:1234/v1',
    model: 'fiction-model',
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
      connections: [connection],
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
      providerFactory: (_) async => throw StateError('the phone calls no model'),
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

  test('a phone\'s task runs on the desktop', () async {
    final task = await generate();
    expect((await tasks.wait(task.id).timeout(_wait)).status, TaskStatus.completed);
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
    expect((await tasks.wait(task.id).timeout(_wait)).status, TaskStatus.cancelled);
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
      throwsA(isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403)),
    );
    expect(calls, 0);
    expect(await desktop.repository.listTasks(), isEmpty);
  });

  test('an unknown image confirmation is declined', () async {
    expect(
      await tasks.respondToImageConfirmation('missing', 'x', approved: true),
      isFalse,
    );
  });
}
```

Run: `dart test test/remote_tasks_test.dart`
Expected: 编译失败，`RemoteTaskControl` 未定义。

- [ ] **Step 2: 桌面任务接口**

`remote_host.dart` 顶部 import 增加 `import 'dart:typed_data';`、`import '../model/task.dart';` 与 `import '../st/import_types.dart';`（`jsonObject` 所在）。类中加入请求体的读取：

```dart
  static const _maxBody = 64 * 1024 * 1024;

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
```

`_route` 的 `switch` 中 `default:` 之前加入：

```dart
      case ('POST', '/v1/tasks/start'):
        await _json(request.response, 200, await _startTask(await _body(request)));
      case ('POST', _) when path.startsWith('/v1/tasks/'):
        await _json(
          request.response,
          200,
          await _taskAction(request.uri.pathSegments, await _body(request)),
        );
```

类中加入：

```dart
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
    switch (parts[3]) {
      case 'cancel':
        await tasks.cancel(id);
        return {};
      case 'resume':
        return {'id': (await tasks.resume(id)).id};
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
  Future<void> _checkEndpoints(Object? value) async {
    final saved = {for (final c in await library!.connections()) c.id: c};
    void visit(Object? node) {
      if (node is Map) {
        if (node['id'] is String &&
            node['protocol'] is String &&
            node.containsKey('baseUrl')) {
          final mine = saved[node['id']];
          if (mine == null ||
              const [
                'protocol',
                'baseUrl',
                'command',
                'allowInsecureHttp',
              ].any((key) => mine.raw[key] != node[key])) {
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
```

- [ ] **Step 3: 手机端任务控制**

`packages/sillydraft_core/lib/src/remote/remote_tasks.dart`：

```dart
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

  /// Re-reads the task on every change: the desktop's progress arrives as
  /// write notifications, and a reconnect sends one too.
  @override
  Future<GenerationTask> wait(String id) async {
    final done = Completer<GenerationTask>();
    Future<void> check() async {
      try {
        final task = await _repository.getTask(id);
        if (!task.isActive && !done.isCompleted) done.complete(task);
      } on RemoteUnavailable {
        // Checked again once the link is back.
      } catch (e, s) {
        if (!done.isCompleted) done.completeError(e, s);
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
  Future<GenerationTask> reconnectRemote(String id) async => _repository.getTask(
    (await session.request('POST', '/v1/tasks/$id/reconnect', json: const {}))['id']
        as String,
  );

  @override
  Future<GenerationTask> resume(String id) async => _repository.getTask(
    (await session.request('POST', '/v1/tasks/$id/resume', json: const {}))['id']
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
```

- [ ] **Step 4: 导出并运行**

`sillydraft_core.dart` 加入 `export 'src/remote/remote_tasks.dart';`

Run: `dart test test/remote_tasks_test.dart && dart analyze`
Expected: PASS（5 个用例）。

---

### Task 8: 模型代理、生图、ComfyUI 工作流与文件接口

**Files:**
- Modify: `packages/sillydraft_core/lib/src/providers/image_provider.dart`
- Modify: `packages/sillydraft_core/lib/src/providers/comfyui.dart:13,52`
- Modify: `packages/sillydraft_core/lib/src/agent/illustration_service.dart:61-75`
- Modify: `packages/sillydraft_core/lib/src/remote/remote_host.dart`
- Create: `packages/sillydraft_core/lib/src/remote/remote_providers.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`
- Test: `packages/sillydraft_core/test/remote_providers_test.dart`

**Interfaces:**
- Consumes: Task 3 `AssetMirror`；Task 6 `RemoteSession.send/request`；Task 7 `_checkEndpoints`。
- Produces:
  - `abstract interface class WorkflowSource { Future<Map<String, dynamic>> readWorkflow(String filename); }`；`ComfyUIProvider implements ImageProvider, WorkflowSource`。
  - 桌面接口 `POST /v1/provider/text`（逐行 JSON：`{"e":"text"|"reasoning"|"tool"|"finish"|"error",…}`，每 2 秒一个空行心跳）、`POST /v1/provider/image`（同格式，结果行 `{"e":"image","image":base64,"revisedPrompt","usage"}`）、`POST /v1/provider/workflow`（`{nodes}`）、`GET|PUT /v1/assets/<hash>.<png|jpg>`。
  - `Map<String, Object?> encodeProviderEvent(ProviderEvent)`、`ProviderEvent decodeProviderEvent(Map<String, dynamic>)`。
  - `final class DesktopModelProvider implements ModelProvider`、`final class DesktopImageProvider implements ImageProvider, WorkflowSource`（构造 `(RemoteSession session, ModelConnection config)`）、`final class HttpAssetMirror implements AssetMirror`（构造 `(RemoteSession session)`）。

- [ ] **Step 1: 写失败测试**

`packages/sillydraft_core/test/remote_providers_test.dart`：

```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

final class _Painter implements ImageProvider, WorkflowSource {
  _Painter(this.config, this.references);
  @override
  final ModelConnection config;
  final List<ImageReference> references;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    this.references.addAll(references);
    return GeneratedImage(
      bytes: Uint8List.fromList([1, 2, 3]),
      revisedPrompt: '改写：${request.prompt}',
    );
  }

  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) async => {
    '9': {'class_type': 'SaveImage', 'file': filename},
  };
  @override
  void close() {}
}

void main() {
  final writer = ModelConnection(
    id: 'writer',
    name: '写手',
    baseUrl: 'http://localhost:1234/v1',
    model: 'm',
  );
  final painter = ModelConnection(
    id: 'painter',
    name: '画师',
    baseUrl: 'http://localhost:8188',
    model: 'workflow',
    kind: ModelKind.image,
  );
  final references = <ImageReference>[];
  final desktopCancelled = Completer<void>();
  late Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  late Desktop desktop;
  late RemoteSession phone;
  setUp(() async {
    references.clear();
    script = (_, _) async* {
      yield const ReasoningDelta('想');
      yield const TextDelta('甲');
      yield ToolCallReady('1', 'look', {'q': 1});
      yield const GenerationFinished('stop', usage: {'total': 3});
    };
    desktop = await Desktop.start(
      connections: [writer, painter],
      providerFactory: (c) async => ScriptProvider(c, (r, k) => script(r, k)),
      imageProviderFactory: (c) async => _Painter(c, references),
    );
    phone = await desktop.phone();
  });
  tearDown(() async {
    await phone.close();
    await desktop.close();
  });

  test('text calls stream from the desktop\'s provider', () async {
    final events = await DesktopModelProvider(
      phone,
      writer,
    ).generate(ProviderRequest(messages: [{'role': 'user', 'content': '你好'}])).toList();
    expect(events[0], isA<ReasoningDelta>().having((e) => e.text, 'text', '想'));
    expect(events[1], isA<TextDelta>().having((e) => e.text, 'text', '甲'));
    expect(events[2], isA<ToolCallReady>().having((e) => e.arguments, 'args', {'q': 1}));
    expect(
      events[3],
      isA<GenerationFinished>().having((e) => e.usage, 'usage', {'total': 3}),
    );
  });

  test('cancelling on the phone cancels the desktop call', () async {
    script = (_, cancel) async* {
      yield const TextDelta('甲');
      final stop = Completer<void>();
      cancel.onCancel(() {
        if (!desktopCancelled.isCompleted) desktopCancelled.complete();
        stop.complete();
      });
      await stop.future;
      throw const GenerationCancelled();
    };
    final cancel = GenerationCancellation();
    Object? error;
    try {
      await for (final _ in DesktopModelProvider(phone, writer).generate(
        ProviderRequest(messages: [{'role': 'user', 'content': '你好'}]),
        cancellation: cancel,
      )) {
        cancel.cancel();
      }
    } catch (e) {
      error = e;
    }
    expect(error, isA<GenerationCancelled>());
    await desktopCancelled.future.timeout(const Duration(seconds: 10));
  });

  test('a connection the desktop did not save is refused', () async {
    final stranger = ModelConnection(
      id: 'stranger',
      name: 'x',
      baseUrl: 'https://elsewhere.example/v1',
      model: 'm',
    );
    await expectLater(
      DesktopModelProvider(phone, stranger).generate(ProviderRequest()).toList(),
      throwsA(isA<RemoteRequestFailed>().having((e) => e.status, 'status', 403)),
    );
  });

  test('images and workflows come from the desktop', () async {
    final provider = DesktopImageProvider(phone, painter);
    final image = await provider.generate(
      ImageRequest(prompt: '雨夜'),
      references: [
        ImageReference(bytes: Uint8List.fromList([9]), mimeType: 'image/png'),
      ],
    );
    expect(image.bytes, [1, 2, 3]);
    expect(image.revisedPrompt, '改写：雨夜');
    expect(references.single.bytes, [9]);
    expect((await provider.readWorkflow('a.json'))['9'], {
      'class_type': 'SaveImage',
      'file': 'a.json',
    });
  });

  test('files move between phone and desktop by hash', () async {
    final cache = Directory('${desktop.directory.path}/phone-cache');
    final mine = AssetLibrary(
      repository: phone.repository,
      directory: cache,
      mirror: HttpAssetMirror(phone),
    );
    final sent = await mine.prepare(
      Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
    );
    expect(await desktop.assets.readHash(sent.hash), isNotEmpty);
    final theirs = await desktop.assets.prepare(
      Uint8List.fromList(img.encodePng(img.Image(width: 9, height: 9))),
    );
    expect(
      await mine.readHash(theirs.hash),
      await desktop.assets.readHash(theirs.hash),
    );
    await expectLater(
      HttpAssetMirror(phone).upload('notahash.png', Uint8List(4)),
      throwsA(isA<RemoteRequestFailed>().having((e) => e.status, 'status', 400)),
    );
  });
}
```

Run: `dart test test/remote_providers_test.dart`
Expected: 编译失败。

- [ ] **Step 2: `WorkflowSource`**

`image_provider.dart` 末尾加入：

```dart
/// A provider that reads workflows saved on its server, as ComfyUI does.
abstract interface class WorkflowSource {
  Future<Map<String, dynamic>> readWorkflow(String filename);
}
```

`comfyui.dart:13` 改为 `final class ComfyUIProvider implements ImageProvider, WorkflowSource {`，`readWorkflow` 上加 `@override`。

`illustration_service.dart` 中：

```dart
      if (provider is! ComfyUIProvider) {
        throw const ProviderException('comfy_workflow', '此执行器无法读取 ComfyUI 工作流');
      }
```

改为：

```dart
      if (provider is! WorkflowSource) {
        throw const ProviderException('comfy_workflow', '此执行器无法读取 ComfyUI 工作流');
      }
      final source = provider as WorkflowSource;
```

同一方法里 `await provider.readWorkflow(workflow.filename)` 改为 `await source.readWorkflow(workflow.filename)`。

Run: `dart test test/comfy_workflow_refresh_test.dart`
Expected: PASS。

- [ ] **Step 3: 事件编码与手机端代理**

`packages/sillydraft_core/lib/src/remote/remote_providers.dart`：

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../assets/asset_library.dart';
import '../providers/image_provider.dart';
import '../providers/provider.dart';
import '../st/import_types.dart';
import 'remote_session.dart';

Map<String, Object?> encodeProviderEvent(ProviderEvent event) => switch (event) {
  TextDelta(:final text) => {'e': 'text', 't': text},
  ReasoningDelta(:final text) => {'e': 'reasoning', 't': text},
  ToolCallReady() => {
    'e': 'tool',
    'id': event.id,
    'name': event.name,
    'arguments': event.arguments,
  },
  GenerationFinished() => {
    'e': 'finish',
    'reason': event.reason,
    'usage': event.usage,
  },
};

ProviderEvent decodeProviderEvent(Map<String, dynamic> json) =>
    switch (json['e']) {
      'text' => TextDelta(json['t'] as String),
      'reasoning' => ReasoningDelta(json['t'] as String),
      'tool' => ToolCallReady(
        json['id'] as String,
        json['name'] as String,
        jsonObject(json['arguments'], 'arguments'),
      ),
      'finish' => GenerationFinished(
        json['reason'] as String,
        usage: (json['usage'] as Map? ?? {}).cast<String, dynamic>(),
      ),
      _ => throw const FormatException('未知的模型事件'),
    };

/// The desktop's JSON lines for [path], heartbeats skipped and errors
/// raised as the provider raised them there.
Stream<Map<String, dynamic>> _desktopLines(
  RemoteSession session,
  String path,
  Object body,
  GenerationCancellation? cancellation,
) async* {
  cancellation?.check();
  final response = await session.send(
    'POST',
    path,
    json: body,
    cancellation: cancellation,
  );
  if (response.statusCode != 200) throw await RemoteRequestFailed.of(response);
  await for (final line in response
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    if (line.isEmpty) continue;
    final json = jsonDecode(line) as Map<String, dynamic>;
    if (json['e'] == 'error') {
      throw ProviderException(
        json['code'] as String,
        json['message'] as String,
        statusCode: json['status'] as int?,
      );
    }
    yield json;
  }
}

/// [config]'s text calls, run by the desktop that keeps its key.
final class DesktopModelProvider implements ModelProvider {
  DesktopModelProvider(this.session, this.config);
  final RemoteSession session;
  @override
  final ModelConnection config;

  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => _desktopLines(session, '/v1/provider/text', {
    'connection': config.raw,
    'request': request.raw,
  }, cancellation).map(decodeProviderEvent);

  @override
  Future<List<String>> listModels() async => config.models;

  /// The desktop's own provider validates when it runs the request.
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      const [];

  @override
  void close() {}
}

/// [config]'s images and ComfyUI workflows, from the desktop.
final class DesktopImageProvider implements ImageProvider, WorkflowSource {
  DesktopImageProvider(this.session, this.config);
  final RemoteSession session;
  @override
  final ModelConnection config;

  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final line = await _desktopLines(session, '/v1/provider/image', {
      'connection': config.raw,
      'request': request.raw,
      'references': [
        for (final r in references)
          {'mimeType': r.mimeType, 'data': base64Encode(r.bytes)},
      ],
    }, cancellation).firstWhere((line) => line['e'] == 'image');
    return GeneratedImage(
      bytes: base64Decode(line['image'] as String),
      revisedPrompt: line['revisedPrompt'] as String? ?? '',
      usage: (line['usage'] as Map? ?? {}).cast<String, dynamic>(),
    );
  }

  @override
  Future<Map<String, dynamic>> readWorkflow(String filename) async =>
      jsonObject(
        (await session.request(
          'POST',
          '/v1/provider/workflow',
          json: {'connection': config.raw, 'filename': filename},
        ))['nodes'],
        'nodes',
      );

  @override
  void close() {}
}

/// A remote library's files, by content hash, on the desktop.
final class HttpAssetMirror implements AssetMirror {
  HttpAssetMirror(this.session);
  final RemoteSession session;

  @override
  Future<Uint8List> download(String name) async {
    final response = await session.send('GET', '/v1/assets/$name');
    if (response.statusCode != 200) throw await RemoteRequestFailed.of(response);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > AssetLibrary.maxBytes) {
        throw const FormatException('图片文件大小异常');
      }
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> upload(String name, Uint8List bytes) async {
    final response = await session.send('PUT', '/v1/assets/$name', bytes: bytes);
    if (response.statusCode != 200) throw await RemoteRequestFailed.of(response);
    await response.drain<void>();
  }
}
```

（`import 'dart:io';` 只为 `BytesBuilder`；若分析器提示 `dart:typed_data` 已提供 `BytesBuilder`，删去 `dart:io`。）

- [ ] **Step 4: 桌面代理与文件接口**

`remote_host.dart` 顶部 import 增加 `import '../providers/image_provider.dart';` 与 `import 'remote_providers.dart';`（为 `encodeProviderEvent`）。`_route` 的 `default:` 之前加入：

```dart
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
```

类中加入：

```dart
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
    } finally {
      heartbeat.cancel();
      finished = true;
      try {
        await response.close();
      } catch (_) {}
    }
  }
```

（`_checkEndpoints` 期望的是含连接的 JSON；`connection.raw` 本身就是一个连接对象，访问时会被检查。）

- [ ] **Step 5: 导出并运行**

`sillydraft_core.dart` 加入 `export 'src/remote/remote_providers.dart';`

Run: `dart test test/remote_providers_test.dart && dart test && dart analyze`
Expected: 全部通过。

---

### Task 9: 分享会话与各类内容

**Files:**
- Create: `packages/sillydraft_core/lib/src/remote/share.dart`
- Modify: `packages/sillydraft_core/lib/src/remote/remote_host.dart`
- Modify: `packages/sillydraft_core/lib/sillydraft_core.dart`
- Test: `packages/sillydraft_core/test/share_test.dart`

**Interfaces:**
- Consumes: Task 4 `ReceiveLink`、`randomSecret`、`pinnedClient`；Task 6 `RemoteHost`。
- Produces:
  - `enum ShareKind { resource, skill, persona, connection }`；`final class SharePayload`（`kind`、`name`、`data`；`static const format = 1`；`fromJson`/`toJson`，未知版本或类型抛 `FormatException`）。
  - `final class ShareRegistry`：`ShareTicket open(SharePayload payload, {Duration lifetime})`、`SharePayload? take(String token)`、`bool get isEmpty`。`final class ShareTicket`：`token`、`Future<void> received`、`void close()`。
  - `RemoteHost.shares`（`ShareRegistry`），接口 `GET /v1/share/<token>` 不需访问密钥，失效令牌计入失败次数。
  - `Future<SharePayload> fetchShare(ReceiveLink link)`。
  - `Future<SharePayload> resourceShare(ResourceLibrary library, String resourceId)`、`Future<LibraryResource> receiveResource(ResourceLibrary library, SharePayload payload)`；`SharePayload skillShare(AgentSkill)`、`AgentSkill receivedSkill(SharePayload)`；`Future<SharePayload> personaShare(Persona, AssetLibrary)`、`Future<Persona> receivePersona(StoryRepository, AssetLibrary, SharePayload)`；`SharePayload connectionShare(ModelConnection, String apiKey)`、`({ModelConnection connection, String apiKey}) receivedConnection(SharePayload, Set<String> takenIds)`。

- [ ] **Step 1: 写失败测试**

`packages/sillydraft_core/test/share_test.dart`：

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

void main() {
  final payload = SharePayload(
    kind: ShareKind.skill,
    name: '技能',
    data: {'name': 'x'},
  );

  test('a ticket is taken once, and not after expiry or close', () async {
    final registry = ShareRegistry();
    final once = registry.open(payload);
    expect(registry.take(once.token)?.name, '技能');
    await once.received;
    expect(registry.take(once.token), isNull);
    final expired = registry.open(payload, lifetime: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(registry.take(expired.token), isNull);
    final closed = registry.open(payload)..close();
    expect(registry.take(closed.token), isNull);
    expect(registry.isEmpty, isTrue);
  });

  test('a share-only host hands a payload to a pinned fetch, once', () async {
    final host = await RemoteHost.start(
      identity: testIdentity,
      name: '手机',
      appVersion: testVersion,
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
    addTearDown(host.close);
    final ticket = host.shares.open(payload);
    final link = ReceiveLink(
      host: '127.0.0.1',
      port: host.port,
      token: ticket.token,
      fingerprint: testIdentity.fingerprint,
    );
    expect((await fetchShare(link)).data, {'name': 'x'});
    await expectLater(
      fetchShare(link),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', contains('已失效')),
      ),
    );
  });

  test('an unknown format version is refused', () {
    expect(
      () => SharePayload.fromJson({...payload.toJson(), 'format': 2}),
      throwsFormatException,
    );
  });

  group('content', () {
    late StoryRepository repository;
    late ResourceLibrary resources;
    late Directory dir;
    late AssetLibrary assets;
    setUp(() async {
      repository = StoryRepository.memory();
      resources = ResourceLibrary(
        repository: repository,
        keyProvider: () async => List.filled(32, 1),
      );
      dir = await Directory.systemTemp.createTemp('sd-share');
      assets = AssetLibrary(repository: repository, directory: dir);
    });
    tearDown(() async {
      await repository.close();
      await dir.delete(recursive: true);
    });

    test('a resource arrives with the versions it was edited from', () async {
      final card = await resources.import(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'spec': 'chara_card_v2',
              'data': {'name': '苏雾', 'description': '灯塔守护人'},
            }),
          ),
        ),
        filename: '苏雾.json',
        kind: ResourceKind.character,
      );
      final edited = await resources.edit(card.id, {...card.data});
      final shared = await resourceShare(resources, edited.id);

      final other = StoryRepository.memory();
      addTearDown(other.close);
      final theirs = ResourceLibrary(
        repository: other,
        keyProvider: () async => List.filled(32, 2),
      );
      final received = await receiveResource(
        theirs,
        SharePayload.fromJson(
          jsonDecode(jsonEncode(shared.toJson())) as Map<String, dynamic>,
        ),
      );
      expect(received.parentId, isNotNull);
      expect(received.data, edited.data);
      expect(
        await theirs.original(received.parentId!),
        await resources.original(card.id),
      );
    });

    test('a persona arrives with its pictures', () async {
      final prepared = await assets.prepare(
        Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
      );
      final persona = await repository.savePersona(
        Persona(
          id: '',
          name: '林岚',
          appearance: '短发',
          images: [PersonaImage.of(prepared)],
        ),
      );
      final shared = await personaShare(persona, assets);
      final received = await receivePersona(repository, assets, shared);
      expect(received.id, isNot(persona.id));
      expect(received.name, '林岚');
      expect(received.appearance, '短发');
      expect(received.images.single.hash, prepared.hash);
    });

    test('a skill and a connection with its key round-trip', () {
      final skill = AgentSkill(name: 'tone', description: '语气', body: '写得轻一点');
      expect(receivedSkill(skillShare(skill)).body, '写得轻一点');

      final connection = ModelConnection(
        id: 'writer',
        name: '写手',
        baseUrl: 'https://api.example/v1',
        model: 'm',
      );
      final shared = connectionShare(connection, 'sk-123');
      final fresh = receivedConnection(shared, {});
      expect(fresh.connection.id, 'writer');
      expect(fresh.apiKey, 'sk-123');
      final renamed = receivedConnection(shared, {'writer'});
      expect(renamed.connection.id, isNot('writer'));
      expect(renamed.connection.baseUrl, 'https://api.example/v1');
    });
  });
}
```

Run: `dart test test/share_test.dart`
Expected: 编译失败。

- [ ] **Step 2: 实现分享**

`packages/sillydraft_core/lib/src/remote/share.dart`：

```dart
import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../agent/skills.dart';
import '../assets/asset_library.dart';
import '../model/persona.dart';
import '../model/resource.dart';
import '../providers/provider.dart';
import '../st/import_types.dart';
import '../st/resource_library.dart';
import '../storage/story_repository.dart';
import 'links.dart';
import 'tls.dart';

enum ShareKind { resource, skill, persona, connection }

/// One item handed from one device to another: what a share link fetches.
final class SharePayload {
  SharePayload({required this.kind, required this.name, required this.data});

  static const format = 1;

  factory SharePayload.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const FormatException('分享内容来自不兼容的版本，请把两台设备升级到同一版本');
    }
    final kind =
        ShareKind.values.asNameMap()[json['kind']] ??
        (throw const FormatException('不认识的分享类型，请把两台设备升级到同一版本'));
    return SharePayload(
      kind: kind,
      name: json['name'] as String,
      data: jsonObject(json['data'], 'data'),
    );
  }

  final ShareKind kind;
  final String name;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
    'format': format,
    'kind': kind.name,
    'name': name,
    'data': data,
  };
}

/// The shares a host hands out: each token fetches its payload once, within
/// its lifetime, until its page closes it.
final class ShareRegistry {
  final _open =
      <
        String,
        ({SharePayload payload, DateTime expires, Completer<void> received})
      >{};

  ShareTicket open(
    SharePayload payload, {
    Duration lifetime = const Duration(minutes: 10),
  }) {
    final token = randomSecret(), received = Completer<void>();
    _open[token] = (
      payload: payload,
      expires: DateTime.now().add(lifetime),
      received: received,
    );
    return ShareTicket._(this, token, received.future);
  }

  /// The payload for [token], used up by this call; null when unknown,
  /// expired or taken.
  SharePayload? take(String token) {
    final entry = _open.remove(token);
    if (entry == null || !entry.expires.isAfter(DateTime.now())) return null;
    entry.received.complete();
    return entry.payload;
  }

  bool get isEmpty {
    _open.removeWhere((_, e) => !e.expires.isAfter(DateTime.now()));
    return _open.isEmpty;
  }
}

final class ShareTicket {
  ShareTicket._(this._registry, this.token, this.received);
  final ShareRegistry _registry;
  final String token;

  /// Completes once a device has fetched the payload.
  final Future<void> received;

  void close() => _registry._open.remove(token);
}

/// The payload [link] points to, fetched over its pinned certificate.
Future<SharePayload> fetchShare(ReceiveLink link) async {
  final client = pinnedClient(link.fingerprint);
  try {
    final request = await client.getUrl(link.endpoint)..followRedirects = false;
    final response = await request.close();
    final json = jsonDecode(await utf8.decodeStream(response));
    if (response.statusCode != 200 || json is! Map<String, dynamic>) {
      throw FormatException(
        (json is Map ? json['error'] as String? : null) ?? '分享读取失败',
      );
    }
    return SharePayload.fromJson(json);
  } finally {
    client.close(force: true);
  }
}

/// [resourceId] with every version it was edited from, oldest first, so the
/// receiver rebuilds the chain and keeps the card's attachments.
Future<SharePayload> resourceShare(
  ResourceLibrary library,
  String resourceId,
) async {
  final chain = <LibraryResource>[];
  for (String? id = resourceId; id != null;) {
    final resource = await library.repository.getResource(id);
    chain.insert(0, resource);
    id = resource.parentId;
  }
  return SharePayload(
    kind: ShareKind.resource,
    name: chain.last.name,
    data: {
      'kind': chain.last.kind.name,
      'versions': [
        for (final r in chain)
          {
            'filename': r.filename,
            'bytes': base64Encode(await library.original(r.id)),
          },
      ],
    },
  );
}

Future<LibraryResource> receiveResource(
  ResourceLibrary library,
  SharePayload payload,
) async {
  final kind = ResourceKind.values.byName(payload.data['kind'] as String);
  LibraryResource? last;
  for (final version in (payload.data['versions'] as List)
      .cast<Map<String, dynamic>>()) {
    final bytes = base64Decode(version['bytes'] as String);
    final filename = version['filename'] as String;
    // ponytail: receiving the same edited share twice adds its edits twice;
    // only the original file is deduplicated.
    last = last == null
        ? await library.importOnce(bytes, filename: filename, kind: kind)
        : await library.import(
            bytes,
            filename: filename,
            kind: kind,
            parentId: last.id,
          );
  }
  return last ?? (throw const FormatException('分享内容为空'));
}

SharePayload skillShare(AgentSkill skill) =>
    SharePayload(kind: ShareKind.skill, name: skill.title, data: skill.raw);

/// The shared skill as the receiver's own, never a built-in.
AgentSkill receivedSkill(SharePayload payload) =>
    AgentSkill.fromJson({...payload.data, 'builtIn': false});

Future<SharePayload> personaShare(Persona persona, AssetLibrary assets) async =>
    SharePayload(
      kind: ShareKind.persona,
      name: persona.name,
      data: {
        ...persona.snapshot,
        'images': [
          for (final image in persona.images)
            base64Encode(await assets.readHash(image.hash)),
        ],
      },
    );

Future<Persona> receivePersona(
  StoryRepository repository,
  AssetLibrary assets,
  SharePayload payload,
) async {
  final data = payload.data;
  return repository.savePersona(
    Persona(
      id: '',
      name: data['name'] as String,
      description: data['description'] as String? ?? '',
      appearance: data['appearance'] as String? ?? '',
      outfit: data['outfit'] as String? ?? '',
      images: [
        for (final image in (data['images'] as List? ?? []).cast<String>())
          PersonaImage.of(await assets.prepare(base64Decode(image))),
      ],
    ),
  );
}

SharePayload connectionShare(ModelConnection connection, String apiKey) =>
    SharePayload(
      kind: ShareKind.connection,
      name: connection.name,
      data: {'connection': connection.raw, 'apiKey': apiKey},
    );

/// The shared connection under an id [takenIds] does not hold yet.
({ModelConnection connection, String apiKey}) receivedConnection(
  SharePayload payload,
  Set<String> takenIds,
) {
  final raw = jsonObject(payload.data['connection'], 'connection');
  final id = raw['id'] as String;
  return (
    connection: ModelConnection.fromJson({
      ...raw,
      if (takenIds.contains(id)) 'id': const Uuid().v4(),
    }),
    apiKey: payload.data['apiKey'] as String? ?? '',
  );
}
```

（若 `Persona.snapshot` 不含 `outfit`，以 `persona.dart` 中实际字段为准补齐 `name`、`description`、`appearance`、`outfit` 四项；`ResourceLibrary.repository` 若为私有，改为传入 `StoryRepository` 参数。）

- [ ] **Step 3: 桌面分享接口**

`remote_host.dart` import 增加 `import 'share.dart';`。字段区加入：

```dart
  /// What this host hands out to devices that scan a share code.
  final shares = ShareRegistry();
```

`_handle` 中 `if (_locked(ip)) …;` 之后、鉴权之前加入：

```dart
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
```

- [ ] **Step 4: 导出并运行**

`sillydraft_core.dart` 加入 `export 'src/remote/share.dart';`

Run: `dart test test/share_test.dart && dart test && dart analyze`
Expected: 全部通过。

---

### Task 10: 应用服务的远程模式、作品库切换与桌面共享生命周期

**Files:**
- Modify: `pubspec.yaml`（无新依赖；确认 `package_info_plus`、`path_provider` 已在）
- Modify: `lib/app/services.dart`
- Create: `lib/app/hosting.dart`
- Create: `lib/app/library_host.dart`
- Modify: `lib/app/app.dart:24-33`
- Test: `test/library_host_test.dart`

**Interfaces:**
- Consumes: Task 2–9 的核心类型。
- Produces:
  - `AppServices.remote(RemoteSession session, {required SecretStore secrets, required Directory cache, Uri? updateEndpoint})`；`final RemoteSession? remote`；`late final LibraryHosting hosting`；`Future<List<int>> resourceKey()`（原 `_resourceKey` 改为公开）；`bool get desktopPlatform`。
  - `Future<String> appVersionString()`。
  - `final class LibraryHosting extends ChangeNotifier`：`host`、`error`、`settings()`、`identity()`、`accessKey()`、`restore()`、`setEnabled(bool enabled, {int? port})`、`regenerateKey()`、`link(String address)`、`offer(SharePayload payload)` → `({ShareTicket ticket, int port, String fingerprint})`、`releaseShares()`、`stop()`。
  - `final class PairedDesktops`：`list()`、`save(ConnectLink)`（按指纹替换）、`remove(String fingerprint)`。
  - `final class LibraryHost extends ChangeNotifier`：`services`、`openRemote(ConnectLink)`、`openLocal()`；构造参数 `openLocal`、`openRemote` 供测试替换。
  - `final libraryHostProvider = Provider<LibraryHost>(…)`；`bool get isPhone`。
  - `SillyDraftApp({required AppServices services, Future<AppServices> Function()? openLocal})`。

- [ ] **Step 1: 写失败测试**

`test/library_host_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft/app/library_host.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'SillyDraft',
      packageName: 'com.moonrailgun.sillydraft',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );
  final link = ConnectLink(
    host: '127.0.0.1',
    port: 8790,
    key: randomSecret(),
    fingerprint: 'a' * 64,
    name: '测试桌面',
  );

  test('a desktop that refuses keeps this library and reports why', () async {
    final local = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(local.close);
    final host = LibraryHost(
      local,
      openRemote: (_, _) async =>
          throw const RemoteRequestFailed(401, '访问密钥无效，请重新扫码配对'),
    );
    await expectLater(
      host.openRemote(link),
      throwsA(isA<RemoteRequestFailed>()),
    );
    expect(host.services, same(local));
    expect(await PairedDesktops(local.secrets).list(), isEmpty);
    expect(await local.repository.listNovels(), isEmpty);
  });

  test('switching saves drafts, remembers the desktop, closes the old', () async {
    final local = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    var flushed = false;
    local.registerDraft(Object(), () async => flushed = true);
    final other = AppServices(
      repository: StoryRepository.memory(),
      secrets: local.secrets,
    );
    addTearDown(other.close);
    final host = LibraryHost(local, openRemote: (_, _) async => other);
    await host.openRemote(link);
    expect(flushed, isTrue);
    expect(host.services, same(other));
    expect(
      (await PairedDesktops(local.secrets).list()).single.fingerprint,
      link.fingerprint,
    );
    await expectLater(local.repository.setSetting('x', {}), throwsStateError);
  });

  test('a busy port leaves sharing off; a free one serves phones', () async {
    final dir = await Directory.systemTemp.createTemp('sd-hosting');
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
    );
    addTearDown(() async {
      await services.close();
      await dir.delete(recursive: true);
    });
    final busy = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    await services.hosting.setEnabled(true, port: busy.port);
    expect(services.hosting.host, isNull);
    expect(services.hosting.error, isA<SocketException>());
    expect((await services.hosting.settings())['enabled'], isFalse);
    await busy.close();

    await services.hosting.setEnabled(true, port: 0);
    expect((await services.hosting.settings())['enabled'], isTrue);
    final phone = await RemoteSession.connect(
      await services.hosting.link('127.0.0.1'),
      appVersion: '1.0.0+1',
    );
    expect(phone.hello.name, Platform.localHostname);
    await phone.close();
  });
}
```

Run: `flutter test test/library_host_test.dart`
Expected: 编译失败。

- [ ] **Step 2: `AppServices` 远程模式**

`lib/app/services.dart`：

1. import 增加 `import 'hosting.dart';`。
2. 构造函数改为下面两个，并新增 `_wire`：

```dart
  AppServices({
    required this.repository,
    required this.secrets,
    this.dataDirectory,
    this.updateEndpoint,
    ProviderFactory? modelProviderFactory,
    ImageProviderFactory? imageProviderFactory,
  }) : remote = null,
       _modelProviderFactory = modelProviderFactory {
    assets = dataDirectory == null
        ? null
        : AssetLibrary(
            repository: repository,
            directory: Directory('${dataDirectory!.path}/assets'),
          );
    runner = TaskRunner(
      repository: repository,
      providerFactory: modelProviderFactory ?? provider,
      imageProviderFactory: imageProviderFactory ?? imageProvider,
      assetLibrary: assets,
    );
    library = ResourceLibrary(repository: repository, keyProvider: resourceKey);
    _wire();
  }

  /// A paired desktop's library over [session]: its database, tasks, files
  /// and models. [secrets] stays this device's own; files are cached under
  /// [cache].
  AppServices.remote(
    RemoteSession session, {
    required this.secrets,
    required Directory cache,
    this.updateEndpoint,
  }) : repository = session.repository,
       remote = session,
       dataDirectory = null,
       _modelProviderFactory = null {
    assets = AssetLibrary(
      repository: repository,
      directory: Directory('${cache.path}/assets'),
      mirror: HttpAssetMirror(session),
    );
    runner = RemoteTaskControl(
      session,
      providerFactory: provider,
      imageProviderFactory: imageProvider,
      assetLibrary: assets,
    );
    library = ResourceLibrary(
      repository: repository,
      keyProvider: () async => session.hello.resourceKey,
    );
    _wire();
  }

  void _wire() {
    writing = WritingService(repository: repository, runner: runner);
    sidecar = SidecarAgent(repository: repository, runner: runner);
    editor = EditorAgent(repository: repository, runner: runner);
    illustrations = IllustrationService(repository: repository, runner: runner);
    personas = PersonaService(repository: repository, runner: runner);
  }
```

3. 字段区加入：

```dart
  /// The desktop this library belongs to; null for this device's own.
  final RemoteSession? remote;

  /// Sharing this library with phones, and handing out share codes.
  late final hosting = LibraryHosting(this);
```

4. `_keyFuture` / `_resourceKey` 改名为公开的 `resourceKey`：

```dart
  Future<List<int>> resourceKey() => _keyFuture ??= _loadResourceKey();
```

5. `draftProvider` 开头加入 `if (remote != null) throw StateError('连接在桌面管理');`；`provider` 开头加入 `if (remote case final session?) return DesktopModelProvider(session, connection);`；`imageProvider` 开头（`supportsImages` 检查之后）加入 `if (remote case final session?) return DesktopImageProvider(session, connection);`。

6. `close()` 改为：

```dart
  Future<void> close() async {
    await flushDrafts();
    await hosting.stop();
    await runner.close();
    if (remote case final session?) {
      await session.close();
    } else {
      await repository.close();
    }
  }
```

7. `AppServices.open` 中 `await services.runner.recoverInterrupted();` 之后加入：

```dart
    // A desktop shares its library again when the author left it on.
    if (desktopPlatform) unawaited(services.hosting.restore());
```

8. 文件末尾 `localCliAvailable` 改为：

```dart
/// macOS, Windows or Linux: hosts a library for phones and runs local CLIs.
bool get desktopPlatform =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Local subscriptions run an installed command-line tool: desktop only.
bool get localCliAvailable => desktopPlatform;
```

- [ ] **Step 3: 桌面共享生命周期**

`lib/app/hosting.dart`：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'services.dart';

/// `'<version>+<build>'`: what two devices must share to link libraries.
Future<String> appVersionString() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version}+${info.buildNumber}';
}

/// This device's TLS identity; on a desktop also the server that shares its
/// library with paired phones (setting `remoteHost`: `{enabled, port}`).
final class LibraryHosting extends ChangeNotifier {
  LibraryHosting(this.services);
  final AppServices services;
  RemoteHost? _host;
  Future<RemoteHost>? _shareHost;
  Future<TlsIdentity>? _identity;
  Object? _error;

  RemoteHost? get host => _host;

  /// Why sharing could not start, until the next attempt.
  Object? get error => _error;

  Future<Map<String, dynamic>> settings() async =>
      await services.repository.getSetting('remoteHost') ?? const {};

  Future<TlsIdentity> identity() => _identity ??= _loadIdentity().catchError(
    (Object e) {
      _identity = null;
      throw e;
    },
  );

  Future<TlsIdentity> _loadIdentity() async {
    final saved = await services.secrets.read('remote/tls');
    if (saved != null) {
      return TlsIdentity.fromJson(jsonDecode(saved) as Map<String, dynamic>);
    }
    final created = await Isolate.run(TlsIdentity.generate);
    await services.secrets.write('remote/tls', jsonEncode(created.toJson()));
    return created;
  }

  Future<String> accessKey() async {
    final saved = await services.secrets.read('remote/access-key');
    if (saved != null) return saved;
    final key = randomSecret();
    await services.secrets.write('remote/access-key', key);
    return key;
  }

  /// Shares the library again at launch when the author left it on.
  Future<void> restore() async {
    try {
      if ((await settings())['enabled'] == true) await setEnabled(true);
    } catch (e) {
      _error = e;
      notifyListeners();
    }
  }

  /// Starts or stops sharing. A port in use leaves sharing off, saved as
  /// off, with [error] saying why.
  Future<void> setEnabled(bool enabled, {int? port}) async {
    final nextPort =
        port ?? (await settings())['port'] as int? ?? defaultRemotePort;
    await _host?.close();
    _host = null;
    _error = null;
    if (enabled) {
      try {
        _host = await RemoteHost.start(
          identity: await identity(),
          name: Platform.localHostname,
          appVersion: await appVersionString(),
          port: nextPort,
          library: LibraryAccess(
            accessKey: await accessKey(),
            repository: services.repository,
            tasks: services.runner,
            assets:
                services.assets ?? (throw StateError('本地资源目录尚未就绪')),
            resourceKey: services.resourceKey,
            connections: services.connections,
            providerFactory: services.provider,
            imageProviderFactory: services.imageProvider,
          ),
        );
      } catch (e) {
        _error = e;
      }
    }
    await services.repository.setSetting('remoteHost', {
      'enabled': _host != null,
      'port': nextPort,
    });
    notifyListeners();
  }

  /// Every paired phone must scan the new link afterwards.
  Future<void> regenerateKey() async {
    await services.secrets.write('remote/access-key', randomSecret());
    if (_host != null) await setEnabled(true);
  }

  /// The pairing link for [address] while sharing runs.
  Future<ConnectLink> link(String address) async => ConnectLink(
    host: address,
    port: _host!.port,
    key: await accessKey(),
    fingerprint: (await identity()).fingerprint,
    name: Platform.localHostname,
  );

  /// Hands out [payload] from the library host, or from a share-only host
  /// started for it while sharing is off.
  Future<({ShareTicket ticket, int port, String fingerprint})> offer(
    SharePayload payload,
  ) async {
    final host = _host ?? await (_shareHost ??= _startShareHost());
    return (
      ticket: host.shares.open(payload),
      port: host.port,
      fingerprint: (await identity()).fingerprint,
    );
  }

  Future<RemoteHost> _startShareHost() async => RemoteHost.start(
    identity: await identity(),
    name: Platform.localHostname,
    appVersion: await appVersionString(),
    port: 0,
  );

  /// Stops the share-only host once no share is open.
  Future<void> releaseShares() async {
    final pending = _shareHost;
    if (pending == null) return;
    final host = await pending;
    if (!host.shares.isEmpty) return;
    _shareHost = null;
    await host.close();
  }

  Future<void> stop() async {
    await _host?.close();
    _host = null;
    final share = _shareHost;
    _shareHost = null;
    await (await share)?.close();
  }
}
```

- [ ] **Step 4: 作品库切换**

`lib/app/library_host.dart`：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'hosting.dart';
import 'services.dart';

/// Android or iOS: the devices that switch between libraries.
bool get isPhone => const {
  TargetPlatform.android,
  TargetPlatform.iOS,
}.contains(defaultTargetPlatform);

/// Desktops this phone paired with, kept in its own secrets file and told
/// apart by certificate: a re-scan after a new key replaces the old entry.
final class PairedDesktops {
  PairedDesktops(this.secrets);
  final SecretStore secrets;
  static const _key = 'remote/paired';

  Future<List<ConnectLink>> list() async {
    final saved = await secrets.read(_key);
    if (saved == null) return [];
    return [
      for (final text in (jsonDecode(saved) as List).cast<String>())
        SillyDraftLink.parse(text) as ConnectLink,
    ];
  }

  Future<void> save(ConnectLink link) async {
    final all = await list();
    final index = all.indexWhere((l) => l.fingerprint == link.fingerprint);
    index < 0 ? all.add(link) : all[index] = link;
    await _store(all);
  }

  Future<void> remove(String fingerprint) async =>
      _store((await list())..removeWhere((l) => l.fingerprint == fingerprint));

  Future<void> _store(List<ConnectLink> all) =>
      secrets.write(_key, jsonEncode([for (final l in all) '$l']));
}

/// Which library the app shows: this device's own, or a paired desktop's.
final class LibraryHost extends ChangeNotifier {
  LibraryHost(
    this._services, {
    Future<AppServices> Function()? openLocal,
    Future<AppServices> Function(ConnectLink link, AppServices current)?
    openRemote,
  }) : _openLocal = openLocal ?? AppServices.open,
       _openRemote = openRemote ?? _connect;

  AppServices _services;
  final Future<AppServices> Function() _openLocal;
  final Future<AppServices> Function(ConnectLink, AppServices) _openRemote;

  AppServices get services => _services;

  /// Shows [link]'s library and remembers the desktop. When it cannot be
  /// reached the error goes to the caller and this library stays open.
  Future<void> openRemote(ConnectLink link) async {
    final current = _services;
    await current.flushDrafts();
    final next = await _openRemote(link, current);
    await PairedDesktops(current.secrets).save(link);
    await _replace(next);
  }

  /// Back to this device's own library.
  Future<void> openLocal() async {
    if (_services.remote == null) return;
    await _services.flushDrafts();
    await _replace(await _openLocal());
  }

  Future<void> _replace(AppServices next) async {
    final previous = _services;
    _services = next;
    notifyListeners();
    // The new scope rebuilds from scratch; queries the old screens still
    // had in flight fail quietly into disposed providers.
    await previous.close();
  }

  static Future<AppServices> _connect(
    ConnectLink link,
    AppServices current,
  ) async {
    final session = await RemoteSession.connect(
      link,
      appVersion: await appVersionString(),
    );
    final cache = Directory(
      '${(await getApplicationCacheDirectory()).path}/remote/${link.fingerprint}',
    );
    return AppServices.remote(
      session,
      secrets: current.secrets,
      cache: cache,
      updateEndpoint: current.updateEndpoint,
    );
  }
}

final libraryHostProvider = Provider<LibraryHost>(
  (ref) => throw StateError('LibraryHost not initialized'),
);
```

- [ ] **Step 5: 应用根组件**

`lib/app/app.dart` 中 `SillyDraftApp` 改为：

```dart
class SillyDraftApp extends StatefulWidget {
  const SillyDraftApp({super.key, required this.services, this.openLocal});
  final AppServices services;

  /// Reopens this device's library after a desktop's; tests pass their own.
  final Future<AppServices> Function()? openLocal;

  @override
  State<SillyDraftApp> createState() => _SillyDraftAppState();
}

class _SillyDraftAppState extends State<SillyDraftApp> {
  late final _host = LibraryHost(widget.services, openLocal: widget.openLocal);

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _host,
    // A new scope per library: every provider and screen starts over.
    builder: (context, _) => ProviderScope(
      key: ObjectKey(_host.services),
      observers: [if (kDebugMode) DevtoolHistoryTrim()],
      overrides: [
        servicesProvider.overrideWithValue(_host.services),
        libraryHostProvider.overrideWithValue(_host),
      ],
      child: const _App(),
    ),
  );
}
```

并 import `'library_host.dart'`。

- [ ] **Step 6: 运行测试**

Run: `flutter test test/library_host_test.dart && flutter analyze && flutter test`
Expected: 全部通过。

---

### Task 11: 桌面“手机连接”设置页

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/features/remote/hosting_screen.dart`
- Modify: `lib/features/settings/settings_screen.dart:283-300`
- Test: `test/hosting_screen_test.dart`

**Interfaces:**
- Consumes: Task 10 `LibraryHosting`、`isPhone`。
- Produces: `HostingScreen({Future<List<String>> Function() addresses = reachableAddresses})`；设置页 `Key('settings-hosting')` 条目（非手机、本机作品库时显示）。

- [ ] **Step 1: 添加依赖**

仓库根目录：`flutter pub add qr_flutter`
Expected: `pubspec.yaml` 增加 `qr_flutter`，锁文件更新。

- [ ] **Step 2: 写失败测试**

`test/hosting_screen_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/remote/hosting_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets('sharing on shows the pairing code and link', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'SillyDraft',
      packageName: 'com.moonrailgun.sillydraft',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sd-hosting-ui'),
    ))!;
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
    );
    addTearDown(() => tester.runAsync(() async {
      await services.close();
      await dir.delete(recursive: true);
    }));
    await tester.runAsync(() => services.hosting.setEnabled(true, port: 0));
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator).first).push(
      MaterialPageRoute<void>(
        builder: (_) => HostingScreen(addresses: () async => ['127.0.0.1']),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.text('允许手机连接'), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('sillydraft://connect?'), findsOneWidget);
    expect(find.textContaining('读写这台电脑上的全部作品'), findsOneWidget);
  });
}
```

Run: `flutter test test/hosting_screen_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现设置页**

`lib/features/remote/hosting_screen.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/hosting.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';

/// 设置 → 手机连接: share this desktop's library with phones by QR code.
class HostingScreen extends ConsumerStatefulWidget {
  const HostingScreen({super.key, this.addresses = reachableAddresses});

  /// This desktop's reachable addresses; tests pass a fixed list.
  final Future<List<String>> Function() addresses;

  @override
  ConsumerState<HostingScreen> createState() => _HostingState();
}

class _HostingState extends ConsumerState<HostingScreen> {
  late final LibraryHosting _hosting = ref.read(servicesProvider).hosting;
  List<String> _addresses = const [];
  String? _address;
  ConnectLink? _link;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _hosting.addListener(_changed);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _hosting.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_refresh());

  Future<void> _refresh() async {
    final addresses = await widget.addresses();
    final address = addresses.contains(_address)
        ? _address
        : addresses.firstOrNull;
    final link = _hosting.host == null || address == null
        ? null
        : await _hosting.link(address);
    if (mounted) {
      setState(() {
        _addresses = addresses;
        _address = address;
        _link = link;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePort() async {
    final text = await askText(
      context,
      title: '更改端口',
      initial: '${_hosting.host?.port ?? defaultRemotePort}',
      label: '端口（1024–65535）',
    );
    final port = int.tryParse(text ?? '');
    if (text == null) return;
    if (port == null || port < 1024 || port > 65535) {
      if (mounted) showError(context, '端口须为 1024 到 65535 之间的数字');
      return;
    }
    await _run(() => _hosting.setEnabled(true, port: port));
  }

  Future<void> _regenerate() async {
    if (!await confirmAction(
      context,
      title: '重新生成密钥？',
      message: '已配对的手机需要重新扫码才能连接。',
      confirmLabel: '重新生成',
      destructive: true,
    )) {
      return;
    }
    await _run(_hosting.regenerateKey);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final host = _hosting.host, link = _link, error = _hosting.error;
    return PageScaffold(
      title: '手机连接',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('打开后，手机扫码即可直接使用这台电脑的作品库、资料和模型。生成任务在这台电脑上执行，手机锁屏也不中断。'),
          const SizedBox(height: 16),
          FTileGroup(
            children: [
              FTile(
                key: const Key('hosting-switch'),
                prefix: const Icon(FLucideIcons.smartphone),
                title: const Text('允许手机连接'),
                subtitle: Text(host == null ? '未开启' : '端口 ${host.port}'),
                suffix: FSwitch(
                  value: host != null,
                  onChange: _busy
                      ? null
                      : (value) => _run(() => _hosting.setEnabled(value)),
                ),
                onPress: _busy
                    ? null
                    : () => _run(() => _hosting.setEnabled(host == null)),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              '无法开启：$error',
              style: theme.typography.body.sm.copyWith(color: theme.colors.error),
            ),
          ],
          if (host != null && _addresses.isEmpty) ...[
            const SizedBox(height: 16),
            const Text('没有找到可用的网络地址：请连接 Wi‑Fi 或局域网。'),
          ],
          if (link != null) ...[
            const SizedBox(height: 24),
            if (_addresses.length > 1)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final address in _addresses)
                    ChoicePill(
                      label: address,
                      selected: address == _address,
                      onPress: () {
                        _address = address;
                        unawaited(_refresh());
                      },
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFFFFFFFF),
                child: QrImageView(data: '$link', size: 240),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText('$link', style: muted),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  prefix: const Icon(FLucideIcons.copy),
                  onPress: () async {
                    await Clipboard.setData(ClipboardData(text: '$link'));
                    if (context.mounted) toast(context, '已复制连接链接');
                  },
                  child: const Text('复制连接链接'),
                ),
                FButton(
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _changePort,
                  child: const Text('更改端口'),
                ),
                FButton(
                  variant: FButtonVariant.destructive,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _regenerate,
                  child: const Text('重新生成密钥'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text(
            '持有连接链接即可读写这台电脑上的全部作品，并能用这里的模型发起付费调用。只在自己的设备间扫码，不要截图外传。',
            style: muted,
          ),
          const SizedBox(height: 8),
          Text('手机需要和电脑在同一局域网，或都加入 Tailscale 等互通的网络。两边须为同一版本的 SillyDraft。', style: muted),
        ],
      ),
    );
  }
}
```

（`appVersionString` 的 import 若未使用则删去 `../../app/hosting.dart` 以外的多余 import；`LibraryHosting` 来自 `hosting.dart`。）

- [ ] **Step 4: 设置页入口**

`settings_screen.dart` 顶部 import 增加 `import '../../app/library_host.dart';` 与 `import '../remote/hosting_screen.dart';`。在 `build` 开头加入 `final remote = ref.watch(servicesProvider).remote;`。在“助手技能”所在 `FTileGroup` 的 `children` 中，`settings-skills` 条目之后加入：

```dart
                  if (!isPhone && remote == null)
                    FTile(
                      key: const Key('settings-hosting'),
                      prefix: const Icon(FLucideIcons.smartphone),
                      title: const Text('手机连接'),
                      subtitle: _wrapped('让手机扫码使用这台电脑的作品库和模型'),
                      suffix: const Icon(FLucideIcons.chevronRight),
                      onPress: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const HostingScreen(),
                        ),
                      ),
                    ),
```

- [ ] **Step 5: 运行**

Run: `flutter test test/hosting_screen_test.dart && flutter analyze && flutter test test/settings_test.dart`
Expected: 通过（`test/settings_test.dart` 不存在时运行 `flutter test`）。

---

### Task 12: 扫码、粘贴与分享界面

**Files:**
- Modify: `pubspec.yaml`
- Modify: `ios/Runner/Info.plist`
- Create: `lib/features/remote/scan_screen.dart`
- Create: `lib/features/remote/share_screen.dart`
- Modify: `lib/features/bookshelf/bookshelf_screen.dart:277-300`
- Modify: `lib/features/resources/resource_library_screen.dart:406-413`
- Modify: `lib/features/skills/skills_screen.dart:219-226`
- Modify: `lib/features/personas/persona_editor_screen.dart:242-249`
- Modify: `lib/features/settings/settings_screen.dart:174-182`
- Test: `test/share_flow_test.dart`

**Interfaces:**
- Consumes: Task 9 分享函数；Task 10 `LibraryHosting.offer/releaseShares`、`libraryHostProvider`、`isPhone`。
- Produces:
  - `ScanScreen`（`Navigator.pop` 返回扫到的文本）。
  - `Future<void> openLink(BuildContext, WidgetRef, String text)`、`Future<void> scanLink(BuildContext, WidgetRef)`、`Future<void> pasteLink(BuildContext, WidgetRef)`。
  - `typedef ShareOffer = ({List<ReceiveLink> links, Future<void> received, void Function() close});`
  - `ShareScreen({required Future<SharePayload> Function() build, bool containsKey = false, Future<ShareOffer> Function(SharePayload)? offer})`；`ReceiveScreen({required ReceiveLink link, Future<SharePayload> Function(ReceiveLink)? fetch})`。
  - `Future<void> shareByQr(BuildContext context, Future<SharePayload> Function() build, {bool containsKey = false})`。

- [ ] **Step 1: 依赖与权限**

仓库根目录：`flutter pub add mobile_scanner`

`ios/Runner/Info.plist` 的 `<dict>` 内加入：

```xml
	<key>NSCameraUsageDescription</key>
	<string>用于扫描 SillyDraft 的配对与分享二维码</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>用于连接同一网络中运行 SillyDraft 的电脑或手机</string>
```

- [ ] **Step 2: 写失败测试**

`test/share_flow_test.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/remote/share_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  final link = ReceiveLink(
    host: '192.168.1.5',
    port: 51000,
    token: randomSecret(),
    fingerprint: 'a' * 64,
  );
  Future<NavigatorState> app(WidgetTester tester, AppServices services) async {
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    return tester.state<NavigatorState>(find.byType(Navigator).first);
  }

  testWidgets('a share page shows its code until it is received', (tester) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final received = Completer<void>();
    var closed = false;
    final navigator = await app(tester, services);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ShareScreen(
            containsKey: true,
            build: () async => connectionShare(
              ModelConnection(id: 'w', name: '写手', baseUrl: 'https://a/v1', model: 'm'),
              'sk-1',
            ),
            offer: (_) async => (
              links: [link],
              received: received.future,
              close: () => closed = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('含 API Key'), findsOneWidget);
    received.complete();
    await tester.pumpAndSettle();
    expect(find.text('已被接收'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('receiving a connection previews it and saves the key', (tester) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final navigator = await app(tester, services);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ReceiveScreen(
            link: link,
            fetch: (_) async => connectionShare(
              ModelConnection(id: 'w', name: '写手', baseUrl: 'https://a/v1', model: 'm'),
              'sk-1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('写手'), findsOneWidget);
    expect(find.textContaining('含 API Key'), findsOneWidget);
    await tester.tap(find.text('接收'));
    await tester.pumpAndSettle();
    expect((await services.connections()).single.name, '写手');
    expect(await services.secrets.read('model/w'), 'sk-1');
  });
}
```

Run: `flutter test test/share_flow_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 扫码页**

`lib/features/remote/scan_screen.dart`：

```dart
import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/widgets.dart';

/// Scans one QR code and returns its text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanState();
}

class _ScanState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '扫码',
    body: MobileScanner(
      onDetect: (capture) {
        final value = capture.barcodes.firstOrNull?.rawValue;
        if (_done || value == null) return;
        _done = true;
        Navigator.pop(context, value);
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('无法使用相机：${error.errorDetails?.message ?? error.errorCode.name}。可以改用“粘贴链接”。'),
        ),
      ),
    ),
  );
}
```

（`errorBuilder` 的签名以所装 `mobile_scanner` 版本为准；7.x 为 `(BuildContext, MobileScannerException)`。）

- [ ] **Step 4: 分享与接收页、链接入口**

`lib/features/remote/share_screen.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/library_host.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';
import 'scan_screen.dart';

/// What a share page shows: one link per reachable address.
typedef ShareOffer = ({
  List<ReceiveLink> links,
  Future<void> received,
  void Function() close,
});

/// Opens a share page for what [build] produces.
Future<void> shareByQr(
  BuildContext context,
  Future<SharePayload> Function() build, {
  bool containsKey = false,
}) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => ShareScreen(build: build, containsKey: containsKey),
  ),
);

/// Opens what a scanned or pasted link points to: a desktop to pair with,
/// or a share to receive.
Future<void> openLink(BuildContext context, WidgetRef ref, String text) async {
  try {
    switch (SillyDraftLink.parse(text)) {
      case final ConnectLink link:
        if (!isPhone) {
          throw const FormatException('这是桌面的配对链接，请在手机上扫码或粘贴');
        }
        await ref.read(libraryHostProvider).openRemote(link);
      case final ReceiveLink link:
        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => ReceiveScreen(link: link)),
          );
        }
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> scanLink(BuildContext context, WidgetRef ref) async {
  final text = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const ScanScreen()),
  );
  if (text != null && context.mounted) await openLink(context, ref, text);
}

Future<void> pasteLink(BuildContext context, WidgetRef ref) async {
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return;
  final text = await askText(
    context,
    title: '粘贴链接',
    label: '配对或分享链接',
    initial: clipboard?.text?.startsWith('sillydraft://') == true
        ? clipboard!.text!
        : '',
  );
  if (text != null && context.mounted) await openLink(context, ref, text);
}

class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({
    super.key,
    required this.build,
    this.containsKey = false,
    this.offer,
  });
  final Future<SharePayload> Function() build;

  /// The payload carries an API key: the page warns about screenshots.
  final bool containsKey;

  /// Hands the payload out; the app's [LibraryHosting] unless a test passes
  /// its own.
  final Future<ShareOffer> Function(SharePayload)? offer;

  @override
  ConsumerState<ShareScreen> createState() => _ShareState();
}

class _ShareState extends ConsumerState<ShareScreen> {
  late final AppServices _services = ref.read(servicesProvider);
  ShareOffer? _offer;
  int _selected = 0;
  bool _received = false, _expired = false;
  Object? _error;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<ShareOffer> _hostOffer(SharePayload payload) async {
    final hosting = _services.hosting;
    final offered = await hosting.offer(payload);
    final addresses = await reachableAddresses();
    return (
      links: [
        for (final address in addresses)
          ReceiveLink(
            host: address,
            port: offered.port,
            token: offered.ticket.token,
            fingerprint: offered.fingerprint,
          ),
      ],
      received: offered.ticket.received,
      close: () {
        offered.ticket.close();
        unawaited(hosting.releaseShares());
      },
    );
  }

  Future<void> _open() async {
    try {
      final payload = await widget.build();
      final offer = await (widget.offer ?? _hostOffer)(payload);
      if (!mounted) {
        offer.close();
        return;
      }
      setState(() => _offer = offer);
      unawaited(
        offer.received.then((_) {
          if (mounted) setState(() => _received = true);
        }),
      );
      _expiry = Timer(const Duration(minutes: 10), () {
        if (mounted) setState(() => _expired = true);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _offer?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final offer = _offer;
    return PageScaffold(
      title: '扫码分享',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_error != null)
            Text('无法分享：$_error')
          else if (offer == null)
            const Center(child: FCircularProgress())
          else if (offer.links.isEmpty)
            const Text('没有找到可用的网络地址：请连接 Wi‑Fi 或局域网。')
          else ...[
            if (offer.links.length > 1)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, link) in offer.links.indexed)
                    ChoicePill(
                      label: link.host,
                      selected: i == _selected,
                      onPress: () => setState(() => _selected = i),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFFFFFFFF),
                child: QrImageView(data: '${offer.links[_selected]}', size: 240),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _received
                    ? '已被接收'
                    : _expired
                    ? '已过期，请重新打开分享'
                    : '等待另一台设备扫码',
                style: theme.typography.body.md.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText('${offer.links[_selected]}', style: muted),
            const SizedBox(height: 8),
            FButton(
              variant: FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              prefix: const Icon(FLucideIcons.copy),
              onPress: () async {
                await Clipboard.setData(
                  ClipboardData(text: '${offer.links[_selected]}'),
                );
                if (context.mounted) toast(context, '已复制分享链接');
              },
              child: const Text('复制链接'),
            ),
          ],
          const SizedBox(height: 24),
          if (widget.containsKey)
            Text(
              '二维码含 API Key：看到或截到它的人都能用这把密钥。',
              style: theme.typography.body.sm.copyWith(color: theme.colors.error),
            ),
          const SizedBox(height: 8),
          Text('另一台设备需在同一网络。分享在本页打开期间有效，最长 10 分钟，被接收一次后失效。', style: muted),
        ],
      ),
    );
  }
}

class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, required this.link, this.fetch});
  final ReceiveLink link;
  final Future<SharePayload> Function(ReceiveLink)? fetch;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveState();
}

class _ReceiveState extends ConsumerState<ReceiveScreen> {
  SharePayload? _payload;
  Object? _error;
  bool _busy = false;

  static const _kinds = {
    ShareKind.resource: '资源',
    ShareKind.skill: '助手技能',
    ShareKind.persona: '人设',
    ShareKind.connection: '模型连接',
  };

  @override
  void initState() {
    super.initState();
    unawaited(
      (widget.fetch ?? fetchShare)(widget.link).then(
        (payload) {
          if (mounted) setState(() => _payload = payload);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      ),
    );
  }

  Future<void> _accept(SharePayload payload) async {
    final services = ref.read(servicesProvider);
    setState(() => _busy = true);
    try {
      switch (payload.kind) {
        case ShareKind.resource:
          await receiveResource(services.library, payload);
        case ShareKind.skill:
          final skill = receivedSkill(payload);
          final mine = await services.skills.installed();
          if (mine.any((s) => s.name == skill.name) &&
              !(context.mounted &&
                  await confirmAction(
                    context,
                    title: '覆盖同名技能？',
                    message: '已有名为 ${skill.name} 的技能。',
                    confirmLabel: '覆盖',
                  ))) {
            return;
          }
          await services.skills.install([skill]);
        case ShareKind.persona:
          await receivePersona(
            services.repository,
            services.assets ?? (throw StateError('本地资源目录尚未就绪')),
            payload,
          );
        case ShareKind.connection:
          if (services.remote != null) {
            throw StateError('连接在桌面管理，请切回本机后再接收');
          }
          final taken = {for (final c in await services.connections()) c.id};
          final received = receivedConnection(payload, taken);
          if (received.connection.protocol.isLocalCli && !localCliAvailable) {
            throw const FormatException('本地订阅连接只能在桌面端使用');
          }
          await services.saveConnection(
            received.connection,
            apiKey: received.apiKey,
          );
      }
      if (mounted) {
        toast(context, '已接收「${payload.name}」');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    return PageScaffold(
      title: '接收分享',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_error != null)
            Text('$_error')
          else if (payload == null)
            const Center(child: FCircularProgress())
          else ...[
            FTileGroup(
              children: [
                FTile(
                  title: Text(payload.name),
                  subtitle: Text(
                    [
                      _kinds[payload.kind]!,
                      if (payload.kind == ShareKind.connection) '含 API Key',
                    ].join(' · '),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FButton(
              onPress: _busy ? null : () => _accept(payload),
              child: const Text('接收'),
            ),
          ],
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: 各处分享入口与书架入口**

1. `resource_library_screen.dart` 的“导出 JSON”按钮之后加入：

```dart
                FButton(
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => shareByQr(
                    context,
                    () => resourceShare(ref.read(servicesProvider).library, resource.id),
                  ),
                  prefix: const Icon(FLucideIcons.qrCode),
                  child: const Text('扫码分享'),
                ),
```

2. `skills_screen.dart` 的 `SkillDetailScreen` 菜单 `entries` 中“导出 SKILL.md”之后加入：

```dart
            if (!skill.builtIn)
              menuEntry(
                '扫码分享',
                () => shareByQr(context, () async => skillShare(skill)),
                icon: FLucideIcons.qrCode,
              ),
```

3. `persona_editor_screen.dart` 的 `actions` 开头加入：

```dart
        if (_id.isNotEmpty)
          HeaderIconAction(
            tooltip: '扫码分享',
            icon: FLucideIcons.qrCode,
            onPress: () => shareByQr(context, () async {
              final services = ref.read(servicesProvider);
              final saved = (await services.repository.listPersonas())
                  .firstWhere((p) => p.id == _id);
              return personaShare(
                saved,
                services.assets ?? (throw StateError('本地资源目录尚未就绪')),
              );
            }),
          ),
```

4. `settings_screen.dart` 连接条目的 `suffix: IconAction(…编辑连接…)` 改为：

```dart
                              suffix: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconAction(
                                    icon: FLucideIcons.qrCode,
                                    tooltip: '扫码分享',
                                    onPress: () => shareByQr(
                                      context,
                                      () async => connectionShare(
                                        connection,
                                        await ref
                                                .read(servicesProvider)
                                                .secrets
                                                .read('model/${connection.id}') ??
                                            '',
                                      ),
                                      containsKey: true,
                                    ),
                                  ),
                                  IconAction(
                                    icon: FLucideIcons.pencil,
                                    tooltip: '编辑连接',
                                    onPress: () => showAppDialog<void>(
                                      context: context,
                                      builder: (_) =>
                                          ConnectionDialog(connection: connection),
                                    ),
                                  ),
                                ],
                              ),
```

5. `bookshelf_screen.dart` 的“导入与同步” `MenuAction.entries` 末尾加入：

```dart
              if (isPhone)
                menuEntry(
                  '扫码',
                  () => scanLink(context, ref),
                  icon: FLucideIcons.scanLine,
                ),
              menuEntry(
                '粘贴链接',
                () => pasteLink(context, ref),
                icon: FLucideIcons.clipboardPaste,
              ),
```

各文件补上 `import '../remote/share_screen.dart';`（书架另加 `import '../../app/library_host.dart';`）。图标名以 forui 实际提供的 `FLucideIcons` 为准（`qrCode`、`scanLine`、`clipboardPaste`）。

- [ ] **Step 6: 运行**

Run: `flutter test test/share_flow_test.dart && flutter analyze && flutter test`
Expected: 全部通过。

---

### Task 13: 手机的作品库切换、断线提示条与远程模式限制

**Files:**
- Create: `lib/features/remote/library_switcher.dart`
- Modify: `lib/features/remote/share_screen.dart`（`openLink` 的配对分支）
- Modify: `lib/features/bookshelf/bookshelf_screen.dart:237-255`
- Modify: `lib/app/app.dart`（`MaterialApp.builder`）
- Modify: `lib/features/settings/settings_screen.dart`
- Test: `test/remote_mode_test.dart`

**Interfaces:**
- Consumes: Task 10 `LibraryHost`、`PairedDesktops`、`isPhone`；Task 12 `scanLink`、`pasteLink`。
- Produces：`pairedDesktopsProvider`、`remoteStatusProvider`、`LibrarySwitcher`、`RemoteFrame({required Widget child})`、`Future<void> switchLibrary(BuildContext, WidgetRef, ConnectLink? link)`（`null` 表示本机）、`PairedDesktopsScreen`。

- [ ] **Step 1: 写失败测试**

`test/remote_mode_test.dart`：

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/library_host.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

/// Lets real socket traffic arrive, then builds, until [finder] shows.
Future<void> _settle(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  ConnectLink link({String name = '书房'}) => ConnectLink(
    host: '192.168.1.5',
    port: 8790,
    key: randomSecret(),
    fingerprint: 'b' * 64,
    name: name,
  );

  test('re-pairing a desktop replaces its entry', () async {
    final paired = PairedDesktops(MemorySecrets());
    await paired.save(link(name: '旧名'));
    final fresh = link();
    await paired.save(fresh);
    final all = await paired.list();
    expect(all, hasLength(1));
    expect(all.single.key, fresh.key);
    expect(all.single.name, '书房');
  });

  testWidgets(
    'a phone lists paired desktops and warns before interrupting tasks',
    (tester) async {
      final repository = StoryRepository.memory();
      final novel = await repository.createNovel(title: '本机作品');
      await repository.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.writing,
        input: const {},
      );
      final services = AppServices(
        repository: repository,
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await PairedDesktops(services.secrets).save(link());
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SillyDraft'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('书房'));
      await tester.pumpAndSettle();
      expect(find.textContaining('切换会中断 1 个本机任务'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('本机作品'), findsOneWidget);
    },
    variant: _phone,
  );
}
```

（`createTask` 的参数以 `task_store.dart` 实际签名为准；新任务状态为 `queued`，即 `isActive`。）

Run: `flutter test test/remote_mode_test.dart`
Expected: 第一个用例通过（Task 10 已实现），第二个失败：找不到可点击的“SillyDraft”菜单与配对条目。

- [ ] **Step 2: 切换器、提示条与配对管理**

`lib/features/remote/library_switcher.dart`：

```dart
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/library_host.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';
import 'share_screen.dart';

final pairedDesktopsProvider = FutureProvider<List<ConnectLink>>(
  (ref) => PairedDesktops(ref.watch(servicesProvider).secrets).list(),
);

final remoteStatusProvider = StreamProvider<RemoteStatus>(
  (ref) =>
      ref.watch(servicesProvider).remote?.statuses ??
      Stream.value((connected: true, problem: null)),
);

/// Opens [link]'s library, or this device's own for null. Leaving this
/// device's library first asks when its own tasks are still running.
Future<void> switchLibrary(
  BuildContext context,
  WidgetRef ref,
  ConnectLink? link,
) async {
  final host = ref.read(libraryHostProvider), services = ref.read(servicesProvider);
  try {
    if (link == null) return await host.openLocal();
    if (services.remote?.link.fingerprint == link.fingerprint) return;
    if (services.remote == null) {
      final running = (await services.repository.listTasks())
          .where((t) => t.isActive)
          .length;
      if (running > 0 &&
          (!context.mounted ||
              !await confirmAction(
                context,
                title: '切换作品库？',
                message: '切换会中断 $running 个本机任务。',
                confirmLabel: '切换',
              ))) {
        return;
      }
    }
    await host.openRemote(link);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// The bookshelf title on a phone: which library is open, and a menu to
/// switch.
class LibrarySwitcher extends ConsumerWidget {
  const LibrarySwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remote = ref.watch(servicesProvider).remote;
    final paired = ref.watch(pairedDesktopsProvider).value ?? const [];
    final theme = context.theme;
    return MenuAction(
      tooltip: '切换作品库',
      entries: [
        menuEntry(
          '本机',
          () => switchLibrary(context, ref, null),
          icon: FLucideIcons.smartphone,
        ),
        for (final link in paired)
          menuEntry(
            '${link.name}（${link.host}）',
            () => switchLibrary(context, ref, link),
            icon: FLucideIcons.monitor,
          ),
        menuEntry('扫码添加桌面', () => scanLink(context, ref), icon: FLucideIcons.scanLine),
        menuEntry('粘贴链接', () => pasteLink(context, ref), icon: FLucideIcons.clipboardPaste),
        if (paired.isNotEmpty)
          menuEntry(
            '管理配对',
            () => Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const PairedDesktopsScreen()),
            ),
            icon: FLucideIcons.settings2,
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            remote == null ? FLucideIcons.libraryBig : FLucideIcons.monitor,
            size: 24,
            color: theme.colors.foreground,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              remote == null ? 'SillyDraft' : '桌面：${remote.hello.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(FLucideIcons.chevronDown, size: 18, color: theme.colors.mutedForeground),
        ],
      ),
    );
  }
}

/// [child] under a bar saying the desktop is unreachable, with a way back
/// to this device's library.
class RemoteFrame extends ConsumerWidget {
  const RemoteFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(remoteStatusProvider).value;
    if (status == null || status.connected) return child;
    final theme = context.theme;
    final style = theme.typography.body.sm.copyWith(
      color: theme.colors.errorForeground,
    );
    return Column(
      children: [
        ColoredBox(
          color: theme.colors.error,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(FLucideIcons.unplug, size: 18, color: style.color),
                  const SizedBox(width: 12),
                  Expanded(child: Text(status.problem ?? '与桌面断开，正在重连', style: style)),
                  FButton(
                    variant: FButtonVariant.outline,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => ref.read(libraryHostProvider).openLocal(),
                    child: const Text('切回本机'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}

class PairedDesktopsScreen extends ConsumerWidget {
  const PairedDesktopsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paired = ref.watch(pairedDesktopsProvider);
    return PageScaffold(
      title: '已配对的桌面',
      body: AsyncView(
        value: paired,
        builder: (List<ConnectLink> all) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (all.isEmpty) const Text('还没有配对的桌面。'),
            if (all.isNotEmpty)
              FTileGroup(
                children: [
                  for (final link in all)
                    FTile(
                      prefix: const Icon(FLucideIcons.monitor),
                      title: Text(link.name),
                      subtitle: Text('${link.host}:${link.port}'),
                      suffix: IconAction(
                        icon: FLucideIcons.trash2,
                        tooltip: '删除配对',
                        onPress: () async {
                          await PairedDesktops(
                            ref.read(servicesProvider).secrets,
                          ).remove(link.fingerprint);
                          ref.invalidate(pairedDesktopsProvider);
                        },
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
```

（界面以“桌面”称呼对方设备，与核心包的报错一致；桌面自己的设置页用“这台电脑”指本机。）

- [ ] **Step 3: 接入**

1. `share_screen.dart` 的 `openLink` 中 `await ref.read(libraryHostProvider).openRemote(link);` 改为 `if (context.mounted) await switchLibrary(context, ref, link);`，并 import `'library_switcher.dart'`。
2. `bookshelf_screen.dart` 窄屏标题中的 `Row(children: [Icon(FLucideIcons.libraryBig, …), …, Flexible(child: Text('SillyDraft', …))])` 改为 `isPhone ? const LibrarySwitcher() : Row(…原样…)`，import `'../../app/library_host.dart'` 与 `'../remote/library_switcher.dart'`。
3. `app.dart` 的 `MaterialApp.builder` 中 `child: DesktopCommands(invoke: _command, child: child!),` 改为 `child: RemoteFrame(child: DesktopCommands(invoke: _command, child: child!)),`，import `'../features/remote/library_switcher.dart'`。
4. `settings_screen.dart`：
   - `ListView.children` 开头（“让工具适合你的写作方式”之前）加入：

```dart
              if (remote != null) ...[
                FTileGroup(
                  children: [
                    FTile(
                      key: const Key('settings-remote'),
                      prefix: const Icon(FLucideIcons.monitor),
                      title: Text('正在使用桌面：${remote.hello.name}'),
                      subtitle: _wrapped('作品、资料和模型都来自这台桌面电脑'),
                      suffix: FButton(
                        variant: FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: () => ref.read(libraryHostProvider).openLocal(),
                        child: const Text('切回本机'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
```

   - “添加连接”的 `FButton` 外包 `if (remote == null)`。
   - 连接说明文字改为 `remote == null ? '一个连接可保存多个模型。…（原文）' : '连接在桌面管理：地址与密钥只保存在桌面电脑里。这里可以为各任务选择连接。'`。
   - 连接条目的 `suffix:` 改为 `suffix: remote == null ? Row(…Task 12 的两个按钮…) : null,`。

- [ ] **Step 4: 远程模式只读的测试**

在 `test/remote_mode_test.dart` 的 `main` 末尾加入（真实回环服务，所有 IO 放进 `runAsync`）：

```dart
  testWidgets(
    'a remote library shows its desktop and keeps connections read-only',
    (tester) async {
      late StoryRepository desktop;
      late RemoteHost host;
      late AppServices services;
      late Directory cache;
      await tester.runAsync(() async {
        final identity = TlsIdentity.generate();
        desktop = StoryRepository.memory();
        await desktop.createNovel(title: '桌面作品');
        cache = await Directory.systemTemp.createTemp('sd-remote-ui');
        final key = randomSecret();
        Future<ModelProvider> noText(ModelConnection _) async =>
            throw StateError('no model in this test');
        Future<ImageProvider> noImage(ModelConnection _) async =>
            throw StateError('no model in this test');
        host = await RemoteHost.start(
          identity: identity,
          name: '书房',
          appVersion: '1.0.0+1',
          address: InternetAddress.loopbackIPv4,
          port: 0,
          library: LibraryAccess(
            accessKey: key,
            repository: desktop,
            tasks: TaskRunner(repository: desktop, providerFactory: noText),
            assets: AssetLibrary(
              repository: desktop,
              directory: Directory('${cache.path}/desktop'),
            ),
            resourceKey: () async => List.filled(32, 1),
            connections: () async => [],
            providerFactory: noText,
            imageProviderFactory: noImage,
          ),
        );
        final session = await RemoteSession.connect(
          ConnectLink(
            host: '127.0.0.1',
            port: host.port,
            key: key,
            fingerprint: identity.fingerprint,
            name: '书房',
          ),
          appVersion: '1.0.0+1',
        );
        services = AppServices.remote(
          session,
          secrets: MemorySecrets(),
          cache: Directory('${cache.path}/phone'),
        );
      });
      addTearDown(
        () => tester.runAsync(() async {
          await services.close();
          await host.close();
          await desktop.close();
          await cache.delete(recursive: true);
        }),
      );
      await tester.pumpWidget(SillyDraftApp(services: services));
      await _settle(tester, find.text('桌面作品'));
      expect(find.text('桌面：书房'), findsOneWidget);
      expect(find.text('桌面作品'), findsOneWidget);

      await tester.tap(find.text('设置'));
      await _settle(tester, find.byKey(const Key('settings-remote')));
      expect(find.byKey(const Key('settings-remote')), findsOneWidget);
      expect(find.text('添加连接'), findsNothing);
    },
    variant: _phone,
  );
```

（底部导航“设置”的文字以 `HomeScreen` 实际标签为准。）

- [ ] **Step 5: 运行**

Run: `flutter test test/remote_mode_test.dart && flutter analyze && flutter test`
Expected: 全部通过。

---

### Task 14: 文档与手动验证清单

**Files:**
- Modify: `docs/user-guide.md:201-206`
- Modify: `docs/product-spec.md`
- Modify: `AGENTS.md`（架构一节）
- Modify: `server/README.md`（开头一句）
- Create: `docs/verification/remote-library.md`

- [ ] **Step 1: 用户指南**

`docs/user-guide.md` 的“任务中断与远程执行”一节之前新增一节：

```markdown
## 手机使用桌面上的作品库

**桌面上**：设置 → 手机连接 → 打开“允许手机连接”。页面显示二维码和连接链接；桌面有多个网络地址（如 Tailscale）时可切换。开关状态会保留，下次启动自动恢复；端口被占用时显示原因并保持关闭。“重新生成密钥”后，已配对的手机需要重新扫码。

**手机上**：书架左上角点“SillyDraft ▾” → 扫码添加桌面（或粘贴链接）。连接成功后书架、正文、资料、任务都是桌面上的那一份，生成在桌面上执行，手机锁屏或退到后台不影响。每次打开应用都回到本机作品库；从同一个菜单切换。桌面和手机的作品库互不影响。

- 两边须为同一版本，不一致时会提示双方版本。
- 连接断开时顶部显示提示条并自动重连，编辑中的文字保留；断开期间的保存会报错，重连后再保存。
- 远程模式下不能新增或编辑模型连接（密钥只在桌面里），可以为各任务选择连接。
- 持有连接链接即可读写桌面上的全部作品并用桌面的模型付费调用。只在自己的设备间扫码。

## 扫码传输

资源库的角色卡、预设、世界书、正则，以及助手技能、人设、模型连接都可以“扫码分享”：另一台设备在书架菜单里扫码（桌面上粘贴链接）即可收到一份副本。

- 分享页开着时有效，最长 10 分钟，被接收一次即失效。
- 两台设备需在同一网络。手机作为分享方时请停留在分享页。
- 模型连接的二维码含 API Key：看到二维码的人就能使用这把密钥。
- 角色卡连同修改过的版本与卡内图片一起传输。
```

“任务中断与远程执行”一节末尾补一句：`手机使用桌面上的作品库时，任务本来就在桌面上执行，见上一节；独立的个人远程执行器适合手机用本机作品库、借用服务器上模型的情况。`

- [ ] **Step 2: 产品规格、AGENTS、执行器说明**

`docs/product-spec.md` 的功能列表追加一条：`桌面可把作品库共享给已配对的手机（TLS 证书锁定、访问密钥），任务在桌面执行；资源、技能、人设、模型连接可扫码在设备间传输。`

`AGENTS.md` 架构一节 `packages/sillydraft_core/` 条目末尾补：`远程作品库与扫码传输在 src/remote/：桌面的 RemoteHost 经 drift 远程协议共享数据库，手机的 RemoteSession 断线重连时仓库对象不变。`

`server/README.md` 第一段末尾补：`手机若要直接使用桌面上的作品库，用应用内的“设置 → 手机连接”，不需要本服务。`

- [ ] **Step 3: 手动验证清单**

`docs/verification/remote-library.md`：

```markdown
# 远程作品库与扫码传输：手动验证

CI 无法覆盖相机与真实网络，发布前在真机上走一遍。

## 准备

- 一台 macOS / Windows 电脑（下称桌面）与一台 iOS 或 Android 手机，同一 Wi‑Fi；另测一次两边都在 Tailscale。
- 两边安装同一构建。

## 配对与使用

1. 桌面：设置 → 手机连接 → 打开。二维码出现，地址为局域网 IP。
2. 手机：书架 → SillyDraft ▾ → 扫码添加桌面。首次使用时系统询问相机与本地网络权限，允许后进入桌面作品库，标题显示“桌面：<名称>”。
3. 手机打开一章续写；生成开始后锁屏 1 分钟再解锁：任务在桌面上已完成或仍在进行，手机任务页显示一致。
4. 桌面与手机同时打开同一章，先在桌面保存，再在手机保存：手机提示版本冲突。
5. 手机导入一张图片作插图：桌面上立即可见。

## 断线与恢复

6. 桌面关闭开关：手机顶部显示“桌面已停止共享”；点“切回本机”回到手机作品库。
7. 再次打开开关、手机重新切换；关闭桌面 Wi‑Fi 30 秒后恢复：手机提示断开后自动恢复，未保存的文字仍在。
8. 桌面“重新生成密钥”：手机切换时提示访问密钥无效并留在本机；重新扫码后配对列表只有一条。

## 扫码传输

9. 手机 → 桌面：分享一张角色卡，桌面粘贴链接接收，卡内图片可导入插图。
10. 桌面 → 手机：分享一个模型连接，手机扫码接收后可直接生成。
11. 同一二维码再扫一次：提示分享已失效。
```

- [ ] **Step 4: 收尾检查**

Run（根目录）：格式检查命令（见 Global Constraints）、`flutter analyze`、`flutter test`；`cd packages/sillydraft_core && dart analyze && dart test`；`cd server && dart analyze && dart test`。
Expected: 全部通过。
