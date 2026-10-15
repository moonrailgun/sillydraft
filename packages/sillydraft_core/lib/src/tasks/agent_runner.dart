part of 'task_runner.dart';

const _editingTools = <Map<String, dynamic>>[
  {
    'type': 'function',
    'function': {
      'name': 'list_lore',
      'description': '列出当前分支在编辑位置已可见的旁路资料，包括确定程度与是否待复核。',
      'parameters': {
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'read_lore',
      'description': '按 ID 读取当前编辑位置的旁路资料。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
        'required': ['id'],
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'propose_lore',
      'description': '提出一条待作者审阅的资料建议。不会直接修改资料；sourceChapterId 必须是可见章节。关系须提供已有资料的 fromId/toId。',
      'parameters': {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'enum': [
              'character',
              'world',
              'organization',
              'item',
              'location',
              'event',
              'foreshadow',
              'relationship',
            ],
          },
          'name': {'type': 'string'},
          'content': {'type': 'string'},
          'certainty': {
            'type': 'string',
            'enum': ['fact', 'plan', 'inference'],
          },
          'sourceChapterId': {'type': 'string'},
          'fromId': {'type': 'string'},
          'toId': {'type': 'string'},
          'directed': {'type': 'boolean'},
        },
        'required': ['kind', 'name', 'content', 'certainty', 'sourceChapterId'],
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'list_chapters',
      'description': '列出当前分支的章节和版本',
      'parameters': {
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'read_chapter',
      'description': '读取当前分支指定章节的正文',
      'parameters': {
        'type': 'object',
        'properties': {
          'chapterId': {'type': 'string'},
        },
        'required': ['chapterId'],
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'search_story',
      'description': '在当前编辑位置及此前的正文中查找词句（不区分大小写），返回所在章节、位置和前后文片段。',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string'},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'propose_chapter',
      'description': '用独立写作模型生成正文候选，供作者审阅。不会直接修改正文。',
      'parameters': {
        'type': 'object',
        'properties': {
          'chapterId': {'type': 'string'},
          'instructions': {'type': 'string'},
          'append': {'type': 'boolean'},
        },
        'required': ['chapterId', 'instructions', 'append'],
        'additionalProperties': false,
      },
    },
  },
];

/// NovelAI always takes a negative prompt; another engine only when the
/// author already sends one, which shows the endpoint accepts it.
bool _takesNegative(Map<String, dynamic> image) =>
    (image['connection'] as Map)['protocol'] == ModelProtocol.novelAI.name ||
    ((image['defaults'] as Map?)?['parameters'] as Map?)?.containsKey(
          'negative_prompt',
        ) ==
        true;

Map<String, dynamic> _imageTool(Map<String, dynamic> image) => {
  'type': 'function',
  'function': {
    'name': 'generate_image',
    'description': '先展示提示词等待作者确认，再用配置的生图引擎生成一张插图并存入作品资产库。作者取消时不要自动重试。',
    'parameters': {
      'type': 'object',
      'properties': {
        'prompt': {'type': 'string', 'description': '提交给生图引擎的提示词'},
        if (_takesNegative(image))
          'negative_prompt': {
            'type': 'string',
            'description': '负面提示词，填写时替换作者默认的负面提示词',
          },
        'name': {'type': 'string', 'description': '图片的简短名称'},
      },
      'required': ['prompt', 'name'],
      'additionalProperties': false,
    },
  },
};

extension _AgentExecution on TaskRunner {
  Future<void> _executeAgent(
    GenerationTask task,
    ModelProvider provider,
    GenerationCancellation cancel,
    StringBuffer output,
    StringBuffer reasoning,
  ) async {
    final input = task.input;
    final conversation = input['conversationId'] as String;
    if (await repository.conversationBranch(conversation) != task.branchId) {
      throw const FormatException('会话不属于任务分支');
    }
    final skills = [
      for (final s in input['skills'] as List? ?? const [])
        AgentSkill.fromJson(s as Map<String, dynamic>),
    ];
    await _toolLoop(
      task,
      provider,
      cancel,
      output,
      reasoning,
      tools: [
        ..._editingTools,
        if (input['image'] case final Map<String, dynamic> image)
          _imageTool(image),
        ...skillTools(skills),
      ],
      execute: (call) => _executeTool(task, call, cancel),
      record: (role, content, metadata) => repository.appendAgentMessage(
        conversation,
        role: role,
        content: content,
        metadata: metadata,
      ),
    );
  }

  /// Rounds of model output and tool calls until the model answers without
  /// any. [record] keeps each message durable as it lands: the conversation
  /// for the editor, the task's transcript for the sidecar. [name] is what
  /// errors call the run.
  Future<void> _toolLoop(
    GenerationTask task,
    ModelProvider provider,
    GenerationCancellation cancel,
    StringBuffer output,
    StringBuffer reasoning, {
    required List<Map<String, dynamic>> tools,
    required Future<Map<String, dynamic>> Function(ToolCallReady call) execute,
    required Future<void> Function(
      String role,
      String content,
      Map<String, dynamic> metadata,
    )
    record,
    String overflow = '编辑会话超出上下文限制，请创建新会话',
    String name = '编辑',
  }) async {
    final request = ProviderRequest.fromJson(
      jsonObject(task.input['request'], 'request'),
    );
    final messages = request.messages;
    for (var round = 0; round < 8; round++) {
      cancel.check();
      if (estimateTokens(jsonEncode(messages)) +
              provider.config.maxOutputTokens >
          provider.config.contextWindow) {
        throw ProviderException('context_limit', overflow);
      }
      final text = StringBuffer();
      final calls = <ToolCallReady>[];
      GenerationFinished? finished;
      final progress = _progress[task.id] = _ProgressSaver(
        () => repository.updateTask(
          task.id,
          status: TaskStatus.running,
          partialText: output.toString(),
          reasoning: reasoning.toString(),
          result: {'round': round + 1},
        ),
      );
      await for (final event in provider.generate(
        ProviderRequest(
          messages: messages,
          tools: tools,
          parameters: request.parameters,
        ),
        cancellation: cancel,
      )) {
        cancel.check();
        switch (event) {
          case TextDelta():
            text.write(event.text);
            output.write(event.text);
          case ReasoningDelta():
            reasoning.write(event.text);
          case ToolCallReady():
            calls.add(event);
          case GenerationFinished():
            finished = event;
        }
        await progress.save();
      }
      // Tool calls that follow keep the saved text, so it must be complete.
      await progress.flush();
      if (finished == null) {
        throw ProviderException('interrupted', '$name会话流中断');
      }
      if (!finished.isComplete) {
        throw ProviderException(
          'incomplete',
          '$name回复未完整结束：${finished.reason}',
        );
      }
      if (calls.isEmpty) {
        await record('assistant', text.toString(), const {});
        await repository.updateTask(
          task.id,
          status: TaskStatus.completed,
          partialText: output.toString(),
          reasoning: reasoning.toString(),
          result: {'text': text.toString(), 'rounds': round + 1},
        );
        return;
      }
      if (calls.length > 12) {
        throw const ProviderException('tool_limit', '单轮工具调用过多');
      }
      final seen = <String>{};
      final wireCalls = calls.map((c) => c.toOpenAI()).toList();
      await record('assistant', text.toString(), {'tool_calls': wireCalls});
      messages.add({
        'role': 'assistant',
        'content': text.toString(),
        'tool_calls': wireCalls,
      });
      for (final call in calls) {
        cancel.check();
        if (!seen.add(call.id)) {
          throw const ProviderException('duplicate_tool', '模型返回重复工具调用标识');
        }
        Map<String, dynamic> result;
        try {
          result = await execute(call);
        } on GenerationCancelled {
          rethrow;
        } catch (_) {
          result = {'error': '工具参数无效、目标不属于当前分支或操作未完成，请检查后再试。'};
        }
        cancel.check();
        var content = jsonEncode(result);
        if (content.length > 32000) {
          content = jsonEncode({
            'truncated': true,
            'preview': content.substring(0, 32000),
          });
        }
        await record('tool', content, {
          'tool_call_id': call.id,
          'tool_name': call.name,
          // Marks the conversation so later turns keep this skill loaded.
          if (call.name == 'activate_skill' && result['loaded'] == true)
            'skill': call.arguments['name'],
        });
        messages.add({
          'role': 'tool',
          'content': content,
          'tool_call_id': call.id,
        });
      }
    }
    throw ProviderException('round_limit', '$name任务达到 8 轮工具调用限制，已有结果已保留');
  }

  Future<Map<String, dynamic>> _executeTool(
    GenerationTask task,
    ToolCallReady call,
    GenerationCancellation cancel,
  ) async {
    final args = call.arguments;
    if (call.name == 'activate_skill' || call.name == 'read_skill_file') {
      return _skillTool(task, call);
    }
    final chapters = (task.input['chapterSnapshot'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final lore = (task.input['loreSnapshot'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (call.name == 'list_lore') {
      if (args.isNotEmpty) throw const FormatException('参数无效');
      return {
        'entries': [
          for (final e in lore)
            {
              for (final key in [
                'id',
                'name',
                'kind',
                'certainty',
                'sourceStale',
              ])
                key: e[key],
            },
        ],
      };
    }
    if (call.name == 'read_lore') {
      if (args.length != 1 || args['id'] is! String) {
        throw const FormatException('参数无效');
      }
      return lore.firstWhere((e) => e['id'] == args['id']);
    }
    if (call.name == 'propose_lore') {
      const required = [
        'kind',
        'name',
        'content',
        'certainty',
        'sourceChapterId',
      ];
      if (required.any(
            (key) =>
                args[key] is! String || (args[key] as String).trim().isEmpty,
          ) ||
          args.keys.any(
            (key) => ![...required, 'fromId', 'toId', 'directed'].contains(key),
          ) ||
          ![
            'character',
            'world',
            'organization',
            'item',
            'location',
            'event',
            'foreshadow',
            'relationship',
          ].contains(args['kind']) ||
          !['fact', 'plan', 'inference'].contains(args['certainty']) ||
          (args['name'] as String).length > 300 ||
          (args['content'] as String).length > 100000 ||
          !chapters.any((s) => s['id'] == args['sourceChapterId'])) {
        throw const FormatException('资料建议参数无效');
      }
      final data = <String, dynamic>{};
      if (args['kind'] == 'relationship') {
        final endpoints = await repository.listLore(
          task.branchId,
          throughChapterId: args['sourceChapterId'] as String,
        );
        if (args['fromId'] == args['toId'] ||
            ['fromId', 'toId'].any(
              (key) => !endpoints.any(
                (e) =>
                    e.id == args[key] &&
                    !['relationship', 'map'].contains(e.kind.name),
              ),
            ) ||
            (args.containsKey('directed') && args['directed'] is! bool)) {
          throw const FormatException('关系端点无效');
        }
        data.addAll({
          'fromId': args['fromId'],
          'toId': args['toId'],
          'directed': args['directed'] ?? true,
        });
      }
      if (!await repository.taskSourcesCurrent(task.id)) {
        throw const FormatException('正文已变化，请重新提出建议');
      }
      cancel.check();
      final proposal = await repository.createTask(
        branchId: task.branchId,
        kind: TaskKind.analysis,
        input: {
          'sourceRevisions': task.input['sourceRevisions'],
          'throughChapterId': task.input['throughChapterId'],
          'parentTaskId': task.id,
          'conversationId': task.input['conversationId'],
          'origin': 'editorSuggestion',
        },
      );
      await repository.updateTask(
        proposal.id,
        status: TaskStatus.completed,
        result: {
          'entries': [
            {for (final key in required) key: args[key], 'data': data},
          ],
        },
      );
      return {
        'taskId': proposal.id,
        'accepted': false,
        'message': '资料建议已保存，等待作者逐条审阅。',
      };
    }
    if (call.name == 'generate_image') {
      final image = task.input['image'];
      final prompt = args['prompt'], name = args['name'];
      final negative = args['negative_prompt'];
      if (image is! Map<String, dynamic> ||
          args.length != (args.containsKey('negative_prompt') ? 3 : 2) ||
          (negative != null &&
              (negative is! String || !_takesNegative(image))) ||
          prompt is! String ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 100) {
        throw const FormatException('参数无效');
      }
      final connection = ModelConnection.fromJson(
        jsonObject(image['connection'], 'image.connection'),
      );
      final saved = (image['defaults'] as Map? ?? {}).cast<String, dynamic>();
      final request = IllustrationService.requestFrom(connection, prompt, {
        ...saved,
        if (negative != null)
          'parameters': {
            ...?saved['parameters'] as Map?,
            'negative_prompt': negative,
          },
      });
      final confirmationId = '${task.id}:${++_imageConfirmationSequence}';
      final answer = Completer<bool>();
      _imageConfirmations[task.id] = (id: confirmationId, answer: answer);
      final removeConfirmation = cancel.onCancel(() {
        if (!answer.isCompleted) answer.complete(false);
      });
      bool approved;
      try {
        await repository.updateTask(
          task.id,
          status: TaskStatus.running,
          result: {
            'imageConfirmation': {
              'id': confirmationId,
              'name': name,
              'prompt': request.prompt,
              'negativePrompt': ?request.parameters['negative_prompt'],
            },
          },
        );
        approved = await answer.future;
      } finally {
        removeConfirmation();
        _imageConfirmations.remove(task.id);
        await repository.updateTask(
          task.id,
          status: TaskStatus.running,
          result: {'imageConfirmation': null},
        );
      }
      cancel.check();
      if (!approved) {
        return {'cancelled': true, 'message': '作者已取消本次生图，未调用生图引擎。请勿自动重试。'};
      }
      final child =
          await IllustrationService(
            repository: repository,
            runner: this,
          ).generate(
            branchId: task.branchId,
            connection: connection,
            name: name,
            request: request,
            chapterId: image['chapterId'] as String?,
          );
      final remove = cancel.onCancel(() => unawaited(this.cancel(child.id)));
      try {
        final result = await wait(child.id);
        cancel.check();
        return {
          'taskId': child.id,
          'status': result.status.name,
          'assetId': ?result.result['assetId'],
          if (result.error.isNotEmpty) 'error': result.error,
        };
      } finally {
        remove();
      }
    }
    if (call.name == 'list_chapters') {
      if (args.isNotEmpty) throw const FormatException('list_chapters 无参数');
      return {
        'chapters': [
          for (final chapter in chapters)
            {
              'id': chapter['id'],
              'title': chapter['title'],
              'revisionId': chapter['revisionId'],
              'canEdit': chapter['id'] == task.input['editChapterId'],
            },
        ],
      };
    }
    if (call.name == 'read_chapter') {
      if (args.keys.any((k) => k != 'chapterId') ||
          args['chapterId'] is! String) {
        throw const FormatException('参数无效');
      }
      final chapter = chapters.firstWhere((s) => s['id'] == args['chapterId']);
      return {
        'chapterId': chapter['id'],
        'revisionId': chapter['revisionId'],
        'title': chapter['title'],
        'text': chapter['text'],
      };
    }
    if (call.name == 'search_story') {
      final query = args['query'];
      if (args.keys.any((k) => k != 'query') ||
          query is! String ||
          query.trim().isEmpty) {
        throw const FormatException('参数无效');
      }
      final needle = query.trim().toLowerCase();
      final matches = <Map<String, dynamic>>[];
      var total = 0;
      for (final chapter in chapters) {
        final text = chapter['text'] as String, lower = text.toLowerCase();
        for (
          var at = lower.indexOf(needle);
          at >= 0;
          at = lower.indexOf(needle, at + needle.length)
        ) {
          total++;
          if (matches.length >= 30) continue;
          matches.add({
            'chapterId': chapter['id'],
            'title': chapter['title'],
            'offset': at,
            'snippet': text.substring(
              (at - 60).clamp(0, text.length),
              (at + needle.length + 60).clamp(0, text.length),
            ),
          });
        }
      }
      return {
        'query': query,
        'total': total,
        'matches': matches,
        if (total > matches.length) 'truncated': true,
      };
    }
    if (call.name == 'propose_chapter') {
      if (args.keys.any(
            (k) => !['chapterId', 'instructions', 'append'].contains(k),
          ) ||
          args['chapterId'] is! String ||
          args['instructions'] is! String ||
          args['append'] is! bool) {
        throw const FormatException('参数无效');
      }
      if (args['chapterId'] != task.input['editChapterId'] ||
          !await repository.taskSourcesCurrent(task.id)) {
        throw const FormatException('不属于当前编辑位置，或正文已变化');
      }
      final input = task.input;
      final service = WritingService(repository: repository, runner: this);
      final context = input['writingContext'] as Map<String, dynamic>? ?? {};
      final child = await service.generate(
        branchId: task.branchId,
        chapterId: args['chapterId'] as String,
        connection: ModelConnection.fromJson(
          jsonObject(input['writingConnection'], 'writingConnection'),
        ),
        brief: args['instructions'] as String,
        append: args['append'] as bool,
        userName: context['userName'] as String? ?? '我',
        persona: context['persona'] as String? ?? '',
        selectedOrderId: context['selectedOrderId'] as int?,
        worldBooks: [
          for (final book in (context['worldBooks'] as List? ?? []))
            ScopedWorldBook(
              WorldBook.fromJson(jsonObject(book['data'], '世界书')),
              branchId: book['branchId'] as String?,
              availableFromPosition: book['availableFromPosition'] as int? ?? 0,
            ),
        ],
        globalRegex: (context['globalRegex'] as List? ?? [])
            .cast<Map<String, dynamic>>(),
        preset: input['writingPreset'] is Map<String, dynamic>
            ? PresetImporter().decode(
                input['writingPreset'] as Map<String, dynamic>,
              )
            : null,
        card: input['card'] is Map<String, dynamic>
            ? CardImporter().decode(
                Uint8List.fromList(utf8.encode(jsonEncode(input['card']))),
                'card.json',
              )
            : null,
      );
      final remove = cancel.onCancel(() => unawaited(this.cancel(child.id)));
      try {
        final result = await wait(child.id);
        cancel.check();
        return {
          'taskId': child.id,
          'status': result.status.name,
          ...result.result,
          if (result.error.isNotEmpty) 'error': result.error,
          'accepted': false,
        };
      } finally {
        remove();
      }
    }
    throw const FormatException('未授权的工具');
  }

  /// Skill tools answer from the skill snapshot frozen into the task input.
  Map<String, dynamic> _skillTool(GenerationTask task, ToolCallReady call) {
    final args = call.arguments;
    final skills = [
      for (final s in task.input['skills'] as List? ?? const [])
        AgentSkill.fromJson(s as Map<String, dynamic>),
    ];
    final skill = skills
        .where((s) => s.modelInvocable && s.name == args['name'])
        .firstOrNull;
    if (skill == null) throw const FormatException('没有这个技能');
    if (call.name == 'activate_skill') {
      if (args.length != 1) throw const FormatException('参数无效');
      final active = (task.input['activeSkills'] as List? ?? const []);
      if (active.contains(skill.name)) {
        return {'loaded': false, 'note': '技能「${skill.name}」已在本会话中加载，无需重复加载。'};
      }
      return {'loaded': true, 'content': skillContent(skill)};
    }
    final path = args['path'];
    if (args.length != 2 || path is! String) {
      throw const FormatException('参数无效');
    }
    final text = skill.files[path.replaceFirst(RegExp(r'^\./'), '')];
    if (text != null) return {'path': path, 'content': text};
    return {
      'error': skill.unsupportedFiles.contains(path)
          ? '该文件是脚本或二进制，本应用不读取也不执行。'
          : '技能中没有这个文件。',
      'files': skill.files.keys.toList(),
    };
  }
}
