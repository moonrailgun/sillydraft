import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class PlatformSecrets implements SecretStore {
  final _storage = Platform.isMacOS
      ? const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        )
      : const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// For isolated tests only. The production entry point always uses keychain /
/// keystore storage and never falls back to this on a secure-storage error.
final class MemorySecrets implements SecretStore {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

final class AppServices {
  AppServices({
    required this.repository,
    required this.secrets,
    this.dataDirectory,
    ProviderFactory? modelProviderFactory,
    ImageProviderFactory? imageProviderFactory,
  }) {
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
    writing = WritingService(repository: repository, runner: runner);
    editor = EditorAgent(repository: repository, runner: runner);
    illustrations = IllustrationService(repository: repository, runner: runner);
    library = ResourceLibrary(
      repository: repository,
      keyProvider: _resourceKey,
    );
  }
  final StoryRepository repository;
  final SecretStore secrets;
  final Directory? dataDirectory;
  late final TaskRunner runner;
  late final WritingService writing;
  late final EditorAgent editor;
  late final ResourceLibrary library;
  late final AssetLibrary? assets;
  late final IllustrationService illustrations;
  ProjectBackup get backups => ProjectBackup(
    repository: repository,
    assets: assets ?? (throw StateError('本地资源目录尚未就绪')),
    resources: library,
  );
  PublicationExporter get publications => PublicationExporter(
    repository: repository,
    assets: assets ?? (throw StateError('本地资源目录尚未就绪')),
  );
  Future<List<int>>? _keyFuture;
  Future<List<int>> _resourceKey() => _keyFuture ??= _loadResourceKey();
  Future<List<int>> _loadResourceKey() async {
    try {
      final existing = await secrets.read('resources/aes256');
      if (existing != null) return base64Decode(existing);
      final random = Random.secure();
      final key = List.generate(32, (_) => random.nextInt(256));
      await secrets.write('resources/aes256', base64Encode(key));
      return key;
    } catch (_) {
      _keyFuture = null;
      rethrow;
    }
  }

  final _drafts = <Object, Future<void> Function()>{};

  static Future<AppServices> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final services = AppServices(
      repository: StoryRepository.open('${dir.path}/library.sqlite'),
      secrets: PlatformSecrets(),
      dataDirectory: dir,
    );
    await services.runner.recoverInterrupted();
    try {
      await services.assets?.pruneOrphans();
    } on FileSystemException {
      // Maintenance failure must not prevent access to saved manuscripts.
      stderr.writeln(
        'SillyDraft: unused asset cleanup failed; will retry on next launch.',
      );
    }
    return services;
  }

  Future<ModelProvider> provider(ModelConnection connection) async {
    if (connection.protocol == ModelProtocol.sillyDraftRunner) {
      return RemoteModelProvider(
        config: connection,
        accessToken: await secrets.read('model/${connection.id}') ?? '',
      );
    }
    if (connection.protocol != ModelProtocol.openAICompatible) {
      throw const FormatException('当前版本支持 OpenAI 兼容接口，请使用兼容端点');
    }
    return OpenAICompatibleProvider(
      config: connection,
      apiKey: await secrets.read('model/${connection.id}') ?? '',
    );
  }

  Future<ImageProvider> imageProvider(ModelConnection connection) async {
    final key = await secrets.read('model/${connection.id}') ?? '';
    if (connection.protocol == ModelProtocol.sillyDraftRunner) {
      return RemoteImageProvider(config: connection, accessToken: key);
    }
    return OpenAIImageProvider(config: connection, apiKey: key);
  }

  Future<List<ModelConnection>> connections() async {
    final setting = await repository.getSetting('connections');
    return (setting?['items'] as List? ?? [])
        .map((v) => ModelConnection.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveConnection(
    ModelConnection connection, {
    String? apiKey,
  }) async {
    if (apiKey != null) await secrets.write('model/${connection.id}', apiKey);
    final list = await connections();
    list.removeWhere((c) => c.id == connection.id);
    list.add(connection);
    await repository.setSetting('connections', {
      'items': list.map((c) => c.raw).toList(),
    });
  }

  Future<void> removeConnection(String id) async {
    final list = await connections();
    list.removeWhere((c) => c.id == id);
    await repository.setSetting('connections', {
      'items': list.map((c) => c.raw).toList(),
    });
    await secrets.delete('model/$id');
  }

  Future<ModelConnection?> connectionFor(String role) async {
    final all = (await connections())
        .where(
          (c) =>
              role != 'editor' || c.protocol == ModelProtocol.openAICompatible,
        )
        .toList();
    if (all.isEmpty) return null;
    final roles = await repository.getSetting('modelRoles');
    return all.where((c) => c.id == roles?[role]).firstOrNull ?? all.first;
  }

  void registerDraft(Object owner, Future<void> Function() flush) =>
      _drafts[owner] = flush;
  void unregisterDraft(Object owner) => _drafts.remove(owner);
  Future<void> flushDrafts() async {
    for (final flush in _drafts.values.toList()) {
      await flush();
    }
  }

  Future<void> close() async {
    await flushDrafts();
    await runner.close();
    await repository.close();
  }
}

final servicesProvider = Provider<AppServices>(
  (ref) => throw StateError('AppServices not initialized'),
);
final repositoryProvider = Provider<StoryRepository>(
  (ref) => ref.watch(servicesProvider).repository,
);
final repositoryChangesProvider = StreamProvider<int>((ref) {
  // Riverpod compares stream values. Repeated void/null events are equal and
  // would leave query providers cached after the first database change.
  var revision = 0;
  return ref.watch(repositoryProvider).changes.map((_) => ++revision);
});
final novelsProvider = FutureProvider<List<Novel>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listNovels(includeArchived: true);
});
final storyProvider = FutureProvider.family<StorySnapshot, String>((
  ref,
  branchId,
) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getStory(branchId);
});
final settingProvider = FutureProvider.family<Map<String, dynamic>?, String>((
  ref,
  key,
) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getSetting(key);
});
