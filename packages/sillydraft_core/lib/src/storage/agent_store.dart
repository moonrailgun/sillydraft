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
