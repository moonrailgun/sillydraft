import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

/// Delays one real database read so a widget can be edited during preparation.
class QueryGate extends QueryInterceptor {
  bool Function(String)? _match;
  Completer<void>? _blocked, _release;

  void arm(bool Function(String) match) {
    _match = match;
    _blocked = Completer<void>();
    _release = Completer<void>();
  }

  void release() {
    if (_release case final release? when !release.isCompleted) {
      release.complete();
    }
  }

  Future<void> waitUntilBlocked(WidgetTester tester) async {
    for (var i = 0; i < 100 && !_blocked!.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(_blocked!.isCompleted, isTrue, reason: 'query delay reached');
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_match?.call(statement) == true) {
      _match = null;
      _blocked!.complete();
      await _release!.future;
    }
    return executor.runSelect(statement, args);
  }
}
