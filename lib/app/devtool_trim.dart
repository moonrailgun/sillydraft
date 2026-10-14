// The fix needs Riverpod's own debug history, which it keeps internal.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/src/internals.dart'
    show ProviderElementUpdateEvent, RiverpodDevtool;

/// Debug builds of Riverpod 3.4.3 record every provider state for the
/// Riverpod DevTools extension (`RiverpodDevtool.frames`) and never drop
/// one, so a long session keeps every task list and story it ever read.
/// This drops the update events, which carry those states, from all but the
/// last [keep] frames. Frames and their add and dispose events stay, so the
/// extension still rebuilds the provider tree and its offsets line up; a
/// provider not updated within [keep] frames shows its first state there.
///
/// Remove once Riverpod bounds that history itself.
final class DevtoolHistoryTrim extends ProviderObserver {
  DevtoolHistoryTrim({this.keep = 100});
  final int keep;
  int _trimmed = 0;

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final frames = RiverpodDevtool.instance.frames;
    for (; _trimmed < frames.length - keep; _trimmed++) {
      frames[_trimmed].events.removeWhere(
        (e) => e is ProviderElementUpdateEvent,
      );
    }
  }
}
