import 'package:drift/drift.dart';

/// What a paired device may run on the desktop's database: anything the
/// repository sends, but nothing that reaches past the library file. drift's
/// server runs whatever SQL a client sends, and `ATTACH` alone would create
/// or read a SQLite file anywhere the desktop can write.
final class RemoteSqlGuard extends QueryInterceptor {
  /// The pragmas the repository issues: StoryDatabase's beforeOpen, then
  /// project_store's imports.
  static const _pragmas = {
    'foreign_keys',
    'busy_timeout',
    'journal_mode',
    'defer_foreign_keys',
    'foreign_key_check',
    'table_info',
  };
  static final _refused = RegExp(
    r'\b(attach|detach|vacuum|load_extension)\b',
    caseSensitive: false,
  );

  /// A pragma's name, when it is a plain one: a schema-qualified or quoted
  /// name leaves the group empty and is refused.
  static final _pragma = RegExp(
    r'\bpragma\b(?:\s*(\w+)\s*(?=[=(;]|$))?',
    caseSensitive: false,
  );

  static void _check(String sql) {
    final code = _code(sql);
    if (_refused.hasMatch(code) ||
        _pragma
            .allMatches(code)
            .any((m) => !_pragmas.contains(m[1]?.toLowerCase()))) {
      throw UnsupportedError('远程连接不能执行此语句');
    }
  }

  /// [sql] with string literals and comments blanked as SQLite tokenizes
  /// them. Quoted identifiers are kept whole: a quote or dash inside one
  /// opens nothing, and a keyword spelled inside one is still refused.
  static String _code(String sql) {
    final out = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final c = sql[i];
      final close = switch (c) {
        "'" || '"' || '`' => c,
        '[' => ']',
        _ => null,
      };
      if (close != null) {
        var end = sql.indexOf(close, i + 1);
        // A doubled quote is one quote inside the token.
        while (close != ']' &&
            end != -1 &&
            end + 1 < sql.length &&
            sql[end + 1] == close) {
          end = sql.indexOf(close, end + 2);
        }
        // Unterminated: SQLite rejects the token, so none of it runs.
        if (end == -1) end = sql.length - 1;
        out.write(c == "'" ? ' ' : sql.substring(i, end + 1));
        i = end + 1;
      } else if (sql.startsWith('--', i)) {
        final end = sql.indexOf('\n', i);
        i = end == -1 ? sql.length : end;
        out.write(' ');
      } else if (sql.startsWith('/*', i)) {
        // SQLite lets an unterminated block comment run to the end.
        final end = sql.indexOf('*/', i + 2);
        i = end == -1 ? sql.length : end + 2;
        out.write(' ');
      } else {
        out.write(c);
        i++;
      }
    }
    return '$out';
  }

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      executor.ensureOpen(_GuardedUser(user, this));

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    statements.statements.forEach(_check);
    return executor.runBatched(statements);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    return executor.runCustom(statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    return executor.runInsert(statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    return executor.runUpdate(statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    return executor.runDelete(statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    _check(statement);
    return executor.runSelect(statement, args);
  }
}

/// The executor a first open hands to migrations is guarded too.
final class _GuardedUser implements QueryExecutorUser {
  _GuardedUser(this._user, this._guard);
  final QueryExecutorUser _user;
  final RemoteSqlGuard _guard;

  @override
  int get schemaVersion => _user.schemaVersion;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) =>
      _user.beforeOpen(executor.interceptWith(_guard), details);
}
