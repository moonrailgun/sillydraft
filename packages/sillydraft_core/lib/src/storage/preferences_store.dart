part of 'story_repository.dart';

extension PreferenceOperations on StoryRepository {
  Future<Map<String, dynamic>?> getSetting(String key) async {
    final json = await _settingJson(key);
    return json == null ? null : jsonDecode(json) as Map<String, dynamic>;
  }

  Future<String?> _settingJson(String key) async {
    final rows = await _rows(
      'SELECT value_json FROM app_settings WHERE key = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.single['value_json'] as String;
  }

  Future<void> setSetting(String key, Map<String, dynamic> value) =>
      _write(() async {
        if (jsonEncode(value) != jsonEncode(redactCredentials(value))) {
          throw ArgumentError('凭据只能存入本机密钥文件，不能写进设置');
        }
        await _execute(
          'INSERT INTO app_settings (key,value_json) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json',
          [key, jsonEncode(value)],
        );
      });

  Future<void> removeSetting(String key) =>
      _write(() => _execute('DELETE FROM app_settings WHERE key = ?', [key]));

  Future<void> setReadingProgress({
    required String branchId,
    required String chapterId,
    required double fraction,
  }) async {
    await getChapter(branchId: branchId, chapterId: chapterId);
    if (!fraction.isFinite) throw ArgumentError('阅读进度无效');
    await setSetting('progress/$branchId', {
      'chapterId': chapterId,
      'fraction': fraction.clamp(0, 1),
      'updatedAt': _now(),
    });
  }

  Future<Map<String, dynamic>?> getReadingProgress(String branchId) =>
      getSetting('progress/$branchId');

  Future<ReadingBookmark> addBookmark({
    required String branchId,
    required String chapterId,
    String label = '',
    int offset = 0,
  }) => _write(() async {
    final chapter = await getChapter(branchId: branchId, chapterId: chapterId);
    final id = _id(), now = _now();
    final position = offset.clamp(0, chapter.content.text.length);
    await _execute(
      'INSERT INTO reading_bookmarks (id,branch_id,chapter_id,label,offset,created_at) VALUES (?,?,?,?,?,?)',
      [id, branchId, chapterId, label, position, now],
    );
    return ReadingBookmark(
      id: id,
      branchId: branchId,
      chapterId: chapterId,
      label: label,
      offset: position,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
    );
  });

  Future<List<ReadingBookmark>> listBookmarks(String branchId) async =>
      (await _rows(
            'SELECT * FROM reading_bookmarks WHERE branch_id = ? ORDER BY created_at DESC',
            [branchId],
          ))
          .map(
            (r) => ReadingBookmark(
              id: r['id'] as String,
              branchId: r['branch_id'] as String,
              chapterId: r['chapter_id'] as String,
              label: r['label'] as String,
              offset: r['offset'] as int,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                r['created_at'] as int,
                isUtc: true,
              ),
            ),
          )
          .toList();

  Future<void> removeBookmark(String id) => _write(
    () => _execute('DELETE FROM reading_bookmarks WHERE id = ?', [id]),
  );
}
