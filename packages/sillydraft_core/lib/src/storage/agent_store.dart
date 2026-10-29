part of 'story_repository.dart';

extension AgentOperations on StoryRepository {
  Future<String> createConversation({
    required String branchId,
    String title = '创作会话',
    String? throughChapterId,
  }) => _write(() async {
    await getBranch(branchId);
    if (throughChapterId != null) {
      await getChapter(branchId: branchId, chapterId: throughChapterId);
    }
    final id = _id();
    await _execute(
      'INSERT INTO agent_conversations (id, branch_id, title, created_at, through_chapter_id) VALUES (?, ?, ?, ?, ?)',
      [id, branchId, title, _now(), throughChapterId],
    );
    return id;
  });

  Future<List<Chapter>> _agentChapters(GenerationTask task) async {
    final conversation = task.input['conversationId'] as String;
    if (await conversationBranch(conversation) != task.branchId) {
      throw const FormatException('会话不属于任务分支');
    }
    final story = await getStory(task.branchId);
    final through = await conversationChapter(conversation);
    if (through == null) return story.chapters;
    final end = story.chapters.indexWhere((c) => c.id == through);
    if (end < 0) throw const FormatException('会话参考章节已不存在');
    return story.chapters.take(end + 1).toList();
  }

  /// Checks the turn's evolving snapshot without changing the frozen task input.
  Future<bool> agentChaptersCurrent(
    GenerationTask task,
    List<Map<String, dynamic>> expected,
  ) async {
    final chapters = await _agentChapters(task);
    if (chapters.length != expected.length) return false;
    for (final (i, chapter) in chapters.indexed) {
      if (chapter.id != expected[i]['id'] ||
          chapter.revisionId != expected[i]['revisionId'] ||
          chapter.title != expected[i]['title']) {
        return false;
      }
    }
    return true;
  }

  /// Chapter management shares the normal store operations and their cleanup.
  Future<List<Chapter>?> manageAgentChapter({
    required GenerationTask task,
    required List<Map<String, dynamic>> expectedChapters,
    required String operation,
    String? chapterId,
    String? name,
  }) => _write(() async {
    if (!await agentChaptersCurrent(task, expectedChapters)) return null;
    final branchId = task.branchId;
    final conversation = task.input['conversationId'] as String;
    final story = await getStory(branchId);
    final through = await conversationChapter(conversation);
    if (operation == 'create_chapter') {
      if (story.chapters.length != expectedChapters.length) {
        throw const FormatException('参考范围后还有未读章节，请切换到分支末尾再新建章节。');
      }
      final chapter = await createChapter(branchId: branchId, name: name!);
      if (through != null) {
        await _execute(
          'UPDATE agent_conversations SET through_chapter_id = ? WHERE id = ?',
          [chapter.id, conversation],
        );
      }
    } else {
      if (!expectedChapters.any((c) => c['id'] == chapterId)) {
        throw const FormatException('目标章节不在当前参考范围内');
      }
      if (operation == 'rename_chapter') {
        await renameChapter(
          branchId: branchId,
          chapterId: chapterId!,
          name: name!,
        );
      } else if (operation == 'delete_chapter') {
        if (through == chapterId) {
          final before = story.chapters
              .takeWhile((c) => c.id != chapterId)
              .lastOrNull
              ?.id;
          // A null boundary means the whole book, not an empty historical scope.
          if (before == null && story.chapters.length > 1) {
            throw const FormatException('删除此章会越过当前参考范围，请先调整会话参考范围。');
          }
          await _execute(
            'UPDATE agent_conversations SET through_chapter_id = ? WHERE id = ?',
            [before, conversation],
          );
        }
        await _deleteChapter(
          branchId: branchId,
          chapterId: chapterId!,
          ignoreTaskId: task.id,
        );
      } else {
        throw const FormatException('无效的章节操作');
      }
    }
    return _agentChapters(task);
  });

  Future<List<Map<String, Object?>>> listConversations(String branchId) =>
      _rows(
        'SELECT * FROM agent_conversations WHERE branch_id = ? ORDER BY created_at DESC',
        [branchId],
      );

  /// Names an untitled conversation without overwriting a title set meanwhile.
  Future<void> nameConversation(String id, String title) => _write(() async {
    title = title.trim();
    if (title.isEmpty ||
        title.length > 30 ||
        title.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('会话标题须为 1 到 30 个字的单行文本');
    }
    await _execute(
      "UPDATE agent_conversations SET title = ? WHERE id = ? AND title = '创作会话'",
      [title, id],
    );
  });

  Future<String> conversationBranch(String id) async =>
      (await _one('SELECT branch_id FROM agent_conversations WHERE id = ?', [
            id,
          ], '编辑会话'))['branch_id']
          as String;

  Future<String?> conversationChapter(String id) async =>
      (await _one(
            'SELECT through_chapter_id FROM agent_conversations WHERE id = ?',
            [id],
            '编辑会话',
          ))['through_chapter_id']
          as String?;

  Future<AgentMessage> appendAgentMessage(
    String conversationId, {
    required String role,
    required String content,
    Map<String, dynamic> metadata = const {},
  }) => _write(() async {
    await conversationBranch(conversationId);
    if (!['user', 'assistant', 'tool', 'system'].contains(role)) {
      throw ArgumentError('会话角色无效');
    }
    final id = _id(), now = _now();
    final position =
        (await _one(
              'SELECT COALESCE(MAX(position), -1) + 1 AS p FROM agent_messages WHERE conversation_id = ?',
              [conversationId],
              '会话',
            ))['p']
            as int;
    await _execute(
      'INSERT INTO agent_messages (id, conversation_id, role, content, metadata_json, position, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        conversationId,
        role,
        content,
        jsonEncode(redactCredentials(metadata)),
        position,
        now,
      ],
    );
    return AgentMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content,
      metadata: metadata,
      createdAt: DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
    );
  });

  Future<List<AgentMessage>> getAgentMessages(String conversationId) async =>
      (await _rows(
            'SELECT * FROM agent_messages WHERE conversation_id = ? ORDER BY position',
            [conversationId],
          ))
          .map(
            (r) => AgentMessage(
              id: r['id'] as String,
              conversationId: r['conversation_id'] as String,
              role: r['role'] as String,
              content: r['content'] as String,
              metadata: jsonDecode(
                r['metadata_json'] as String,
              ) as Map<String, dynamic>,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                r['created_at'] as int,
                isUtc: true,
              ),
            ),
          )
          .toList();

  /// Removes the author's message [messageId] and everything after it, so the
  /// turn can be asked again.
  Future<void> deleteAgentMessagesFrom(
    String conversationId,
    String messageId,
  ) => _write(() async {
    final position =
        (await _one(
              "SELECT position FROM agent_messages WHERE id = ? AND conversation_id = ? AND role = 'user'",
              [messageId, conversationId],
              '会话消息',
            ))['position']
            as int;
    await _execute(
      'DELETE FROM agent_messages WHERE conversation_id = ? AND position >= ?',
      [conversationId, position],
    );
  });

  Future<void> deleteConversation(String id) => _write(
    () => _execute('DELETE FROM agent_conversations WHERE id = ?', [id]),
  );
}
