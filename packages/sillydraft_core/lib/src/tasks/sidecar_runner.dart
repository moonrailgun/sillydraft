part of 'task_runner.dart';

/// The data fields the sidecar may write per kind. Anything else an entry
/// holds (portraits, map points) is the author's and kept as it is.
const _sidecarFields = {
  LoreKind.character: ['appearance', 'outfit', 'goal', 'state', 'user'],
  LoreKind.relationship: ['fromId', 'toId', 'directed'],
  LoreKind.event: ['storyTime', 'status'],
  LoreKind.foreshadow: ['storyTime', 'status'],
};
const _sidecarFlags = {'user', 'directed'};

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
    duties.any(
      (d) =>
          d.kinds.contains(kind) &&
          d.certainties.contains(certainty) &&
          (previous == null || d.certainties.contains(previous.certainty)),
    ) ||
    (duties.contains(SidecarDuty.projection) &&
        SidecarDuty.projection.kinds.contains(kind) &&
        certainty == LoreCertainty.fact &&
        previous != null &&
        previous.certainty != LoreCertainty.fact);

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
    'save_lore',
    '批量新建或更新资料，直接写入并归于本章。更新须给 id 与 expectedRevisionId，未给出的字段保持原值。单次最多 20 条，逐条返回结果。',
    {
      'entries': {
        'type': 'array',
        'maxItems': 20,
        'items': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string', 'description': '更新已有条目时填写'},
            'expectedRevisionId': {
              'type': 'string',
              'description': '更新时填读到的 revisionId',
            },
            'kind': {
              'type': 'string',
              'enum': [
                for (final k in LoreKind.values)
                  if (duties.any((d) => d.kinds.contains(k))) k.name,
              ],
            },
            'name': {'type': 'string'},
            'content': {'type': 'string'},
            'certainty': {
              'type': 'string',
              'enum': [for (final c in LoreCertainty.values) c.name],
            },
            'appearance': {'type': 'string', 'description': '人物：外貌与辨识特征'},
            'outfit': {'type': 'string', 'description': '人物：当前服饰'},
            'goal': {'type': 'string', 'description': '人物：动机与目标'},
            'state': {'type': 'string', 'description': '人物：当前状态，如伤势、情绪、处境'},
            'user': {'type': 'boolean', 'description': '人物：是否为主角 {{user}}'},
            'fromId': {'type': 'string', 'description': '关系：起点条目 id'},
            'toId': {'type': 'string', 'description': '关系：终点条目 id'},
            'directed': {'type': 'boolean', 'description': '关系：是否有方向'},
            'storyTime': {'type': 'string', 'description': '事件、伏笔：故事内时间'},
            'status': {
              'type': 'string',
              'enum': [
                'active',
                'planted',
                'developing',
                'resolved',
                'abandoned',
              ],
            },
          },
          'required': ['kind', 'name', 'content', 'certainty'],
          'additionalProperties': false,
        },
      },
    },
    ['entries'],
  ),
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
        return {
          'id': e.id,
          'revisionId': e.revisionId,
          'kind': e.kind.name,
          'name': e.name,
          'content': e.content,
          'certainty': e.certainty.name,
          'sourceStale': e.sourceStale,
          'data': e.data,
        };
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
              await _sidecarSave(task, duties, i, entry),
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

  /// Writes one `save_lore` entry, answering with its new revision or why
  /// it was not written; one bad entry never stops the rest.
  Future<Map<String, dynamic>> _sidecarSave(
    GenerationTask task,
    Set<SidecarDuty> duties,
    int index,
    Object? value,
  ) async {
    LoreEntry? previous;
    try {
      final args = jsonObject(value, 'entry');
      final kind = LoreKind.values.asNameMap()[args['kind']];
      final certainty = LoreCertainty.values.asNameMap()[args['certainty']];
      final name = args['name'], content = args['content'];
      final id = args['id'], expected = args['expectedRevisionId'];
      if (kind == null ||
          certainty == null ||
          name is! String ||
          content is! String ||
          (id == null) != (expected == null) ||
          (id != null && (id is! String || expected is! String))) {
        throw const FormatException(
          'kind、certainty、name、content 无效，或更新缺少 id 与 expectedRevisionId',
        );
      }
      final fields = _sidecarFields[kind] ?? const <String>[];
      const common = {
        'id',
        'expectedRevisionId',
        'kind',
        'name',
        'content',
        'certainty',
      };
      if (args.keys.any((k) => !common.contains(k) && !fields.contains(k))) {
        throw FormatException('${kind.name} 条目只能写这些字段：${fields.join('、')}');
      }
      final given = {
        for (final key in fields)
          if (args.containsKey(key)) key: args[key],
      };
      if (given.entries.any(
        (e) => _sidecarFlags.contains(e.key)
            ? e.value is! bool
            : e.value is! String,
      )) {
        throw const FormatException('字段类型无效');
      }
      previous = id == null
          ? null
          : await repository.getLoreEntry(
              branchId: task.branchId,
              id: id as String,
              throughChapterId: task.chapterId,
            );
      if (!_sidecarAllows(duties, kind, certainty, previous)) {
        throw FormatException('当前开启的职责不能写入 ${kind.name}（${certainty.name}）');
      }
      final saved = await repository.saveLoreEntry(
        branchId: task.branchId,
        id: id as String?,
        expectedRevisionId: expected as String?,
        kind: kind,
        name: name,
        content: content,
        certainty: certainty,
        atChapterId: task.chapterId,
        data: {...?previous?.data, ...given},
        provenance: _sidecarProvenance(task),
      );
      return {'index': index, 'id': saved.id, 'revisionId': saved.revisionId};
    } on LoreConflict {
      return {
        'index': index,
        'error': '版本冲突：资料已被修改，请重新读取后再写',
        'revisionId': ?previous?.revisionId,
      };
    } on FormatException catch (e) {
      return {'index': index, 'error': e.message};
    } on StoryNotFound {
      return {'index': index, 'error': '目标条目不存在或不在本章可见范围内'};
    } catch (e) {
      return {'index': index, 'error': '写入失败：$e'};
    }
  }
}
