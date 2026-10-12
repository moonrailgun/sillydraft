import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../model/manuscript.dart';
import '../model/story.dart';
import '../model/task.dart';
import '../model/bookmark.dart';
import '../st/import_types.dart';
import 'database.dart';

part 'manuscript_store.dart';
part 'branch_store.dart';
part 'proposal_store.dart';
part 'story_mappers.dart';
part 'task_store.dart';
part 'agent_store.dart';
part 'preferences_store.dart';

/// All writable story state is committed here, independently of widget lifetime.
final class StoryRepository {
  StoryRepository._(this._db);
  factory StoryRepository.memory() => StoryRepository._(StoryDatabase.memory());
  factory StoryRepository.open(String path) =>
      StoryRepository._(StoryDatabase.open(path));

  final StoryDatabase _db;
  final _changes = StreamController<void>.broadcast();
  bool _closed = false;
  Stream<void> get changes => _changes.stream;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _db.close();
    await _changes.close();
  }

  Future<T> _write<T>(Future<T> Function() action) async {
    if (_closed) throw StateError('资料库已关闭。');
    final result = await _db.transaction(action);
    _changes.add(null);
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
  }) => _write(() async {
    _validateTitle(title);
    final id = _id();
    final branchId = _id();
    final now = _now();
    await _execute(
      '''INSERT INTO novels
      (id, title, synopsis, genre, language, style, point_of_view,
       active_branch_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        title.trim(),
        synopsis,
        genre,
        language,
        style,
        pointOfView,
        branchId,
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
      cover_asset_id = ?, archived = ?, updated_at = ? WHERE id = ?''',
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
      'SELECT * FROM branch_chapters WHERE branch_id = ? ORDER BY position, chapter_id',
      [branchId],
    );
    final scenes = await _rows(
      '$_sceneQuery WHERE s.branch_id = ? ORDER BY c.position, s.position, s.scene_id',
      [branchId],
    );
    return StorySnapshot(
      novel: await getNovel(branch.novelId),
      branch: branch,
      chapters: chapters.map(_chapter).toList(),
      scenes: scenes.map(_scene).toList(),
    );
  });

  static const _sceneQuery = '''SELECT s.*, r.content_json FROM branch_scenes s
    JOIN revisions r ON r.id = s.revision_id
    JOIN branch_chapters c ON c.branch_id = s.branch_id AND c.chapter_id = s.chapter_id''';
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
