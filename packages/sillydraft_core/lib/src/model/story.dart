import 'chapter_title.dart';
import 'manuscript.dart';

final class Novel {
  const Novel({
    required this.id,
    required this.title,
    required this.activeBranchId,
    required this.createdAt,
    required this.updatedAt,
    this.synopsis = '',
    this.genre = '自由创作',
    this.language = 'zh',
    this.style = '',
    this.pointOfView = '第三人称',
    this.coverAssetId,
    this.archived = false,
    this.chapterNumerals = ChapterNumerals.chinese,
  });

  final String id;
  final String title;
  final String synopsis;
  final String genre;
  final String language;
  final String style;
  final String pointOfView;
  final String activeBranchId;
  final String? coverAssetId;
  final bool archived;

  /// How the novel writes its chapter numbers.
  final ChapterNumerals chapterNumerals;
  final DateTime createdAt;
  final DateTime updatedAt;

  Novel copyWith({
    String? title,
    String? synopsis,
    String? genre,
    String? language,
    String? style,
    String? pointOfView,
    String? activeBranchId,
    String? coverAssetId,
    bool clearCover = false,
    bool? archived,
    ChapterNumerals? chapterNumerals,
    DateTime? updatedAt,
  }) => Novel(
    id: id,
    title: title ?? this.title,
    synopsis: synopsis ?? this.synopsis,
    genre: genre ?? this.genre,
    language: language ?? this.language,
    style: style ?? this.style,
    pointOfView: pointOfView ?? this.pointOfView,
    activeBranchId: activeBranchId ?? this.activeBranchId,
    coverAssetId: clearCover ? null : coverAssetId ?? this.coverAssetId,
    archived: archived ?? this.archived,
    chapterNumerals: chapterNumerals ?? this.chapterNumerals,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

final class StoryBranch {
  const StoryBranch({
    required this.id,
    required this.novelId,
    required this.name,
    required this.createdAt,
    this.parentBranchId,
    this.forkChapterId,
    this.forkRevisionId,
  });

  final String id;
  final String novelId;
  final String name;
  final String? parentBranchId;
  final String? forkChapterId;
  final String? forkRevisionId;
  final DateTime createdAt;
}

final class Chapter {
  const Chapter({
    required this.id,
    required this.branchId,
    required this.name,
    required this.position,
    required this.revisionId,
    required this.content,
    this.number,
    this.numerals = ChapterNumerals.chinese,
  });

  final String id;
  final String branchId;

  /// The chapter's own name, without its number; may be empty.
  final String name;

  /// Its place in the numbering, from 1; null for a chapter outside it.
  final int? number;
  final ChapterNumerals numerals;
  final int position;
  final String revisionId;
  final ManuscriptContent content;

  bool get numbered => number != null;

  /// Outside the numbering under a name that still reads 第N章, as
  /// migration keeps a title past a gap in the old numbering.
  bool get keptOldNumber => !numbered && splitChapterTitle(name).number != null;

  /// What the chapter is called on screen, in exports and in prompts.
  String get title => chapterTitle(number, name, numerals);
}

final class DocumentRevision {
  const DocumentRevision({
    required this.id,
    required this.novelId,
    required this.chapterId,
    required this.originBranchId,
    required this.content,
    required this.createdAt,
    required this.reason,
    this.parentRevisionId,
    this.sourceProposalId,
  });

  final String id;
  final String novelId;
  final String chapterId;
  final String originBranchId;
  final String? parentRevisionId;
  final ManuscriptContent content;
  final String reason;
  final String? sourceProposalId;
  final DateTime createdAt;
}

enum ProposalStatus { pending, accepted, rejected }

final class ManuscriptProposal {
  const ManuscriptProposal({
    required this.id,
    required this.branchId,
    required this.chapterId,
    required this.baseRevisionId,
    required this.content,
    required this.status,
    required this.summary,
    required this.createdAt,
    this.acceptedRevisionId,
    this.taskId,
  });

  final String id;
  final String branchId;
  final String chapterId;
  final String baseRevisionId;
  final ManuscriptContent content;
  final ProposalStatus status;
  final String summary;
  final String? acceptedRevisionId;
  final String? taskId;
  final DateTime createdAt;
}

final class StorySnapshot {
  StorySnapshot({
    required this.novel,
    required this.branch,
    required List<Chapter> chapters,
  }) : chapters = List.unmodifiable(chapters);

  final Novel novel;
  final StoryBranch branch;
  final List<Chapter> chapters;
  String get text => chapters.map((s) => s.content.text).join('\n');
}

final class RevisionConflict implements Exception {
  const RevisionConflict({required this.expected, required this.actual});
  final String expected;
  final String actual;
  @override
  String toString() => '正文已经更新，请比较最新版本后再应用修改。';
}

final class StoryNotFound implements Exception {
  const StoryNotFound(this.entity);
  final String entity;
  @override
  String toString() => '找不到$entity，可能已删除或不属于当前故事。';
}
