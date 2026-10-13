part of 'story_repository.dart';

extension ProposalOperations on StoryRepository {
  Future<GenerationTask?> _displayContext(DocumentRevision revision) async {
    var current = revision;
    while (true) {
      if (current.sourceProposalId case final String id) {
        final proposal = await getProposal(id);
        return proposal.taskId == null ? null : getTask(proposal.taskId!);
      }
      if (current.parentRevisionId == null) return null;
      current = await getRevision(current.parentRevisionId!);
    }
  }

  /// Immutable task input pins display rules and macro values to this revision.
  /// Later manual edits inherit its display context; exports use original data.
  Future<ManuscriptPresentation> presentRevision(String id) async {
    final revision = await getRevision(id),
        task = await _displayContext(revision);
    return task == null
        ? await _presentWithBranchRules(revision)
        : ManuscriptPresentation.fromTask(revision.content, task);
  }

  Future<ManuscriptPresentation> presentProposal(String id) async {
    final proposal = await getProposal(id);
    final task = proposal.taskId == null
        ? await _displayContext(await getRevision(proposal.baseRevisionId))
        : await getTask(proposal.taskId!);
    return task == null
        ? ManuscriptPresentation.identity(proposal.content)
        : ManuscriptPresentation.fromTask(proposal.content, task);
  }

  Future<ManuscriptProposal> createProposal({
    required String branchId,
    required String sceneId,
    required String baseRevisionId,
    required ManuscriptContent content,
    String summary = '',
    String? taskId,
  }) => _write(() async {
    final history = await listRevisions(branchId: branchId, sceneId: sceneId);
    if (!history.any((r) => r.id == baseRevisionId)) {
      throw const StoryNotFound('提案依据的正文版本');
    }
    final id = _id();
    await _execute(
      '''INSERT INTO proposals
      (id, branch_id, scene_id, base_revision_id, content_json, summary, status, task_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)''',
      [
        id,
        branchId,
        sceneId,
        baseRevisionId,
        content.encoded,
        summary,
        taskId,
        _now(),
      ],
    );
    return getProposal(id);
  });

  Future<ManuscriptProposal> getProposal(String id) async => _proposal(
    await _one('SELECT * FROM proposals WHERE id = ?', [id], '修改提案'),
  );

  Future<List<ManuscriptProposal>> listProposals(
    String branchId, {
    ProposalStatus? status,
  }) async {
    final rows = await _rows(
      '''SELECT * FROM proposals WHERE branch_id = ?
      AND (? IS NULL OR status = ?) ORDER BY created_at DESC, id''',
      [branchId, status?.name, status?.name],
    );
    return rows.map(_proposal).toList(growable: false);
  }

  Future<DocumentRevision> acceptProposal(String id) => _write(() async {
    final proposal = await getProposal(id);
    if (proposal.status == ProposalStatus.accepted) {
      return getRevision(proposal.acceptedRevisionId!);
    }
    if (proposal.status != ProposalStatus.pending) {
      throw StateError('该提案已经被拒绝。');
    }
    final scene = await _saveScene(
      branchId: proposal.branchId,
      sceneId: proposal.sceneId,
      expectedRevisionId: proposal.baseRevisionId,
      content: proposal.content,
      reason: 'accept',
      sourceProposalId: proposal.id,
    );
    await _commitProposalVariables(proposal, scene);
    await _execute(
      "UPDATE proposals SET status = 'accepted', accepted_revision_id = ? WHERE id = ?",
      [scene.revisionId, proposal.id],
    );
    return getRevision(scene.revisionId);
  });

  Future<void> rejectProposal(String id) => _write(() async {
    final proposal = await getProposal(id);
    if (proposal.status == ProposalStatus.accepted) {
      throw StateError('已采纳的提案不能拒绝，请从版本历史恢复正文。');
    }
    await _execute("UPDATE proposals SET status = 'rejected' WHERE id = ?", [
      id,
    ]);
  });
}
