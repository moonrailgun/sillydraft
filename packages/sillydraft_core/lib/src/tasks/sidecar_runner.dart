part of 'task_runner.dart';

/// The sidecar's duties as its task froze them.
Set<SidecarDuty> _sidecarDuties(GenerationTask task) => {
  for (final name in task.input['duties'] as List? ?? const [])
    SidecarDuty.values.byName(name as String),
};

/// Whether [duties] let the sidecar write [kind] at [certainty]. A duty must
/// also cover the certainty of the [previous] entry it updates or deletes, so
/// no duty can demote or remove what it may not write. Projection may also
/// promote any existing plan or inference this chapter bore out to fact.
bool _sidecarAllows(
  Set<SidecarDuty> duties,
  LoreKind kind,
  LoreCertainty certainty,
  LoreEntry? previous,
) =>
    previous?.data['worldBookOnly'] != true &&
    (duties.any(
          (d) =>
              d.kinds.contains(kind) &&
              d.certainties.contains(certainty) &&
              (previous == null || d.certainties.contains(previous.certainty)),
        ) ||
        (duties.contains(SidecarDuty.projection) &&
            SidecarDuty.projection.kinds.contains(kind) &&
            certainty == LoreCertainty.fact &&
            previous != null &&
            previous.certainty != LoreCertainty.fact));

Map<String, dynamic> _sidecarFunction(
  String name,
  String description,
  Map<String, dynamic> properties, [
  List<String> required = const [],
]) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
      'additionalProperties': false,
    },
  },
};

List<Map<String, dynamic>> _sidecarTools(Set<SidecarDuty> duties) => [
  _sidecarFunction(
    'list_lore',
    '列出截至本章的资料索引：id、类型、名称、确定程度，以及是否过期、是否来自本章旁路整理、是否主角。可按类型筛选。',
    {
      'kind': {
        'type': 'string',
        'enum': [for (final k in LoreKind.values) k.name],
      },
    },
  ),
  _sidecarFunction(
    'read_lore',
    '读取截至本章的一个资料条目全文，含 revisionId 与 data。',
    {
      'id': {'type': 'string'},
    },
    ['id'],
  ),
  _sidecarFunction(
    'read_lore_batch',
    '批量读取截至本章的资料全文、revisionId 与 data；最多 20 个 id，逐条返回错误。',
    {
      'ids': {
        'type': 'array',
        'items': {'type': 'string'},
        'minItems': 1,
        'maxItems': 20,
      },
    },
    ['ids'],
  ),
  _saveLoreTool({for (final duty in duties) ...duty.kinds}),
  _sidecarFunction(
    'delete_lore',
    '删除一个资料条目：在本章位置写入删除版本。',
    {
      'id': {'type': 'string'},
      'expectedRevisionId': {'type': 'string'},
    },
    ['id', 'expectedRevisionId'],
  ),
];

extension _SidecarExecution on TaskRunner {
  /// The sidecar's tool loop. With no conversation to keep its messages,
  /// they are saved on the task as its transcript once the run ends, however
  /// it ends. SQLite rewrites the whole task row on each progress save, so a
  /// transcript saved as it grew cost the square of its size.
  // ponytail: a run killed mid-way keeps its lore writes but not its
  // transcript; a table of task messages would keep both.
  Future<void> _executeSidecar(
    GenerationTask task,
    ModelProvider provider,
    GenerationCancellation cancel,
    StringBuffer output,
    StringBuffer reasoning,
  ) async {
    final duties = _sidecarDuties(task);
    final transcript = <Map<String, dynamic>>[];
    try {
      await _toolLoop(
        task,
        provider,
        cancel,
        output,
        reasoning,
        tools: _sidecarTools(duties),
        execute: (call) => _sidecarTool(task, duties, call),
        record: (role, content, metadata) async =>
            transcript.add({'role': role, 'content': content, ...metadata}),
        overflow: '本章与资料超出整理模型的上下文限制',
        name: '旁路整理',
      );
    } finally {
      if (transcript.isNotEmpty) {
        await repository.saveTaskTranscript(task.id, transcript);
      }
    }
  }

