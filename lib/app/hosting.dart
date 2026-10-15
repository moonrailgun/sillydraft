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
  RemoteHost? _host, _shareHost;
  Future<TlsIdentity>? _identity;
  Object? _error;
  Future<void> _queue = Future.value();

  /// Starting, stopping and handing out shares run one at a time, so no
  /// host outlives the call that turned sharing off.
  Future<T> _serial<T>(Future<T> Function() task) {
    final next = _queue.then((_) => task());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  RemoteHost? get host => _host;

  /// Why sharing could not start, until the next attempt.
  Object? get error => _error;

  /// Phones can write the setting, so anything but an object reads as
  /// nothing saved rather than keeping sharing from starting.
  Future<Map<String, dynamic>> settings() async {
    try {
      return await services.repository.getSetting('remoteHost') ?? const {};
    } on FormatException {
      return const {};
    } on TypeError {
      return const {};
    }
  }

  Future<TlsIdentity> identity() =>
      _identity ??= _loadIdentity().catchError((Object e) {
        _identity = null;
        throw e;
      });

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
  Future<void> restore() => _serial(() async {
    try {
      if ((await settings())['enabled'] == true) await _setEnabled(true);
    } catch (e) {
      _error = e;
      notifyListeners();
    }
  });

  /// Starts or stops sharing. A port in use leaves sharing off, saved as
  /// off, with [error] saying why.
  Future<void> setEnabled(bool enabled, {int? port}) =>
      _serial(() => _setEnabled(enabled, port: port));

  Future<void> _setEnabled(bool enabled, {int? port}) async {
    // Stop first: the settings are phone-writable, and nothing read from
    // them may keep the old host (and its key) serving.
    await _host?.close();
    _host = null;
    _error = null;
    final saved = (await settings())['port'];
    final nextPort =
        port ??
        (saved is int && saved > 0 && saved < 65536
            ? saved
            : defaultRemotePort);
    if (enabled) {
      try {
        await services.bindSavedEndpoints();
        _host = await RemoteHost.start(
          identity: await identity(),
          name: Platform.localHostname,
          appVersion: await appVersionString(),
          port: nextPort,
          library: LibraryAccess(
            accessKey: await accessKey(),
            repository: services.repository,
            tasks: services.runner,
            assets: services.assets ?? (throw StateError('本地资源目录尚未就绪')),
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

  /// Every paired phone must scan the new link afterwards. Sharing stays
  /// on the port it runs on.
  Future<void> regenerateKey() => _serial(() async {
    await services.secrets.write('remote/access-key', randomSecret());
    if (_host case final host?) await _setEnabled(true, port: host.port);
  });

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
  ) => _serial(() async {
    // Assigned only once started: a failed start is retried next time.
    final host = _host ?? (_shareHost ??= await _startShareHost());
    return (
      ticket: host.shares.open(payload),
      port: host.port,
      fingerprint: (await identity()).fingerprint,
    );
  });

  Future<RemoteHost> _startShareHost() async => RemoteHost.start(
    identity: await identity(),
    name: Platform.localHostname,
    appVersion: await appVersionString(),
    port: 0,
  );

  /// Stops the share-only host once no share is open.
  Future<void> releaseShares() => _serial(() async {
    final host = _shareHost;
    if (host == null || !host.shares.isEmpty) return;
    _shareHost = null;
    await host.close();
  });

  Future<void> stop() => _serial(() async {
    final library = _host, share = _shareHost;
    _host = _shareHost = null;
    await library?.close();
    await share?.close();
  });
}
