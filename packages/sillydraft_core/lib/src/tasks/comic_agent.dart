part of 'task_runner.dart';

final _comicTools = <Map<String, dynamic>>[
  for (final entry in {
    'read_comic': '读取当前参考范围内已保存的漫画分镜、页面和对白。',
    'plan_comic': '根据开场或下一页指令保存原创漫画分镜，不调用生图。已有页面须完成后再续写。',
    'continue_comic': '根据开场或下一页指令保存原创分镜并绘制一张完整漫画页，含所有分镜和对白。',
    'draw_comic': '检查并绘制已保存的漫画分镜，补齐缺图或过期页面。',
    'edit_comic': '修改已保存分镜的画面、衔接或对白；修改后画面需要重画。',
    'adapt_comic': '将指定小说章节提取为忠于原文的漫画分镜并保存，随后可 draw_comic。',
  }.entries)
    {
      'type': 'function',
      'function': {
        'name': entry.key,
        'description': entry.value,
        'parameters': {
          'type': 'object',
          'properties': {
            ..._chapterSelector,
            if (['plan_comic', 'continue_comic'].contains(entry.key))
              'instruction': {'type': 'string', 'description': '本页开场或后续剧情要求'},
            if (entry.key == 'edit_comic') ...{
              'panelId': {'type': 'string'},
              'description': {'type': 'string'},
              'continuity': {'type': 'string'},
              'texts': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'kind': {
                      'type': 'string',
                      'enum': ['dialogue', 'thought', 'narration', 'sound'],
                    },
                    'speaker': {'type': 'string'},
                    'text': {'type': 'string'},
                    'factId': {'type': 'string'},
                  },
                  'required': ['kind', 'speaker', 'text'],
                  'additionalProperties': false,
                },
              },
            },
          },
          'required': [
            if (['plan_comic', 'continue_comic'].contains(entry.key))
              'instruction',
            if (entry.key == 'edit_comic') 'panelId',
          ],
          'additionalProperties': false,
        },
      },
    },
];

