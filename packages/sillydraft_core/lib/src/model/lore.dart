import '../st/import_types.dart';

enum LoreKind {
  character,
  world,
  organization,
  item,
  location,
  event,
  foreshadow,
  relationship,
  map,
}

enum LoreCertainty { fact, plan, inference }

final class LoreEntry extends JsonSource {
  LoreEntry({
    required this.id,
    required this.revisionId,
    required this.branchId,
    required this.kind,
    required this.name,
    required this.content,
    required this.certainty,
    required this.createdAt,
    required Map<String, dynamic> data,
    required Map<String, dynamic> provenance,
    this.atSceneId,
    this.previousRevisionId,
    this.deleted = false,
    this.sourceStale = false,
  }) : super({'data': data, 'provenance': provenance});
  final String id, revisionId, branchId, name, content;
  final String? atSceneId, previousRevisionId;
  final LoreKind kind;
  final LoreCertainty certainty;
  final DateTime createdAt;
  final bool deleted, sourceStale;
  Map<String, dynamic> get data => raw['data'] as Map<String, dynamic>;
  Map<String, dynamic> get provenance =>
      raw['provenance'] as Map<String, dynamic>;
}

final class LoreConflict implements Exception {
  const LoreConflict([this.message = '资料已经更新，请重新打开后再保存。']);
  final String message;
  @override
  String toString() => message;
}

final class StaleAnalysis implements Exception {
  const StaleAnalysis();
  @override
  String toString() => '依据的正文已经变化，请重新分析或生成候选。';
}
