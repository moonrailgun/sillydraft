import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

final screenAwakeProvider = Provider<ScreenAwake>((ref) => ScreenAwake());

class ScreenAwake {
  ScreenAwake([Future<void> Function(bool)? toggle])
    : _toggle = toggle ?? ((on) => WakelockPlus.toggle(enable: on));
  final Future<void> Function(bool) _toggle;
  final _owners = <Object>{};
  Future<void> _pending = Future.value();

  Future<void> set(Object owner, bool enabled) {
    final wasEnabled = _owners.isNotEmpty;
    enabled ? _owners.add(owner) : _owners.remove(owner);
    return wasEnabled == _owners.isNotEmpty ? _pending : refresh();
  }

  /// Reapply on resume: the OS may release a screen wake lock in the background.
  Future<void> refresh() {
    final enabled = _owners.isNotEmpty;
    return _pending = _pending.then((_) => _toggle(enabled)).catchError((
      Object e,
    ) {
      debugPrint('Unable to keep screen awake: $e');
    });
  }
}