  Map<String, dynamic> _sidecarProvenance(GenerationTask task) => {
    'type': 'sidecar',
    'taskId': task.id,
    'chapterId': task.chapterId,
    'revisionId': task.baseRevisionId,
  };

  /// The sidecar's tools read and write the lore live, as of its chapter.
  Future<Map<String, dynamic>> _sidecarTool(
    GenerationTask task,
    Set<SidecarDuty> duties,
    ToolCallReady call,
  ) async {
    final args = call.arguments, chapterId = task.chapterId!;
    Future<LoreEntry> read(Object? id) => repository.getLoreEntry(
      branchId: task.branchId,
      id: id as String,
      throughChapterId: chapterId,
    );
    switch (call.name) {
      case 'list_lore':
        final kind = args['kind'];
        if (args.keys.any((k) => k != 'kind') ||
            (kind != null && kind is! String)) {
          throw const FormatException('参数无效');
        }
        return {
          'entries': [
            for (final e in await repository.listLore(
              task.branchId,
              throughChapterId: chapterId,
            ))
              if (kind == null || e.kind.name == kind)
                sidecarIndexEntry(e, chapterId),
          ],
        };
      case 'read_lore':
        if (args.length != 1 || args['id'] is! String) {
          throw const FormatException('参数无效');
        }
        final e = await read(args['id']);
        return _sidecarEntry(e);
      case 'read_lore_batch':
        final ids = args['ids'];
        if (args.length != 1 ||
            ids is! List ||
            ids.isEmpty ||
            ids.length > 20 ||
            ids.any((id) => id is! String || id.isEmpty)) {
          throw const FormatException('ids 须为 1 到 20 个条目 id');
        }
        final entries = <Map<String, dynamic>>[];
        for (final id in ids.toSet()) {
          try {
            entries.add(_sidecarEntry(await read(id)));
          } on StoryNotFound {
            entries.add({'id': id, 'error': '条目不存在或不在本章可见范围内'});
          }
        }
        return {'entries': entries};
      case 'save_lore':
        final entries = args['entries'];
        if (args.length != 1 ||
            entries is! List ||
            entries.isEmpty ||
            entries.length > 20) {
          throw const FormatException('entries 须为 1 到 20 条');
        }
        return {
          'results': [
            for (final (i, entry) in entries.indexed)
              await _saveLore(task, i, entry),
          ],
        };
      case 'delete_lore':
        if (args.length != 2 ||
            args['id'] is! String ||
            args['expectedRevisionId'] is! String) {
          throw const FormatException('参数无效');
        }
        final entry = await read(args['id']);
        if (!_sidecarAllows(duties, entry.kind, entry.certainty, entry)) {
          return {'error': '当前开启的职责不能删除这类资料'};
        }
        try {
          await repository.saveLoreEntry(
            branchId: task.branchId,
            id: entry.id,
            expectedRevisionId: args['expectedRevisionId'] as String,
            kind: entry.kind,
            name: entry.name,
            content: entry.content,
            certainty: entry.certainty,
            atChapterId: chapterId,
            data: entry.data,
            provenance: _sidecarProvenance(task),
            deleted: true,
          );
        } on LoreConflict {
          return {'error': '版本冲突：资料已被修改，请重新读取', 'revisionId': entry.revisionId};
        }
        return {'deleted': entry.id};
    }
    throw const FormatException('未授权的工具');
  }
}

Map<String, dynamic> _sidecarEntry(LoreEntry e) => {
  'id': e.id,
  'revisionId': e.revisionId,
  'kind': e.kind.name,
  'name': e.name,
  'content': e.content,
  'certainty': e.certainty.name,
  'sourceStale': e.sourceStale,
  'data': e.data,
};
