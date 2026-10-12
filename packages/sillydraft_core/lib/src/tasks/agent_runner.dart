part of 'task_runner.dart';

const _editingTools = <Map<String, dynamic>>[
  {
    'type': 'function',
    'function': {
      'name': 'list_scenes',
      'description': '列出当前分支的场景和版本',
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
      'name': 'read_scene',
      'description': '读取当前分支指定场景的正文',
      'parameters': {
        'type': 'object',
        'properties': {
          'sceneId': {'type': 'string'},
        },
        'required': ['sceneId'],
        'additionalProperties': false,
      },
    },
  },
  {
    'type': 'function',
    'function': {
      'name': 'propose_scene',
      'description': '用独立写作模型生成正文候选，供作者审阅。不会直接修改正文。',
      'parameters': {
        'type': 'object',
        'properties': {
          'sceneId': {'type': 'string'},
          'instructions': {'type': 'string'},
          'append': {'type': 'boolean'},
        },
        'required': ['sceneId', 'instructions', 'append'],
        'additionalProperties': false,
      },
    },
  },
];

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
    final request = ProviderRequest.fromJson(
      jsonObject(input['request'], 'request'),
    );
    final messages = request.messages;
    for (var round = 0; round < 8; round++) {
      cancel.check();
      if (estimateTokens(jsonEncode(messages)) +
              provider.config.maxOutputTokens >
          provider.config.contextWindow) {
        throw const ProviderException('context_limit', '编辑会话超出上下文限制，请创建新会话');
      }
      final text = StringBuffer();
      final calls = <ToolCallReady>[];
      GenerationFinished? finished;
      await for (final event in provider.generate(
        ProviderRequest(
          messages: messages,
          tools: _editingTools,
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
        await repository.updateTask(
          task.id,
          status: TaskStatus.running,
          partialText: output.toString(),
          reasoning: reasoning.toString(),
          result: {'round': round + 1},
        );
      }
      if (finished == null) {
        throw const ProviderException('interrupted', '编辑会话流中断');
      }
      if (!finished.isComplete) {
        throw ProviderException('incomplete', '编辑回复未完整结束：${finished.reason}');
      }
      if (calls.isEmpty) {
        await repository.appendAgentMessage(
          conversation,
          role: 'assistant',
          content: text.toString(),
        );
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
      await repository.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: text.toString(),
        metadata: {'tool_calls': wireCalls},
      );
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
          result = await _executeTool(task, call, cancel);
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
        await repository.appendAgentMessage(
          conversation,
          role: 'tool',
          content: content,
          metadata: {'tool_call_id': call.id, 'tool_name': call.name},
        );
        messages.add({
          'role': 'tool',
          'content': content,
          'tool_call_id': call.id,
        });
      }
    }
    throw const ProviderException('round_limit', '编辑任务达到 8 轮工具调用限制，已有结果已保留');
  }

  Future<Map<String, dynamic>> _executeTool(
    GenerationTask task,
    ToolCallReady call,
    GenerationCancellation cancel,
  ) async {
    final args = call.arguments;
    if (call.name == 'list_scenes') {
      if (args.isNotEmpty) throw const FormatException('list_scenes 无参数');
      final story = await repository.getStory(task.branchId);
      return {
        'scenes': [
          for (final scene in story.scenes)
            {
              'id': scene.id,
              'title': scene.title,
              'revisionId': scene.revisionId,
            },
        ],
      };
    }
    if (call.name == 'read_scene') {
      if (args.keys.any((k) => k != 'sceneId') || args['sceneId'] is! String) {
        throw const FormatException('参数无效');
      }
      final scene = await repository.getScene(
        branchId: task.branchId,
        sceneId: args['sceneId'] as String,
      );
      return {
        'sceneId': scene.id,
        'revisionId': scene.revisionId,
        'title': scene.title,
        'text': scene.content.text,
      };
    }
    if (call.name == 'propose_scene') {
      if (args.keys.any(
            (k) => !['sceneId', 'instructions', 'append'].contains(k),
          ) ||
          args['sceneId'] is! String ||
          args['instructions'] is! String ||
          args['append'] is! bool) {
        throw const FormatException('参数无效');
      }
      await repository.getScene(
        branchId: task.branchId,
        sceneId: args['sceneId'] as String,
      );
      final input = task.input;
      final service = WritingService(repository: repository, runner: this);
      final context = input['writingContext'] as Map<String, dynamic>? ?? {};
      final child = await service.generate(
        branchId: task.branchId,
        sceneId: args['sceneId'] as String,
        connection: ModelConnection.fromJson(
          jsonObject(input['writingConnection'], 'writingConnection'),
        ),
        brief: args['instructions'] as String,
        append: args['append'] as bool,
        userName: context['userName'] as String? ?? '主角',
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
}
