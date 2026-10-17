import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft/app/library_host.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'SillyDraft',
      packageName: 'com.moonrailgun.sillydraft',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );
  // A library with a data directory, so it can be shared.
  Future<AppServices> shareable([SecretStore? secrets]) async {
    final dir = await Directory.systemTemp.createTemp('sd-hosting');
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: secrets ?? MemorySecrets(),
      dataDirectory: dir,
    );
    addTearDown(() async {
      await services.close();
      await dir.delete(recursive: true);
    });
    return services;
  }

  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> expectClosed(int port) => expectLater(
    Socket.connect(InternetAddress.loopbackIPv4, port),
    throwsA(isA<SocketException>()),
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

  test(
    'switching saves drafts, remembers the desktop, closes the old',
    () async {
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
    },
  );

  test('a library shuts down even when its drafts cannot be saved', () async {
    final dir = await Directory.systemTemp.createTemp('sd-hosting');
    addTearDown(() => dir.delete(recursive: true));
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
    );
    await services.hosting.setEnabled(true, port: 0);
    final port = services.hosting.host!.port;
    services.registerDraft(
      Object(),
      () async => throw const RemoteUnavailable(),
    );
    await expectLater(services.close(), throwsA(isA<RemoteUnavailable>()));
    await expectClosed(port);
    await expectLater(
      services.repository.setSetting('x', {}),
      throwsStateError,
    );
  });

  test('a desktop that cannot be remembered is hung up', () async {
    final local = AppServices(
      repository: StoryRepository.memory(),
      secrets: _FailOnce('remote/paired'),
    );
    addTearDown(local.close);
    final other = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    final host = LibraryHost(local, openRemote: (_, _) async => other);
    await expectLater(
      host.openRemote(link),
      throwsA(isA<FileSystemException>()),
    );
    expect(host.services, same(local));
    await expectLater(other.repository.setSetting('x', {}), throwsStateError);
  });

  test('an old library that fails to close still switches', () async {
    final local = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    // Saved before the switch, then the desktop is gone for the close.
    var flushes = 0;
    local.registerDraft(Object(), () async {
      if (flushes++ > 0) throw const RemoteUnavailable();
    });
    final other = AppServices(
      repository: StoryRepository.memory(),
      secrets: local.secrets,
    );
    addTearDown(other.close);
    final host = LibraryHost(local, openRemote: (_, _) async => other);
    await host.openRemote(link);
    expect(host.services, same(other));
    await expectLater(local.repository.setSetting('x', {}), throwsStateError);
  });

  test(
    'drafts a dead desktop cannot take keep its library unless discarded',
    () async {
      final desktop = await shareable();
      await desktop.hosting.setEnabled(true, port: 0);
      final cache = await Directory.systemTemp.createTemp('sd-cache');
      addTearDown(() => cache.delete(recursive: true));
      final phone = AppServices.remote(
        await RemoteSession.connect(
          await desktop.hosting.link('127.0.0.1'),
          appVersion: '1.0.0+1',
        ),
        secrets: MemorySecrets(),
        cache: cache,
      );
      final draft = Object();
      phone.registerDraft(draft, () async => throw const RemoteUnavailable());
      addTearDown(() async {
        phone.unregisterDraft(draft);
        await phone.close();
      });
      final local = AppServices(
        repository: StoryRepository.memory(),
        secrets: phone.secrets,
      );
      addTearDown(local.close);
      final host = LibraryHost(phone, openLocal: () async => local);

      await expectLater(host.openLocal(), throwsA(isA<RemoteUnavailable>()));
      expect(host.services, same(phone));
      expect(await phone.repository.listNovels(), isEmpty);

      await host.openLocal(discardUnsaved: true);
      expect(host.services, same(local));
      await expectLater(phone.repository.listNovels(), throwsA(anything));
    },
  );

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

  test('a phone-written port cannot keep sharing or an old key', () async {
    final services = await shareable();
    await services.hosting.setEnabled(true, port: 0);
    final port = services.hosting.host!.port;
    final old = await services.hosting.link('127.0.0.1');
    // Settings are part of the shared database.
    Future<void> forge() => services.repository.setSetting('remoteHost', {
      'enabled': true,
      'port': 'oops',
    });
    await forge();
    await services.hosting.regenerateKey();
    expect(services.hosting.host?.port, port);
    await expectLater(
      RemoteSession.connect(old, appVersion: '1.0.0+1'),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 401),
      ),
    );
    await forge();
    await services.hosting.setEnabled(false);
    expect(services.hosting.host, isNull);
    expect((await services.hosting.settings())['enabled'], isFalse);
    await expectClosed(port);
  });

  test('turning sharing off right after on leaves nothing serving', () async {
    final services = await shareable();
    final port = await freePort();
    await Future.wait([
      services.hosting.setEnabled(true, port: port),
      services.hosting.setEnabled(false),
    ]);
    expect(services.hosting.host, isNull);
    expect((await services.hosting.settings())['enabled'], isFalse);
    await expectClosed(port);
  });

  test('stopping while sharing starts leaves nothing serving', () async {
    final services = await shareable();
    final port = await freePort();
    await Future.wait([
      services.hosting.setEnabled(true, port: port),
      services.hosting.stop(),
    ]);
    expect(services.hosting.host, isNull);
    await expectClosed(port);
  });

  test(
    'a share host that failed to start is retried; close completes',
    () async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: _FailOnce('remote/tls'),
      );
      final payload = SharePayload(kind: ShareKind.skill, name: '技能', data: {});
      await expectLater(
        services.hosting.offer(payload),
        throwsA(isA<FileSystemException>()),
      );
      final offered = await services.hosting.offer(payload);
      offered.ticket.close();
      await services.hosting.releaseShares();
      await expectClosed(offered.port);
      await services.close();
      await expectLater(
        services.repository.setSetting('x', {}),
        throwsStateError,
      );
    },
  );

  group('a saved key is bound to its endpoint', () {
    ModelConnection connection(String baseUrl) => ModelConnection(
      id: 'c1',
      name: '测试',
      baseUrl: baseUrl,
      model: 'm',
      kind: ModelKind.both,
    );
    final original = connection('https://api.example.com/v1');
    final moved = connection('https://attacker.example/v1');
    final throwsMoved = throwsA(
      isA<StateError>().having(
        (e) => e.message,
        'message',
        '连接地址已在本机之外改动，请重新输入密钥',
      ),
    );

    // What a paired phone can do over the shared database.
    Future<void> rewrite(AppServices services) =>
        services.repository.setSetting('connections', {
          'items': [moved.raw],
        });

    test('a connection moved in the database cannot use the key', () async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await services.saveConnection(original, apiKey: 'sk-test');
      await rewrite(services);
      await expectLater(services.provider(moved), throwsStateError);
      await expectLater(services.imageProvider(moved), throwsStateError);
      // The settings form sends the saved key only where it was saved; a
      // key typed into it goes anywhere.
      await expectLater(services.draftProvider(moved), throwsMoved);
      await expectLater(
        services.draftProvider(moved, secret: 'sk-typed'),
        completes,
      );
      expect(await services.endpointTrusted(moved), isFalse);
      await expectLater(services.provider(original), completes);
    });

    test('a new address takes a new key', () async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await services.saveConnection(original, apiKey: 'sk-test');
      await expectLater(services.saveConnection(moved), throwsMoved);
      await expectLater(services.provider(original), completes);
      await services.saveConnection(moved, apiKey: 'sk-new');
      await expectLater(services.provider(moved), completes);
      expect(await services.secrets.read('model/c1'), 'sk-new');
      await expectLater(services.provider(original), throwsStateError);
    });

    test('a saved key without a record needs retyping once shared', () async {
      final services = await shareable();
      await services.hosting.setEnabled(true, port: 0);
      await services.secrets.write('model/c1', 'sk-old');
      await expectLater(services.saveConnection(original), throwsMoved);
      await services.saveConnection(original, apiKey: 'sk-new');
      await expectLater(services.provider(original), completes);
    });

    test('untouched and never-shared connections are trusted', () async {
      final services = await shareable();
      await services.repository.setSetting('connections', {
        'items': [original.raw],
      });
      expect(await services.endpointTrusted(original), isTrue);
      await services.hosting.setEnabled(true, port: 0);
      expect(await services.endpointTrusted(original), isTrue);
      final added = ModelConnection(
        id: 'c2',
        name: '手机添加',
        baseUrl: 'https://attacker.example/v1',
        model: 'm',
      );
      expect(await services.endpointTrusted(added), isFalse);
    });

    test('older keys work, and are bound once sharing starts', () async {
      final dir = await Directory.systemTemp.createTemp('sd-binding');
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
        dataDirectory: dir,
      );
      addTearDown(() async {
        await services.close();
        await dir.delete(recursive: true);
      });
      await services.repository.setSetting('connections', {
        'items': [original.raw],
      });
      await services.secrets.write('model/c1', 'sk-old');
      await expectLater(services.provider(original), completes);

      await services.hosting.setEnabled(true, port: 0);
      expect(services.hosting.host, isNotNull);
      expect(await services.secrets.read('endpoint/c1'), isNotNull);
      await rewrite(services);
      await expectLater(services.provider(moved), throwsStateError);
      await expectLater(services.provider(original), completes);
    });

    test('removing a connection forgets its key and endpoint', () async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await services.saveConnection(original, apiKey: 'sk-test');
      await services.removeConnection('c1');
      expect(await services.secrets.read('model/c1'), isNull);
      expect(await services.secrets.read('endpoint/c1'), isNull);
    });

    test('a local tool rewritten in the database is refused', () async {
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      ModelConnection cli(String command) => ModelConnection(
        id: 'cli',
        name: 'Claude Code',
        baseUrl: '',
        model: 'sonnet',
        protocol: ModelProtocol.claudeCode,
        command: command,
      );
      await services.saveConnection(cli('/usr/local/bin/claude'));
      final changed = cli('/bin/sh');
      await services.repository.setSetting('connections', {
        'items': [changed.raw],
      });
      await expectLater(services.provider(changed), throwsStateError);
      await expectLater(
        services.provider(cli('/usr/local/bin/claude')),
        completes,
      );
    });

    test('once shared, only connections saved here are used', () async {
      final services = await shareable();
      await services.hosting.setEnabled(true, port: 0);
      // Added over the shared database, as a phone could.
      final added = ModelConnection(
        id: 'c2',
        name: '手机添加',
        baseUrl: 'https://attacker.example/v1',
        model: 'm',
      );
      await services.repository.setSetting('connections', {
        'items': [added.raw],
      });
      await expectLater(services.provider(added), throwsStateError);
      await services.saveConnection(original, apiKey: 'sk-test');
      await expectLater(services.provider(original), completes);
    });

    test('a connection named like the marker leaves it in place', () async {
      final services = await shareable();
      await services.hosting.setEnabled(true, port: 0);
      await services.saveConnection(
        ModelConnection(
          id: 'bound',
          name: '同名',
          baseUrl: 'https://api.example.com/v1',
          model: 'm',
        ),
      );
      await services.removeConnection('bound');
      final added = ModelConnection(
        id: 'c2',
        name: '手机添加',
        baseUrl: 'https://attacker.example/v1',
        model: 'm',
      );
      await services.repository.setSetting('connections', {
        'items': [added.raw],
      });
      await expectLater(services.provider(added), throwsStateError);
      expect(await services.secrets.read('remote/endpoints-bound'), isNotNull);
    });

    test('a phone leaves connections to the desktop', () async {
      final desktop = await shareable();
      await desktop.hosting.setEnabled(true, port: 0);
      final cache = await Directory.systemTemp.createTemp('sd-cache');
      final phone = AppServices.remote(
        await RemoteSession.connect(
          await desktop.hosting.link('127.0.0.1'),
          appVersion: '1.0.0+1',
        ),
        secrets: MemorySecrets(),
        cache: cache,
      );
      addTearDown(() async {
        await phone.close();
        await cache.delete(recursive: true);
      });
      await expectLater(phone.saveConnection(original), throwsStateError);
      await expectLater(phone.removeConnection('c1'), throwsStateError);
    });

    test('a phone never picks the desktop\'s local subscriptions', () async {
      final desktop = await shareable();
      await desktop.saveConnection(
        ModelConnection(
          id: 'cli',
          name: 'Claude Code',
          baseUrl: '',
          model: 'sonnet',
          protocol: ModelProtocol.claudeCode,
        ),
      );
      await desktop.saveConnection(original, apiKey: 'sk-test');
      await desktop.repository.setSetting('modelRoles', {'analysis': 'cli'});
      await desktop.hosting.setEnabled(true, port: 0);
      final cache = await Directory.systemTemp.createTemp('sd-cache');
      final phone = AppServices.remote(
        await RemoteSession.connect(
          await desktop.hosting.link('127.0.0.1'),
          appVersion: '1.0.0+1',
        ),
        secrets: MemorySecrets(),
        cache: cache,
      );
      addTearDown(() async {
        await phone.close();
        await cache.delete(recursive: true);
      });
      expect([for (final c in await phone.connections()) c.id], ['c1']);
      expect((await phone.connectionFor('analysis'))?.id, 'c1');
      expect((await desktop.connectionFor('analysis'))?.id, 'cli');
    });
  });

  test('a sharing setting a phone garbled still lets sharing start', () async {
    final services = await shareable();
    await services.hosting.setEnabled(true, port: 0);
    final phone = await RemoteSession.connect(
      await services.hosting.link('127.0.0.1'),
      appVersion: '1.0.0+1',
    );
    await phone.repository.listNovels();
    for (final value in ['[1]', 'oops']) {
      await phone.executor.runUpdate(
        "UPDATE app_settings SET value_json = ? WHERE key = 'remoteHost'",
        [value],
      );
      expect(await services.hosting.settings(), isEmpty);
    }
    await phone.close();
    await services.hosting.setEnabled(false);
    await services.hosting.setEnabled(true, port: 0);
    expect(services.hosting.host, isNotNull);
  });
}

/// Fails the first read of one key, as a locked secrets file would.
final class _FailOnce implements SecretStore {
  _FailOnce(this._key);
  String? _key;
  final _inner = MemorySecrets();

  @override
  Future<String?> read(String key) async {
    if (key == _key) {
      _key = null;
      throw const FileSystemException('密钥文件暂时无法读取');
    }
    return _inner.read(key);
  }

  @override
  Future<void> write(String key, String value) => _inner.write(key, value);

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
