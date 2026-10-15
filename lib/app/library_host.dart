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

  /// Entries that no longer parse are skipped rather than hiding the rest;
  /// a value that is no list holds none.
  Future<List<ConnectLink>> list() async {
    final saved = await secrets.read(_key);
    Object? entries;
    try {
      entries = saved == null ? null : jsonDecode(saved);
    } on FormatException {
      entries = null;
    }
    return [
      if (entries is List)
        for (final text in entries) ?_parse(text),
    ];
  }

  static ConnectLink? _parse(Object? text) {
    try {
      return SillyDraftLink.parse(text as String) as ConnectLink;
    } catch (_) {
      return null;
    }
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
    try {
      await PairedDesktops(current.secrets).save(link);
    } catch (_) {
      await next.close();
      rethrow;
    }
    await _replace(next);
  }

  /// Back to this device's own library. Unsaved drafts go to the desktop
  /// first, and a failure keeps its library open, unless [discardUnsaved]
  /// drops them.
  Future<void> openLocal({bool discardUnsaved = false}) async {
    if (_services.remote == null) return;
    if (!discardUnsaved) await _services.flushDrafts();
    await _replace(await _openLocal(), flushDrafts: !discardUnsaved);
  }

  Future<void> _replace(AppServices next, {bool flushDrafts = true}) async {
    final previous = _services;
    _services = next;
    notifyListeners();
    // The new scope rebuilds from scratch; queries the old screens still
    // had in flight fail quietly into disposed providers. The switch is
    // done, so a failing close (say a desktop gone since the flush) is only
    // reported.
    try {
      await previous.close(flushDrafts: flushDrafts);
    } catch (e) {
      debugPrint('SillyDraft: closing the previous library failed: $e');
    }
  }

  static Future<AppServices> _connect(
    ConnectLink link,
    AppServices current,
  ) async {
    final session = await RemoteSession.connect(
      link,
      appVersion: await appVersionString(),
    );
    try {
      final cache = Directory(
        '${(await getApplicationCacheDirectory()).path}/remote/${link.fingerprint}',
      );
      return AppServices.remote(
        session,
        secrets: current.secrets,
        cache: cache,
        updateEndpoint: current.updateEndpoint,
      );
    } catch (_) {
      await session.close();
      rethrow;
    }
  }
}

final libraryHostProvider = Provider<LibraryHost>(
  (ref) => throw StateError('LibraryHost not initialized'),
);
