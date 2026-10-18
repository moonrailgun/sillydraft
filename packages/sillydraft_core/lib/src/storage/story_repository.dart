import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
// drift 2.35.2 is pinned by the lock file; both ends ship the same build.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:uuid/uuid.dart';

import '../model/chapter_title.dart';
import '../model/manuscript.dart';
import '../model/manuscript_presentation.dart';
import '../model/story.dart';
import '../model/task.dart';
import '../model/bookmark.dart';
import '../model/resource.dart';
import '../model/lore.dart';
import '../model/asset.dart';
import '../model/persona.dart';
import '../model/usage.dart';
import '../model/display_context.dart';
import '../st/import_types.dart';
import '../st/card_importer.dart';
import '../st/preset_importer.dart';
import '../st/macro_engine.dart';
import '../st/world_book.dart';
import '../mvu/mvu_service.dart';
import '../providers/provider.dart';
import '../remote/sql_guard.dart';
import 'database.dart';
import '../transfer/project_snapshot.dart';
import '../transfer/manuscript_import.dart';

part 'manuscript_store.dart';
part 'branch_store.dart';
part 'proposal_store.dart';
part 'story_mappers.dart';
part 'task_store.dart';
part 'agent_store.dart';
part 'preferences_store.dart';
part 'resource_store.dart';
part 'lore_store.dart';
part 'lore_review_store.dart';
part 'variable_store.dart';
part 'card_start_store.dart';
part 'manuscript_import_store.dart';
part 'asset_store.dart';
part 'project_store.dart';
part 'display_store.dart';
part 'persona_store.dart';
part 'usage_store.dart';

/// All writable story state is committed here, independently of widget lifetime.
final class StoryRepository {
  StoryRepository._(this._db);
  factory StoryRepository.memory() => StoryRepository._(StoryDatabase.memory());
  factory StoryRepository.open(String path) =>
      StoryRepository._(StoryDatabase.open(path));

  /// A library another device serves: [executor] reaches a database that
  /// device opened and migrated. This side never migrates it.
  factory StoryRepository.connect(QueryExecutor executor) =>
      StoryRepository._(StoryDatabase(executor));

  final StoryDatabase _db;

  /// Each write, as whether it touched only generation tasks.
  final _changes = StreamController<bool>.broadcast();
  final _local = StreamController<bool>.broadcast();
  final _displayCache = <String, ({String key, DisplayContext context})>{};

  /// Listed task inputs by task id, cached once frozen for execution.
  final _listedInputs = <String, String>{};
  bool _closed = false;

  /// Every committed write.
  Stream<void> get changes => _changes.stream;

  /// Writes beyond generation tasks. A streamed chapter saves its task a few
  /// times a second; views that never read tasks need not reload for it.
  Stream<void> get contentChanges =>
      _changes.stream.where((tasksOnly) => !tasksOnly);

  /// This repository's own committed writes, as whether they touched only
  /// generation tasks: what a remote link forwards to other devices.
  Stream<bool> get localWrites => _local.stream;

  /// A write another device committed to the same database.
  void notifyExternal(bool tasksOnly) {
    if (!_closed) _changes.add(tasksOnly);
  }

