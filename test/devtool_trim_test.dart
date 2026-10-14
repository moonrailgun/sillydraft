// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/src/internals.dart'
    show
        Frame,
        ProviderElementAddEvent,
        ProviderElementUpdateEvent,
        RiverpodDevtool;
import 'package:sillydraft/app/devtool_trim.dart';

final class _Counter extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final _counter = NotifierProvider<_Counter, int>(_Counter.new);

void main() {
  test('debug history drops old updates and keeps the provider tree', () async {
    final container = ProviderContainer(
      observers: [DevtoolHistoryTrim(keep: 5)],
    );
    addTearDown(container.dispose);
    container.listen(_counter, (_, _) {});
    for (var i = 0; i < 40; i++) {
      container.read(_counter.notifier).bump();
      await Future<void>.delayed(Duration.zero);
    }
    final frames = RiverpodDevtool.instance.frames;
    bool updates(Frame f) =>
        f.events.any((e) => e is ProviderElementUpdateEvent);
    expect(frames.length, greaterThan(30));
    // Old frames stay in place, so offsets hold, but lose their states.
    expect(frames.reversed.skip(6).any(updates), isFalse);
    expect(frames.reversed.take(5).every(updates), isTrue);
    expect(
      frames.first.events.whereType<ProviderElementAddEvent>(),
      isNotEmpty,
    );
  });
}
