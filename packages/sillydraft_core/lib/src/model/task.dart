import '../st/import_types.dart';
import '../st/macro_engine.dart';
import '../st/preset_importer.dart';
import '../st/prompt_compiler.dart';
import '../providers/provider.dart';

enum TaskKind {
  writing,
  rewrite,
  branches,
  analysis,
  agent,
  illustration,
  sidecar,
}

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
    this.chapterId,
    this.baseRevisionId,
    this.retryOf,
    this.result = const {},
  }) : super(input);

  /// Loads an immutable database snapshot; input is decoded only on access.
  GenerationTask.fromStoredJson({
    required this.id,
    required this.branchId,
    required this.kind,
    required this.status,
    required String inputJson,
    required this.partialText,
    required this.reasoning,
    required this.error,
    required this.createdAt,
    required this.updatedAt,
    this.chapterId,
    this.baseRevisionId,
    this.retryOf,
    this.result = const {},
  }) : super.encoded(inputJson);

  final String id, branchId, partialText, reasoning, error;
  final String? chapterId, baseRevisionId, retryOf;
  final TaskKind kind;
  final TaskStatus status;
  final DateTime createdAt, updatedAt;
  final Map<String, dynamic> result;
  Map<String, dynamic> get input => raw;
  bool get isActive =>
      status == TaskStatus.queued || status == TaskStatus.running;
  bool get isRemote =>
      (input['connection'] as Map?)?['protocol'] ==
      ModelProtocol.sillyDraftRunner.name;

  /// Local time's UTC offset when the task's `clock` was read, so its time
  /// macros render the same later. Older tasks rendered the UTC clock as is.
  Duration get clockOffset =>
      Duration(minutes: input['utcOffset'] as int? ?? 0);

  /// The env the prompt was compiled with (`macroEnv`). Older tasks kept
  /// only `macroValues`: the names, description and scenario stand in,
  /// with the connection's model and their preset's reasoning template;
  /// token limits they did not keep come from the connection and the
  /// request's response length, as WritingService checks them.
  MacroEnv get macroEnv {
    // Read raw, with ModelConnection.fromJson's defaults: a display must not
    // fail on a stored connection that today's validation would reject.
    final connection = input['connection'] as Map?;
    final tokens =
        ((input['compiled'] as Map?)?['parameters'] as Map?)?['max_tokens'];
    final limits = <String, num?>{
      'maxContext': connection == null
          ? null
          : connection['contextWindow'] as num? ?? 200000,
      'maxResponse': tokens is num
          ? tokens
          : connection == null
          ? null
          : connection['maxOutputTokens'] as num? ?? 2048,
    };
    final stored = input['macroEnv'];
    // Tasks from before the reasoning macros (or, earlier, the system
    // prompt macros) did not keep these templates; their preset has them.
    final preset =
        !(stored is Map &&
                stored.containsKey('sysprompt') &&
                stored.containsKey('reasoning')) &&
            input['preset'] is Map<String, dynamic>
        ? _presetEnv(input['preset'] as Map<String, dynamic>)
        : null;
    if (stored case final Map<String, dynamic> env) {
      return MacroEnv.fromJson({
        ...limits,
        if (preset != null) ...{
          'sysprompt': preset.sysprompt,
          'reasoning': preset.reasoning,
        },
        ...env,
      });
    }
    final values = (input['macroValues'] as Map? ?? const {})
        .cast<String, String>();
    final env = MacroEnv.of(
      card: {
        'name': values['char'],
        'description': values['description'],
        'scenario': values['scenario'],
      },
      user: values['user'] ?? '',
      model: (input['connection'] as Map?)?['model'] as String? ?? '',
      maxContext: limits['maxContext'],
      maxResponse: limits['maxResponse'],
    );
    return preset == null
        ? env
        : MacroEnv.fromJson({...env.toJson(), 'reasoning': preset.reasoning});
  }

  /// The templates of a stored [preset], as [MacroEnv.of] picks them; none
  /// for one today's importer rejects.
  static MacroEnv? _presetEnv(Map<String, dynamic> preset) {
    try {
      return MacroEnv.of(user: '', preset: PresetImporter().decode(preset));
    } on FormatException {
      return null;
    }
  }

  /// The chat macros of the request once its prompt was built
  /// (`chatMacros`): output regex reads them as ST's `cleanUpMessage` does,
  /// before the reply joins the chat. Older writing tasks had the chapters
  /// in `sourceRevisions`, then the brief, as their chat; the texts were not
  /// kept.
  Map<String, String> get chatMacros {
    if (input['chatMacros'] case final Map values) {
      return values.cast<String, String>();
    }
    final sources = input['sourceRevisions'];
    if (sources is! List) return const {};
    final chat = sources.length + 1;
    final compiled = input['compiled'] as Map?;
    return {
      'lastmessageid': '${chat - 1}',
      'allchatrange': '0-${chat - 1}',
      'lastswipeid': '',
      'currentswipeid': '',
      if (compiled != null)
        'firstincludedmessageid': PromptCompiler.firstIncluded(
          chat,
          compiled['completionText'] != null
              ? null
              : [
                  for (final m in compiled['messages'] as List? ?? const [])
                    (m as Map)['role'] as String,
                ],
          'normal',
        ),
      'firstdisplayedmessageid': '0',
      'lastgenerationtype': 'normal',
    };
  }

  /// A macro evaluator for the task's output and display stages: its env,
  /// clock, seed, chat and outlets, with [local] and [global] variables. With
  /// [message], the target chapter's text once the reply is in it (MVU and
  /// display): ST's `saveReply` adds the reply before they read the chat,
  /// and here that chapter is the chat's last message, the brief never
  /// being stored.
  MacroEngine macros({
    Map<String, String> local = const {},
    Map<String, String> global = const {},
    String? message,
  }) {
    final sources = input['sourceRevisions'];
    final id = sources is List ? '${sources.length - 1}' : null;
    return MacroEngine(
      env: macroEnv,
      values: {
        ...chatMacros,
        if (message != null && id != null) ...{
          'lastmessageid': id,
          'allchatrange': '0-$id',
          'lastmessage': message,
          'lastusermessage': '',
          'lastcharmessage': message,
          'lastswipeid': '1',
          'currentswipeid': '1',
        },
      },
      outlets: (input['outlets'] as Map? ?? const {}).cast<String, String>(),
      clock: DateTime.parse(input['clock'] as String),
      utcOffset: clockOffset,
      seed: input['seed'] as int,
      local: local,
      global: global,
    );
  }
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
