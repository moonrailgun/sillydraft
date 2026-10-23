import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/screen_awake.dart';

void main() {
  test('readers and tasks release only their own wake request', () async {
    final calls = <bool>[];
    final awake = ScreenAwake((enabled) async => calls.add(enabled));
    final reader = Object(), tasks = Object();
    await awake.set(reader, true);
    await awake.set(tasks, true);
    await awake.set(reader, false);
    expect(calls, [true]);
    await awake.set(tasks, false);
    expect(calls, [true, false]);
  });

  test('platform requests stay ordered and recover after failure', () async {
    final first = Completer<void>();
    final calls = <bool>[];
    final awake = ScreenAwake((enabled) async {
      calls.add(enabled);
      if (calls.length == 1) await first.future;
    });
    final owner = Object();
    final enabled = awake.set(owner, true);
    final disabled = awake.set(owner, false);
    await Future<void>.delayed(Duration.zero);
    expect(calls, [true]);
    first.completeError(StateError('platform unavailable'));
    await enabled;
    await disabled;
    expect(calls, [true, false]);
    await awake.set(owner, true);
    await awake.refresh();
    expect(calls, [true, false, true, true]);
  });
}
