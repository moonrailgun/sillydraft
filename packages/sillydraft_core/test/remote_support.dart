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

  /// [accessKey] and [identity] stand in for a desktop that re-keyed or
  /// changed its certificate since the phone paired; [tasks] replaces the
  /// runner the host hands tasks to.
  Future<void> startHost({
    String appVersion = testVersion,
    String? accessKey,
    TlsIdentity? identity,
    TaskControl? tasks,
  }) async {
    host = await RemoteHost.start(
      identity: identity ?? testIdentity,
      name: '测试桌面',
      appVersion: appVersion,
      address: InternetAddress.loopbackIPv4,
      port: _port,
      library: LibraryAccess(
        accessKey: accessKey ?? key,
        repository: repository,
        tasks: tasks ?? runner,
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