extension _ComicAgentExecution on TaskRunner {
  Future<Map<String, dynamic>> _agentComic(
    GenerationTask task,
    ToolCallReady call,
    GenerationCancellation cancel,
    List<Map<String, dynamic>> chapters,
    Map<String, dynamic> snapshot,
    String key,
  ) async {
    final args = call.arguments;
    final schema =
        _comicTools.firstWhere(
              (t) => t['function']['name'] == call.name,
            )['function']['parameters']
            as Map;
    if (args.keys.any((k) => !(schema['properties'] as Map).containsKey(k))) {
      throw const FormatException('漫画工具参数无效');
    }
    final target = _resolveChapter(args, chapters);
    if (target.containsKey('error')) return target;
    final id = target['id'] as String;
    snapshot.putIfAbsent(id, () => {'revisionId': null, 'document': null});
    final frozen = Map<String, dynamic>.from(snapshot[id] as Map);
    if (call.name == 'read_comic') return {'chapterId': id, ...frozen};
    final signature = canonicalJson({'tool': call.name, 'args': args});
    final state = await repository.getTask(task.id);
    final recorded = (state.result['agentComicCalls'] as Map?)?[key] as Map?;
    Map<String, dynamic> remember(Map<String, dynamic> result) {
      if (result['saved'] == true) {
        snapshot[id] = {
          'revisionId': result['revisionId'],
          'document': result['document'],
        };
      }
      return result;
    }

    if (recorded != null && recorded['signature'] != signature) {
      return {
        'error': '中断前的漫画调用与本次不同，请检查已保存结果后发起新消息。',
        'code': 'source_changed',
      };
    }
    if (recorded?['result'] case final Map result) {
      return remember(Map<String, dynamic>.from(result));
    }
    final link = <String, dynamic>{
      'taskId': task.id,
      'key': key,
      'signature': signature,
      'chapters': chapters,
      'heads': {
        for (final c in chapters.take(chapters.indexOf(target) + 1))
          c['id'] as String: (snapshot[c['id']] as Map?)?['revisionId'],
      },
    };
    GenerationTask? child;
    if (recorded?['taskId'] case final String childId) {
      child = await repository.getTask(childId);
    } else {
      if (!await repository.agentComicScopeCurrent(task, link)) {
        return _chapterSourceChanged;
      }
      cancel.check();
      final doc = frozen['document'] == null
          ? null
          : ComicDocument.fromJson(jsonObject(frozen['document'], 'comic'));
      final service = ComicService(
        repository: repository,
        runner: this,
        agentCall: link,
      );
      final connection = ModelConnection.fromJson(
        jsonObject(task.input['connection'], 'connection'),
      );
      final image = task.input['image'] as Map?;
      final head = frozen['revisionId'] as String?;
      if (call.name == 'edit_comic') {
        if (doc == null || args['panelId'] is! String) {
          throw const FormatException('请先读取已保存分镜');
        }
        final panels = doc.panels;
        final panel = panels
            .where((p) => p['id'] == args['panelId'])
            .firstOrNull;
        if (panel == null) throw const FormatException('分镜不存在');
        for (final field in ['description', 'continuity', 'texts']) {
          if (args.containsKey(field)) panel[field] = args[field];
        }
        return remember(
          await repository.saveAgentComic(
            taskId: task.id,
            link: link,
            document: doc.editPanels(panels),
            expectedRevisionId: head!,
          ),
        );
      }
      if (['draw_comic', 'continue_comic'].contains(call.name) &&
          image == null) {
        return {
          'error': '请先在设置中配置生图模型；可以先用 plan_comic 保存分镜。',
          'code': 'image_unavailable',
        };
      }
      if (['draw_comic', 'continue_comic'].contains(call.name)) {
        final approved = await _confirmImage(task, cancel, {
          'comic': true,
          'name': call.name == 'draw_comic' ? '绘制已保存分镜' : '绘制下一页',
          'connection': image!['connection'],
          'prompt': args['instruction'] ?? jsonEncode(doc?.panels),
          'references': doc?.assetIds.toList() ?? <String>[],
        });
        if (!approved) {
          final result = {
            'cancelled': true,
            'message': '作者已取消本次漫画绘制，未调用生图引擎。请勿自动重试。',
          };
          final latest = await repository.getTask(task.id);
          await repository.updateTask(
            task.id,
            status: TaskStatus.running,
            result: {
              'agentComicCalls': {
                ...?(latest.result['agentComicCalls'] as Map?),
                key: {'signature': signature, 'result': result},
              },
            },
          );
          return result;
        }
      }
      switch (call.name) {
        case 'plan_comic':
        case 'continue_comic':
          if (args['instruction'] is! String) {
            throw const FormatException('请提供剧情要求');
          }
          child = await service.compose(
            branchId: task.branchId,
            chapterId: id,
            instruction: args['instruction'] as String,
            connection: connection,
            expectedRevisionId: head,
            imageConnection: call.name == 'continue_comic'
                ? ModelConnection.fromJson(
                    jsonObject(image!['connection'], 'image'),
                  )
                : null,
            nsfwConnection: image?['nsfwConnection'] == null
                ? null
                : ModelConnection.fromJson(
                    jsonObject(image!['nsfwConnection'], 'nsfw'),
                  ),
          );
        case 'adapt_comic':
          child = await service.adapt(
            branchId: task.branchId,
            chapterIds: [id],
            connection: connection,
          );
        case 'draw_comic':
          if (doc == null) throw const FormatException('请先保存分镜');
          // Check and draw share one durable comic task.
          child = await service.generateImages(
            branchId: task.branchId,
            chapterId: id,
            connection: ModelConnection.fromJson(
              jsonObject(image!['connection'], 'image'),
            ),
            promptConnection: connection,
            expectedRevisionId: head,
            nsfwConnection: image['nsfwConnection'] == null
                ? null
                : ModelConnection.fromJson(
                    jsonObject(image['nsfwConnection'], 'nsfw'),
                  ),
            checkFirst: !doc.checked,
          );
      }
    }
    if (child == null) throw const FormatException('漫画工具无效');
    final removeCancel = cancel.onCancel(
      () => unawaited(this.cancel(child!.id)),
    );
    late GenerationTask done;
    try {
      done = await wait(child.id);
    } finally {
      removeCancel();
    }
    cancel.check();
    final revisionId = (done.result['comicHeads'] as Map?)?[id];
    final document = (done.result['comicDocuments'] as Map?)?[id];
    final result = <String, dynamic>{
      'taskId': done.id,
      'status': done.status.name,
      'saved':
          revisionId != null &&
          document != null &&
          !(done.result['comicCandidates'] as List? ?? []).contains(id),
      'chapterId': id,
      'revisionId': revisionId,
      'document': document,
      if (done.status != TaskStatus.completed)
        'error': done.error.isEmpty ? '任务未完成，请查看任务后继续；不会重复提交。' : done.error,
    };
    final latest = await repository.getTask(task.id);
    await repository.updateTask(
      task.id,
      status: TaskStatus.running,
      result: {
        'agentComicCalls': {
          ...?(latest.result['agentComicCalls'] as Map?),
          key: {'signature': signature, 'taskId': done.id, 'result': result},
        },
      },
    );
    return remember(result);
  }
}
