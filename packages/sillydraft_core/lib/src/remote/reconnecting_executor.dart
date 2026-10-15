import 'package:drift/drift.dart';
// ConnectionClosedException is not exported; drift is pinned by the lock file.
// ignore: implementation_imports
import 'package:drift/src/remote/communication.dart'
    show ConnectionClosedException;

/// Thrown while a remote library cannot be reached.
final class RemoteUnavailable implements Exception {
  const RemoteUnavailable([this.reason = '与桌面断开，正在重连']);
  final String reason;
  @override
  String toString() => reason;
}

/// A database executor whose remote connection can be replaced: a phone's
/// repository, and every screen built on it, outlives a dropped link.
final class ReconnectingExecutor extends QueryExecutor {
  QueryExecutor? _current;
  QueryExecutorUser? _user;
  String _reason = const RemoteUnavailable().reason;

  /// Uses [executor] from now on, opened for the database already using
  /// this one.
  Future<void> attach(QueryExecutor executor) async {
    if (_user case final user?) await executor.ensureOpen(user);
    _current = executor;
  }

  /// Fails every call with [reason] until the next [attach].
  void detach([String? reason]) {
    _current = null;
    _reason = reason ?? const RemoteUnavailable().reason;
  }

  /// A call in flight when the link drops, or made just after it closed but
  /// before [detach], is the same outage as a detached call.
  Future<T> _run<T>(Future<T> Function(QueryExecutor live) call) =>
      _unavailable(() => call(_live));

  Future<T> _unavailable<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ConnectionClosedException {
      throw RemoteUnavailable(_reason);
    } on StateError catch (e) {
      if (e.message.contains('connection was closed')) {
        throw RemoteUnavailable(_reason);
      }
      rethrow;
    }
  }

  QueryExecutor get _live => _current ?? (throw RemoteUnavailable(_reason));

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) async {
    _user = user;
    return _run((live) => live.ensureOpen(user));
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) async => _run((live) => live.runSelect(statement, args));

  @override
  Future<int> runInsert(String statement, List<Object?> args) async =>
      _run((live) => live.runInsert(statement, args));

  @override
  Future<int> runUpdate(String statement, List<Object?> args) async =>
      _run((live) => live.runUpdate(statement, args));

  @override
  Future<int> runDelete(String statement, List<Object?> args) async =>
      _run((live) => live.runDelete(statement, args));

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) async =>
      _run((live) => live.runCustom(statement, args));

  @override
  Future<void> runBatched(BatchedStatements statements) async =>
      _run((live) => live.runBatched(statements));

  /// Statements in a transaction, which every repository write is, go to
  /// the live executor's own; they are mapped the same way.
  @override
  TransactionExecutor beginTransaction() =>
      _live.interceptWith(_Unavailable(this)).beginTransaction();

  @override
  QueryExecutor beginExclusive() =>
      _live.interceptWith(_Unavailable(this)).beginExclusive();

  @override
  Future<void> close() async {
    final current = _current;
    _current = null;
    await current?.close();
  }
}

/// [ReconnectingExecutor._unavailable] for transactions and exclusive
/// blocks, and for theirs in turn (the interceptor is sticky).
final class _Unavailable extends QueryInterceptor {
  _Unavailable(this._owner);
  final ReconnectingExecutor _owner;

  Future<T> _map<T>(Future<T> Function() call) => _owner._unavailable(call);

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      _map(() => executor.ensureOpen(user));

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _map(() => executor.runSelect(statement, args));

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _map(() => executor.runInsert(statement, args));

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _map(() => executor.runUpdate(statement, args));

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _map(() => executor.runDelete(statement, args));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) => _map(() => executor.runCustom(statement, args));

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => _map(() => executor.runBatched(statements));

  @override
  Future<void> commitTransaction(TransactionExecutor inner) => _map(inner.send);

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      _map(inner.rollback);

  @override
  Future<void> close(QueryExecutor inner) => _map(inner.close);
}
