part of 'story_repository.dart';

// Original attachments are fetched separately by encryptedResourceSource.
const _resourceColumns =
    'id, kind, name, filename, source_hash, data_json, parent_id, archived, created_at';

extension ResourceOperations on StoryRepository {
  Future<LibraryResource> storeResource({
    required String id,
    required ResourceKind kind,
    required String name,
    required String filename,
    required String sourceHash,
    required Map<String, dynamic> data,
    required List<int> encryptedSource,
    String? parentId,
  }) => _write(() async {
    if (parentId != null && (await getResource(parentId)).kind != kind) {
      throw ArgumentError('资源类型不能改变');
    }
    await _execute(
      '''INSERT INTO library_resources
        (id,kind,name,filename,source_hash,data_json,encrypted_source,parent_id,created_at)
        VALUES (?,?,?,?,?,?,?,?,?)''',
      [
        id,
        kind.name,
        name,
        filename,
        sourceHash,
        jsonEncode(redactCredentials(data)),
        Uint8List.fromList(encryptedSource),
        parentId,
        _now(),
      ],
    );
    return getResource(id);
  });

  Future<LibraryResource> getResource(String id) async => _resource(
    await _one('SELECT $_resourceColumns FROM library_resources WHERE id = ?', [
      id,
    ], '创作资源'),
  );
  Future<List<LibraryResource>> listResources({
    ResourceKind? kind,
    bool includeArchived = false,
  }) async => (await _rows(
    '''SELECT $_resourceColumns FROM library_resources WHERE (? = 1 OR archived = 0)
      AND (? IS NULL OR kind = ?) ORDER BY created_at DESC, id''',
    [includeArchived ? 1 : 0, kind?.name, kind?.name],
  )).map(_resource).toList();
  Future<Uint8List> encryptedResourceSource(String id) async =>
      Uint8List.fromList(
        (await _one(
              'SELECT encrypted_source FROM library_resources WHERE id = ?',
              [id],
              '创作资源',
            ))['encrypted_source']
            as List<int>,
      );
  Future<void> archiveResource(String id, {required bool archived}) =>
      _write(() async {
        await getResource(id);
        await _execute(
          'UPDATE library_resources SET archived = ? WHERE id = ?',
          [archived ? 1 : 0, id],
        );
      });
}

LibraryResource _resource(Map<String, Object?> r) =>
    LibraryResource.fromStoredJson(
      id: r['id'] as String,
      kind: ResourceKind.values.byName(r['kind'] as String),
      name: r['name'] as String,
      filename: r['filename'] as String,
      sourceHash: r['source_hash'] as String,
      dataJson: r['data_json'] as String,
      parentId: r['parent_id'] as String?,
      archived: r['archived'] == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        r['created_at'] as int,
        isUtc: true,
      ),
    );