  /// Serves this repository's database to remote devices, refusing SQL that
  /// reaches past it. Shutting the server down leaves the database open;
  /// [close] closes it.
  DriftServer remoteServer() => DriftServer(
    _db.executor.interceptWith(RemoteSqlGuard()),
    closeConnectionAfterShutdown: false,
  );

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _db.close();
    await _changes.close();
    await _local.close();
  }

  Future<T> _write<T>(
    Future<T> Function() action, {
    bool tasksOnly = false,
  }) async {
    if (_closed) throw StateError('资料库已关闭。');
    final result = await _db.transaction(action);
    _changes.add(tasksOnly);
    _local.add(tasksOnly);
    return result;
  }

  Future<List<Map<String, Object?>>> _rows(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final rows = await _db.customSelect(sql, variables: _variables(args)).get();
    return rows
        .map((r) => r.data.cast<String, Object?>())
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _one(
    String sql,
    List<Object?> args,
    String entity,
  ) async {
    final rows = await _rows(sql, args);
    if (rows.isEmpty) throw StoryNotFound(entity);
    return rows.single;
  }

  Future<void> _execute(String sql, [List<Object?> args = const []]) =>
      _db.customStatement(sql, args);

  Future<void> _touchNovel(String novelId) => _execute(
    'UPDATE novels SET updated_at = ? WHERE id = ?',
    [_now(), novelId],
  );

  Future<Novel> createNovel({
    required String title,
    String synopsis = '',
    String genre = '自由创作',
    String language = 'zh',
    String style = '',
    String pointOfView = '第三人称',
    ChapterNumerals chapterNumerals = ChapterNumerals.chinese,
  }) => _write(() async {
    _validateTitle(title);
    final id = _id();
    final branchId = _id();
    final now = _now();
    await _execute(
      '''INSERT INTO novels
      (id, title, synopsis, genre, language, style, point_of_view,
       active_branch_id, chapter_numerals, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        title.trim(),
        synopsis,
        genre,
        language,
        style,
        pointOfView,
        branchId,
        chapterNumerals.name,
        now,
        now,
      ],
    );
    await _execute(
      'INSERT INTO branches (id, novel_id, name, created_at) VALUES (?, ?, ?, ?)',
      [branchId, id, '主线', now],
    );
    return getNovel(id);
  });

  Future<Novel> getNovel(String id) async =>
      _novel(await _one('SELECT * FROM novels WHERE id = ?', [id], '小说'));

  Future<List<Novel>> listNovels({
    bool includeArchived = false,
    String query = '',
  }) async {
    final rows = await _rows(
      '''SELECT * FROM novels
      WHERE (? = 1 OR archived = 0)
      AND (? = '' OR instr(lower(title), lower(?)) > 0 OR instr(lower(synopsis), lower(?)) > 0)
      ORDER BY updated_at DESC, id''',
      [includeArchived ? 1 : 0, query.trim(), query.trim(), query.trim()],
    );
    return rows.map(_novel).toList(growable: false);
  }

  Future<Novel> updateNovel(Novel novel) => _write(() async {
    _validateTitle(novel.title);
    final branch = await getBranch(novel.activeBranchId);
    if (branch.novelId != novel.id) throw const StoryNotFound('小说分支');
    await getNovel(novel.id);
    await _execute(
      '''UPDATE novels SET title = ?, synopsis = ?, genre = ?,
      language = ?, style = ?, point_of_view = ?, active_branch_id = ?,
      cover_asset_id = ?, archived = ?, chapter_numerals = ?, updated_at = ?
      WHERE id = ?''',
      [
        novel.title.trim(),
        novel.synopsis,
        novel.genre,
        novel.language,
        novel.style,
        novel.pointOfView,
        novel.activeBranchId,
        novel.coverAssetId,
        novel.archived ? 1 : 0,
        novel.chapterNumerals.name,
        _now(),
        novel.id,
      ],
    );
    return getNovel(novel.id);
  });

  Future<void> archiveNovel(String id, {required bool archived}) =>
      _write(() async {
        await getNovel(id);
        await _execute(
          'UPDATE novels SET archived = ?, updated_at = ? WHERE id = ?',
          [archived ? 1 : 0, _now(), id],
        );
      });

  Future<StorySnapshot> getStory(String branchId) => _db.transaction(() async {
    final branch = await getBranch(branchId);
    final chapters = await _rows(
      '$_chapterQuery ORDER BY c.position, c.chapter_id',
      [branchId],
    );
    return StorySnapshot(
      novel: await getNovel(branch.novelId),
      branch: branch,
      chapters: chapters.map(_chapter).toList(),
    );
  });

  /// One branch's chapters (`c`) with their place in the numbering, then
  /// their content. Filter on `c` from outside: the count still covers the
  /// whole branch, and only the chapters kept have their content read.
  static const _chapterQuery = '''SELECT c.*, r.content_json FROM (
      SELECT s.*, n.chapter_numerals,
        CASE WHEN s.numbered = 1 THEN sum(s.numbered)
          OVER (ORDER BY s.position, s.chapter_id) END AS number
      FROM branch_chapters s
      JOIN branches b ON b.id = s.branch_id
      JOIN novels n ON n.id = b.novel_id
      WHERE s.branch_id = ?
    ) c JOIN revisions r ON r.id = c.revision_id''';
}

String _id() => const Uuid().v4();
int _now() => DateTime.now().toUtc().millisecondsSinceEpoch;
void _validateTitle(String title) {
  if (title.trim().isEmpty) throw ArgumentError('名称不能为空。');
}

List<Variable<Object>> _variables(List<Object?> values) => values
    .map<Variable<Object>>((value) {
      return switch (value) {
        String v => Variable<String>(v),
        int v => Variable<int>(v),
        double v => Variable<double>(v),
        bool v => Variable<bool>(v),
        null => const Variable<String>(null),
        _ => throw ArgumentError('不支持的数据库参数类型。'),
      };
    })
    .toList(growable: false);
