part of 'story_repository.dart';

DateTime _date(Object? value) =>
    DateTime.fromMillisecondsSinceEpoch(value as int, isUtc: true);

Novel _novel(Map<String, Object?> r) => Novel(
  id: r['id'] as String,
  title: r['title'] as String,
  synopsis: r['synopsis'] as String,
  genre: r['genre'] as String,
  language: r['language'] as String,
  style: r['style'] as String,
  pointOfView: r['point_of_view'] as String,
  activeBranchId: r['active_branch_id'] as String,
  coverAssetId: r['cover_asset_id'] as String?,
  archived: r['archived'] == 1,
  createdAt: _date(r['created_at']),
  updatedAt: _date(r['updated_at']),
);

StoryBranch _branch(Map<String, Object?> r) => StoryBranch(
  id: r['id'] as String,
  novelId: r['novel_id'] as String,
  name: r['name'] as String,
  parentBranchId: r['parent_branch_id'] as String?,
  forkChapterId: r['fork_chapter_id'] as String?,
  forkRevisionId: r['fork_revision_id'] as String?,
  createdAt: _date(r['created_at']),
);

Chapter _chapter(Map<String, Object?> r) => Chapter(
  id: r['chapter_id'] as String,
  branchId: r['branch_id'] as String,
  title: r['title'] as String,
  position: r['position'] as int,
  revisionId: r['revision_id'] as String,
  content: ManuscriptContent.decode(r['content_json'] as String),
);

DocumentRevision _revision(Map<String, Object?> r) => DocumentRevision(
  id: r['id'] as String,
  novelId: r['novel_id'] as String,
  chapterId: r['chapter_id'] as String,
  originBranchId: r['origin_branch_id'] as String,
  parentRevisionId: r['parent_revision_id'] as String?,
  content: ManuscriptContent.decode(r['content_json'] as String),
  createdAt: _date(r['created_at']),
  reason: r['reason'] as String,
  sourceProposalId: r['source_proposal_id'] as String?,
);

ManuscriptProposal _proposal(Map<String, Object?> r) => ManuscriptProposal(
  id: r['id'] as String,
  branchId: r['branch_id'] as String,
  chapterId: r['chapter_id'] as String,
  baseRevisionId: r['base_revision_id'] as String,
  content: ManuscriptContent.decode(r['content_json'] as String),
  status: ProposalStatus.values.byName(r['status'] as String),
  summary: r['summary'] as String,
  acceptedRevisionId: r['accepted_revision_id'] as String?,
  taskId: r['task_id'] as String?,
  createdAt: _date(r['created_at']),
);
