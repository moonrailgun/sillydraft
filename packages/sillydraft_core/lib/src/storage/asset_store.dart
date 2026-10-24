part of 'story_repository.dart';

extension AssetOperations on StoryRepository {
  /// Includes archived assets and assets used only by old manuscript revisions.
  Future<Set<String>> assetFileNames() async => {
    for (final row in await _rows(
      'SELECT content_hash,thumbnail_hash FROM story_assets',
    )) ...['${row['content_hash']}.png', '${row['thumbnail_hash']}.jpg'],
    // Persona images are referenced only from the persona list.
    for (final persona in await listPersonas())
      for (final image in persona.images) ...[
        '${image.hash}.png',
        '${image.thumbnailHash}.jpg',
      ],
  };

  Future<StoryAsset> getAsset(String id) async => _asset(
    await _one('SELECT * FROM story_assets WHERE id = ?', [id], '图片资源'),
  );
  Future<List<StoryAsset>> listAssets(
    String novelId, {
    bool includeArchived = false,
  }) async => (await _rows(
    'SELECT * FROM story_assets WHERE novel_id = ? AND (? = 1 OR archived = 0) ORDER BY created_at DESC,id',
    [novelId, includeArchived ? 1 : 0],
  )).map(_asset).toList();
  Future<void> archiveAsset(String id, {required bool archived}) =>
      _write(() async {
        final asset = await getAsset(id);
        await _execute('UPDATE story_assets SET archived = ? WHERE id = ?', [
          archived ? 1 : 0,
          id,
        ]);
        await _touchNovel(asset.novelId);
      });
  Future<StoryAsset> storeAsset({
    required String branchId,
    required String name,
    required PreparedAsset prepared,
    AssetPurpose purpose = AssetPurpose.illustration,
    String? sourceChapterId,
    String? sourceRevisionId,
    String? taskId,
    Map<String, dynamic> metadata = const {},
  }) => _write(() async {
    _validateTitle(name);
    final branch = await getBranch(branchId);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(prepared.hash) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(prepared.thumbnailHash) ||
        prepared.width <= 0 ||
        prepared.height <= 0 ||
        prepared.byteLength <= 0) {
      throw const FormatException('图片资源记录无效');
    }
    if ((sourceChapterId == null) != (sourceRevisionId == null)) {
      throw const FormatException('图片来源章节和版本必须同时提供');
    }
    if (sourceChapterId != null &&
        !(await listRevisions(
          branchId: branchId,
          chapterId: sourceChapterId,
        )).any((r) => r.id == sourceRevisionId)) {
      throw const StoryNotFound('插画依据版本');
    }
    if (taskId != null && (await getTask(taskId)).branchId != branchId) {
      throw const StoryNotFound('插画生成任务');
    }
    final id = _id();
    await _execute(
      '''INSERT INTO story_assets (id,novel_id,branch_id,name,content_hash,thumbnail_hash,width,height,byte_length,purpose,source_chapter_id,source_revision_id,task_id,metadata_json,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
      [
        id,
        branch.novelId,
        branchId,
        name.trim(),
        prepared.hash,
        prepared.thumbnailHash,
        prepared.width,
        prepared.height,
        prepared.byteLength,
        purpose.name,
        sourceChapterId,
        sourceRevisionId,
        taskId,
        jsonEncode(redactCredentials(metadata)),
        _now(),
      ],
    );
    await _touchNovel(branch.novelId);
    return getAsset(id);
  });
  Future<StoryAsset?> completeIllustrationTask({
    required String taskId,
    required PreparedAsset prepared,
    required Map<String, dynamic> metadata,
  }) => _write(() async {
    final task = await getTask(taskId);
    if (task.kind != TaskKind.illustration) {
      throw const FormatException('不是插画任务');
    }
    if (task.result['assetId'] case final String id) return getAsset(id);
    if (task.status != TaskStatus.running) return null;
    final asset = await storeAsset(
      branchId: task.branchId,
      name: task.input['name'] as String,
      prepared: prepared,
      purpose: AssetPurpose.values.byName(task.input['purpose'] as String),
      sourceChapterId: task.chapterId,
      sourceRevisionId: task.baseRevisionId,
      taskId: taskId,
      metadata: metadata,
    );
    await updateTask(
      taskId,
      status: TaskStatus.completed,
      result: {'assetId': asset.id, 'stage': 'completed'},
    );
    return asset;
  });
  Future<bool> assetSourceCurrent(String id) async {
    final asset = await getAsset(id);
    if (asset.sourceChapterId == null) return true;
    try {
      return (await getChapter(
            branchId: asset.branchId,
            chapterId: asset.sourceChapterId!,
          )).revisionId ==
          asset.sourceRevisionId;
    } on StoryNotFound {
      return false;
    }
  }

  Future<void> _validateManuscriptAssets(
    String novelId,
    ManuscriptContent content,
  ) async {
    for (final op in content.delta) {
      if (op['insert'] case final Map embed) {
        final uri = embed['image'];
        if (embed.length != 1 || uri is! String || !uri.startsWith('asset:')) {
          throw const FormatException('正文插图只能引用已导入的图片资源');
        }
        final asset = await getAsset(uri.substring(6));
        if (asset.novelId != novelId) throw const StoryNotFound('本作品的图片资源');
      }
    }
  }

  Future<int> insertAgentIllustrations({
    required String branchId,
    required List<String> assetIds,
    required AgentMessage source,
    Map<String, Map<String, dynamic>> anchors = const {},
  }) => _write(() async {
    var inserted = 0;
    // Insertion prepends to a paragraph's images; reverse to keep result order.
    for (final assetId in assetIds.reversed) {
      final asset = await getAsset(assetId);
      final anchor = anchors[assetId] ?? asset.metadata['illustrationAnchor'];
      if (anchor is! Map || anchor['chapterId'] is! String) {
        throw const FormatException('部分图片未保存引用段落，请逐张选择位置插入。');
      }
      final chapter = await getChapter(
        branchId: branchId,
        chapterId: anchor['chapterId'] as String,
      );
      if (chapter.content.delta.any(
        (op) =>
            op['insert'] is Map &&
            (op['insert'] as Map)['image'] == 'asset:$assetId',
      )) {
        continue;
      }
      await insertAgentIllustration(
        branchId: branchId,
        assetId: assetId,
        source: source,
        illustrationAnchor: anchor.cast<String, dynamic>(),
      );
      inserted++;
    }
    return inserted;
  });

  Future<Chapter> insertAgentIllustration({
    required String branchId,
    required String assetId,
    required AgentMessage source,
    Map<String, dynamic>? illustrationAnchor,
  }) async {
    if (source.role != 'user' ||
        await conversationBranch(source.conversationId) != branchId) {
      throw const FormatException('找不到这张图片引用的正文，请从插图库选择插入位置。');
    }
    final asset = await getAsset(assetId);
    final anchor =
        illustrationAnchor ??
        asset.metadata['illustrationAnchor'] ??
        source.raw['illustrationAnchor'];
    final attachment = source.raw['attachment'];
    final chapterId = anchor is Map
        ? anchor['chapterId']
        : attachment is Map
        ? attachment['chapterId']
        : null;
    if (chapterId is! String) {
      throw const FormatException('这张图片没有引用正文，请从插图库选择插入位置。');
    }
    final chapter = await getChapter(branchId: branchId, chapterId: chapterId);
    final text = chapter.content.text;
    late int end;
    if (anchor case {
      'revisionId': final String revision,
      'quote': final String quote,
    }) {
      // Earlier image insertions move offsets without changing the quoted prose.
      var current = await getRevision(chapter.revisionId);
      while (current.id != revision) {
        if (current.reason != 'insert_illustration' ||
            current.parentRevisionId == null) {
          throw RevisionConflict(
            expected: revision,
            actual: chapter.revisionId,
          );
        }
        current = await getRevision(current.parentRevisionId!);
      }
      if (chapter.content.delta.any(
        (op) =>
            op['insert'] is Map &&
            (op['insert'] as Map)['image'] == 'asset:$assetId',
      )) {
        throw const FormatException('这张插图已在本章正文中。');
      }
      final start = quote.isEmpty ? -1 : text.indexOf(quote);
      if (start < 0 || text.indexOf(quote, start + 1) >= 0) {
        throw const FormatException('无法准确定位引用段落，请从插图库选择插入位置。');
      }
      end = start + quote.length;
    } else if (anchor case {
      'revisionId': final String revision,
      'endOffset': final int offset,
    }) {
      if (chapter.revisionId != revision) {
        throw RevisionConflict(expected: revision, actual: chapter.revisionId);
      }
      end = offset;
    } else {
      // Older selection requests stored only the quote and the attached chapter.
      const prefix = '为这段正文生成一张插图：';
      final quote = source.content.startsWith(prefix)
          ? source.content.substring(prefix.length).trim()
          : '';
      final start = quote.isEmpty ? -1 : text.indexOf(quote);
      if (attachment is! Map ||
          attachment['text'] != text ||
          start < 0 ||
          text.indexOf(quote, start + 1) >= 0) {
        throw const FormatException('无法准确定位引用段落，请重新选中正文生成插图。');
      }
      end = start + quote.length;
    }
    if (end <= 0 || end > text.length) throw const FormatException('引用段落的位置无效');
    final newline = text.indexOf('\n', end - 1);
    final offset = (newline + 1).clamp(0, text.length - 1);
    return insertIllustration(
      branchId: branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      assetId: assetId,
      offset: offset,
    );
  }

  Future<Chapter> insertIllustration({
    required String branchId,
    required String chapterId,
    required String expectedRevisionId,
    required String assetId,
    required int offset,
  }) => _write(() async {
    final chapter = await getChapter(branchId: branchId, chapterId: chapterId);
    if (chapter.revisionId != expectedRevisionId) {
      throw RevisionConflict(
        expected: expectedRevisionId,
        actual: chapter.revisionId,
      );
    }
    final asset = await getAsset(assetId), branch = await getBranch(branchId);
    if (asset.novelId != branch.novelId) throw const StoryNotFound('本作品的图片资源');
    return _saveChapter(
      branchId: branchId,
      chapterId: chapterId,
      expectedRevisionId: expectedRevisionId,
      content: chapter.content.insertImage(offset, assetId),
      reason: 'insert_illustration',
    );
  });
  Future<void> setCover(String novelId, String? assetId) => _write(() async {
    if (assetId != null && (await getAsset(assetId)).novelId != novelId) {
      throw const StoryNotFound('本作品的封面');
    }
    await _execute(
      'UPDATE novels SET cover_asset_id = ?, updated_at = ? WHERE id = ?',
      [assetId, _now(), novelId],
    );
  });
}

StoryAsset _asset(Map<String, Object?> r) => StoryAsset(
  id: r['id'] as String,
  novelId: r['novel_id'] as String,
  branchId: r['branch_id'] as String,
  name: r['name'] as String,
  hash: r['content_hash'] as String,
  thumbnailHash: r['thumbnail_hash'] as String,
  width: r['width'] as int,
  height: r['height'] as int,
  byteLength: r['byte_length'] as int,
  purpose: AssetPurpose.values.byName(r['purpose'] as String),
  sourceChapterId: r['source_chapter_id'] as String?,
  sourceRevisionId: r['source_revision_id'] as String?,
  taskId: r['task_id'] as String?,
  archived: r['archived'] == 1,
  metadata: jsonDecode(r['metadata_json'] as String) as Map<String, dynamic>,
  createdAt: DateTime.fromMillisecondsSinceEpoch(
    r['created_at'] as int,
    isUtc: true,
  ),
);
