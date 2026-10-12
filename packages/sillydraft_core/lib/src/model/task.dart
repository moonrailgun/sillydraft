import '../st/import_types.dart';

enum TaskKind { writing, rewrite, branches, analysis, agent, illustration }

enum TaskStatus { queued, running, completed, failed, cancelled, interrupted }

final class GenerationTask extends JsonSource {
  GenerationTask({
    required this.id,
    required this.branchId,
    required this.kind,
    required this.status,
    required Map<String, dynamic> input,
    required this.partialText,
    required this.reasoning,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
    this.sceneId,
    this.baseRevisionId,
    this.retryOf,
    this.result = const {},
  }) : super(input);
  final String id, branchId, partialText, reasoning, error;
  final String? sceneId, baseRevisionId, retryOf;
  final TaskKind kind;
  final TaskStatus status;
  final DateTime createdAt, updatedAt;
  final Map<String, dynamic> result;
  Map<String, dynamic> get input => raw;
  bool get isActive =>
      status == TaskStatus.queued || status == TaskStatus.running;
}

final class BranchVariables {
  BranchVariables({
    required this.version,
    Map<String, String> local = const {},
    Map<String, String> global = const {},
  }) : local = Map.unmodifiable(local),
       global = Map.unmodifiable(global);
  final int version;
  final Map<String, String> local, global;
}

final class VariableConflict implements Exception {
  const VariableConflict();
  @override
  String toString() => '分支变量已变化，请重新生成或单独保留此候选。';
}

final class AgentMessage extends JsonSource {
  AgentMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    Map<String, dynamic> metadata = const {},
  }) : super(metadata);
  final String id, conversationId, role, content;
  final DateTime createdAt;
  Map<String, dynamic> toWire() => {
    'role': role,
    'content': content,
    if (raw['tool_calls'] != null) 'tool_calls': raw['tool_calls'],
    if (raw['tool_call_id'] != null) 'tool_call_id': raw['tool_call_id'],
  };
}
