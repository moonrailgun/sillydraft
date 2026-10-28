import 'dart:async';
import 'dart:convert';
import 'dart:math' show max, min;
import 'dart:typed_data';

import '../agent/editor_agent.dart';
import '../agent/illustration_service.dart';
import '../agent/sidecar_agent.dart';
import '../agent/skills.dart';
import '../agent/writing_service.dart';
import '../assets/asset_library.dart';
import '../model/asset.dart';
import '../providers/image_provider.dart';

import '../model/lore.dart';
import '../model/manuscript.dart';
import '../model/story.dart';
import '../model/task.dart';
import '../mvu/mvu_data.dart';
import '../providers/provider.dart';
import '../providers/remote_provider.dart';
import '../st/import_types.dart';
import '../st/card_importer.dart';
import '../st/preset_importer.dart';
import '../st/regex_pipeline.dart';
import '../st/world_book_engine.dart';
import '../st/world_book.dart';
import '../storage/story_repository.dart';

part 'agent_runner.dart';
part 'agent_compaction.dart';
part 'illustration_runner.dart';
part 'sidecar_runner.dart';
part 'writing_quality.dart';

typedef ProviderFactory = Future<ModelProvider> Function(
  ModelConnection connection,
);
typedef ImageProviderFactory = Future<ImageProvider> Function(
  ModelConnection connection,
);

/// Saves streamed progress at most every [interval]: each save refreshes
/// every task view, and a chapter streams thousands of deltas.
// ponytail: no timer, so text from just before a pause shows with the next
// delta (or [flush]); add a trailing timer if pauses leave views stale.
final class _ProgressSaver {
  _ProgressSaver(this._save);
  static const interval = Duration(milliseconds: 250);
  final Future<void> Function() _save;
  final _sinceSave = Stopwatch();
  bool _pending = false;

  Future<void> save() async {
    if (_sinceSave.isRunning && _sinceSave.elapsed < interval) {
      _pending = true;
      return;
    }
    await _write();
  }

  /// Saves what [save] held back, if anything.
  Future<void> flush() async {
    if (_pending) await _write();
  }

  Future<void> _write() {
    _pending = false;
    _sinceSave
      ..reset()
      ..start();
    return _save();
  }
}

/// What services and screens need from task execution. [TaskRunner] runs
/// tasks in this process; a remote library hands them to the desktop.
abstract interface class TaskControl {
  ProviderFactory get providerFactory;
  ImageProviderFactory? get imageProviderFactory;
  AssetLibrary? get assetLibrary;
  Future<int> recoverInterrupted();
  Future<GenerationTask> start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? chapterId,
    String? baseRevisionId,
    String? retryOf,
  });
  Future<GenerationTask> wait(String id);
  Future<void> cancel(String id);
  Future<GenerationTask> reconnectRemote(String id);
  Future<GenerationTask> resume(String id);

  /// An answer applies only to this pending request, never a later tool call.
  Future<bool> respondToImageConfirmation(
    String taskId,
    String confirmationId, {
    required bool approved,
  });
  Future<void> close();
}

final class TaskRunner implements TaskControl {
  TaskRunner({
    required this.repository,
    required this.providerFactory,
    this.imageProviderFactory,
    this.assetLibrary,
  });
  final StoryRepository repository;
  @override
  final ProviderFactory providerFactory;
  @override
  final ImageProviderFactory? imageProviderFactory;
  @override
  final AssetLibrary? assetLibrary;
  final _running = <String, Future<void>>{};
  final _agentTails = <String, Future<void>>{};
  final _cancellations = <String, GenerationCancellation>{};

  /// Streamed progress not yet saved, flushed before a stop marks the task
  /// done: the runner's own final save is ignored once it is.
  final _progress = <String, _ProgressSaver>{};
  final _imageConfirmations = <String, ({String id, Completer<bool> answer})>{};
  int _imageConfirmationSequence = 0;
  bool _closing = false;

  @override
  Future<bool> respondToImageConfirmation(
    String taskId,
    String confirmationId, {
    required bool approved,
  }) async {
    final pending = _imageConfirmations[taskId];
    if (pending == null ||
        pending.id != confirmationId ||
        pending.answer.isCompleted ||
        _cancellations[taskId]?.isCancelled != false) {
      return false;
    }
    _imageConfirmations.remove(taskId);
    pending.answer.complete(approved);
    return true;
  }

  @override
  Future<int> recoverInterrupted() {
    if (_running.isNotEmpty) throw StateError('运行中不能恢复旧任务');
    return repository.recoverInterruptedTasks();
  }

  @override
  Future<GenerationTask> start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? chapterId,
    String? baseRevisionId,
    String? retryOf,
  }) async {
    if (_closing) throw StateError('任务执行器已关闭');
    final task = await repository.createTask(
      branchId: branchId,
      kind: kind,
      input: input,
      chapterId: chapterId,
      baseRevisionId: baseRevisionId,
      retryOf: retryOf,
    );
    return _launch(task);
  }

  Future<GenerationTask> _launch(GenerationTask task) async {
    if (_closing) throw StateError('任务执行器已关闭');
    final cancel = GenerationCancellation();
    _cancellations[task.id] = cancel;
    final conversation = task.kind == TaskKind.agent
        ? task.input['conversationId'] as String?
        : null;
    final previous = _agentTails[conversation];
    final future = _executeQueued(task, cancel, previous);
    if (conversation != null) {
      // Cancelling a waiting turn must not let its successor skip the head.
      final tail = Future.wait<void>([?previous, future]).then((_) {});
      _agentTails[conversation] = tail;
      unawaited(
        tail.then((_) {
          if (identical(_agentTails[conversation], tail)) {
            _agentTails.remove(conversation);
          }
        }),
      );
    }
    _running[task.id] = future;
    unawaited(
      future.whenComplete(() {
        _running.remove(task.id);
        _cancellations.remove(task.id);
        _progress.remove(task.id);
      }),
    );
    return task;
  }

  Future<void> _executeQueued(
    GenerationTask task,
    GenerationCancellation cancel,
    Future<void>? previous,
  ) async {
    if (previous != null) {
      final cancelled = Completer<void>();
      final remove = cancel.onCancel(() => cancelled.complete());
      try {
        await Future.any([previous, cancelled.future]);
      } finally {
        remove();
      }
    }
    await _execute(task, cancel);
  }

  @override
  Future<GenerationTask> wait(String id) async {
    await _running[id];
    return repository.getTask(id);
  }

  @override
  Future<void> cancel(String id) async {
    final task = await repository.getTask(id, snapshots: false);
    if (task.isRemote && task.input['agentMessage'] == null) {
      final config = ModelConnection.fromJson(
        jsonObject(task.input['connection'], 'connection'),
      );
      final provider = await providerFactory(config);
      try {
        if (provider is! RemoteJobControl) throw StateError('连接不支持远程取消确认');
        await (provider as RemoteJobControl).cancelRemote(id);
      } finally {
        provider.close();
      }
      _cancellations[id]?.cancel();
      await _progress[id]?.flush();
      await repository.acknowledgeRemoteCancellation(id);
      return;
    }
    _cancellations[id]?.cancel();
    await _progress[id]?.flush();
    await repository.updateTask(id, status: TaskStatus.cancelled);
  }

  @override
  Future<GenerationTask> reconnectRemote(String id) async {
    if (_closing) throw StateError('任务执行器已关闭');
    if (_running.containsKey(id)) return repository.getTask(id);
    return _launch(await repository.requeueRemoteTask(id));
  }

  /// Retry explicitly starts a new network request and a new durable task. It
  /// never pretends a broken stream can be resumed or silently retries billing.
  @override
  Future<GenerationTask> resume(String id) async {
    final old = await repository.getTask(id);
    if (old.isActive || old.status == TaskStatus.completed) {
      throw StateError('此任务无需重新生成');
    }
    return start(
      branchId: old.branchId,
      kind: old.kind,
      input: old.input,
      chapterId: old.chapterId,
      baseRevisionId: old.baseRevisionId,
      retryOf: old.id,
    );
  }

  @override
  Future<void> close() async {
    _closing = true;
    for (final cancel in _cancellations.values) {
      cancel.cancel();
    }
    await Future.wait(_running.values.toList());
  }

  Future<void> _execute(
    GenerationTask task,
    GenerationCancellation cancel,
  ) async {
    // Tool loops keep their text as it streams, not the durable snapshot.
    final looped = const {TaskKind.agent, TaskKind.sidecar}.contains(task.kind);
    ModelProvider? provider;
    final text = StringBuffer(), reasoning = StringBuffer();
    final reconnect = task.isRemote && task.result['remoteReconnect'] == true;
    var durableText = reconnect ? task.partialText : '';
    var durableReasoning = reconnect ? task.reasoning : '';
    // Recovery replays cumulative output from the beginning. Keep the last
    // durable snapshot until the replay catches up; never prepend it to replay.
    String snapshot(String previous, String replay) {
      if (!reconnect) return replay;
      if (previous.startsWith(replay)) return previous;
      if (!replay.startsWith(previous)) {
        throw const ProviderException(
          'remote_mismatch',
          '远程内容与已保存的输出不一致，原内容已保留',
        );
      }
      return replay;
    }

    try {
      cancel.check();
      final current =
          task.kind == TaskKind.agent && task.input['pendingAgent'] != null
          ? await repository.prepareAgentTask(task.id, () async {
              final Map<String, dynamic> input;
              try {
                input = await EditorAgent(
                  repository: repository,
                  runner: this,
                ).prepare(task);
              } on FormatException catch (error) {
                throw ProviderException(
                  'preparation_failed',
                  '发送前准备失败：${error.message}\n'
                      '请检查预设配置后重试；本次尚未请求模型，待发送内容已保留。',
                );
              }
              cancel.check();
              return input;
            })
          : await repository.updateTask(task.id, status: TaskStatus.running);
      if (current.status != TaskStatus.running) return;
      if (task.input['pendingAgent'] != null) task = current;
      cancel.check();
      if (task.kind == TaskKind.illustration) {
        await _executeIllustration(task, cancel);
        return;
      }
      final input = task.input;
      final connection = ModelConnection.fromJson(
        jsonObject(input['connection'], 'connection'),
      );
      final request = ProviderRequest.fromJson({
        ...jsonObject(input['request'], 'request'),
        if (task.isRemote) 'executionId': task.id,
        if (task.isRemote)
          'retrieveOnly': task.result['remoteReconnect'] == true,
      });
      provider = await providerFactory(connection);
      final diagnostics = provider.validateParameters(request);
      await repository.updateTask(
        task.id,
        status: TaskStatus.running,
        result: {'diagnostics': diagnostics.map((d) => d.toJson()).toList()},
      );
      if (diagnostics.any((d) => d.severity == DiagnosticSeverity.error)) {
        throw ProviderException(
          'unsupported_configuration',
          diagnostics
              .where((d) => d.severity == DiagnosticSeverity.error)
              .map((d) => d.message)
              .join('\n'),
        );
      }
      if (task.kind == TaskKind.agent) {
        await _executeAgent(task, provider, cancel, text, reasoning);
        return;
      }
      if (task.kind == TaskKind.sidecar) {
        await _executeSidecar(task, provider, cancel, text, reasoning);
        return;
      }
      GenerationFinished? finish;
      // Completion and every failure path save the full text themselves.
      final progress = _progress[task.id] = _ProgressSaver(
        () => repository.saveTaskProgress(
          task.id,
          partialText: durableText,
          reasoning: durableReasoning,
        ),
      );
      await for (final event in provider.generate(
        request,
        cancellation: cancel,
      )) {
        cancel.check();
        switch (event) {
          case TextDelta():
            text.write(event.text);
          case ReasoningDelta():
            reasoning.write(event.text);
          case ToolCallReady():
            throw const ProviderException('unexpected_tool', '正文生成不允许调用编辑工具');
          case GenerationFinished():
            finish = event;
        }
        durableText = snapshot(durableText, text.toString());
        durableReasoning = snapshot(durableReasoning, reasoning.toString());
        await progress.save();
      }
      cancel.check();
      if (finish == null) {
        throw const ProviderException('interrupted', '连接未提供完成标志');
      }
      if (!finish.isComplete) {
        throw ProviderException(
          'incomplete',
          '模型未完整结束（${finish.reason}），部分内容已保留',
        );
      }
      if (reconnect &&
          (text.length < durableText.length ||
              reasoning.length < durableReasoning.length)) {
        throw const ProviderException(
          'remote_mismatch',
          '远程完整结果短于已保存的输出，原内容已保留',
        );
      }
      if (text.toString().trim().isEmpty) {
        throw const ProviderException('empty_output', '模型没有返回正文内容');
      }
      if ([TaskKind.writing, TaskKind.rewrite].contains(task.kind)) {
        final processed = _processOutput(task, text.toString());
        reasoning.write(processed.reasoning);
        final mvuEnabled = input['mvu'] is Map;
        final original = input['originalContent'] == null
            ? ManuscriptContent.plainText('')
            : ManuscriptContent.fromJson(
                jsonObject(input['originalContent'], 'originalContent'),
              );
        var outputText = mvuEnabled
            ? stripMvuMarkup(processed.text).trimRight()
            : processed.text;
        if (input['qualityReview'] == true) {
          await progress.flush();
          outputText = await _reviewWriting(task, provider, cancel, outputText);
          cancel.check();
        }
        final range = input['replacementRange'] as Map<String, dynamic>?;
        var content = range != null
            ? original.replaceRange(
                range['start'] as int,
                range['end'] as int,
                outputText,
              )
            : input['append'] == true && original.text.trim().isNotEmpty
            ? ManuscriptContent.fromDelta([
                ...original.delta,
                {'insert': '\n$outputText\n'},
              ])
            : ManuscriptContent.plainText(outputText);
        var variables = processed.variables;
        Map<String, dynamic>? mvuResult;
        if (mvuEnabled) {
          // One status bar per chapter: the placeholder MVU appends moves to
          // the end of the chapter, and the model's own copy of the state
          // listing is dropped, as MVU strips it from the saved message.
          content = _withoutMvuMarkup(content);
          final applied = _applyMvu(task, content.text, variables);
          content = ManuscriptContent.fromDelta([
            ...content.delta,
            {
              'insert': content.text.endsWith('\n')
                  ? '\n$mvuStatusPlaceholder\n'
                  : '\n\n$mvuStatusPlaceholder\n',
            },
          ]);
          variables = applied.variables;
          mvuResult = applied.result;
        }
        final done = await repository.completeWritingTask(
          task.id,
          content: content,
          rawText: text.toString(),
          reasoning: reasoning.toString(),
          summary: input['brief'] as String? ?? '',
          variableResult: variables,
          mvuResult: mvuResult,
        );
        // Accepting commits the chapter's story state with it, so each chapter
        // written this way keeps its own snapshot to fork or roll back to.
        // A conflict leaves the candidate for the author to review.
        final proposal = done.result['proposalId'];
        if (input['autoAccept'] == true && proposal is String) {
          try {
            await repository.acceptProposal(proposal);
          } on Object catch (_) {}
        }
      } else {
        final result = _structuredResult(task.kind, text.toString());
        await repository.updateTask(
          task.id,
          status: TaskStatus.completed,
          partialText: text.toString(),
          reasoning: reasoning.toString(),
          result: result,
        );
      }
    } on GenerationCancelled {
      await repository.updateTask(
        task.id,
        status: _closing ? TaskStatus.interrupted : TaskStatus.cancelled,
        partialText: looped ? text.toString() : durableText,
        reasoning: looped ? reasoning.toString() : durableReasoning,
        error: _closing
            ? (task.isRemote ? '本地连接已关闭，远程任务可能仍在执行，可获取同一任务的结果。' : '应用关闭，生成已中断。')
            : '',
      );
    } on ProviderException catch (error) {
      await repository.updateTask(
        task.id,
        status: error.code == 'interrupted'
            ? TaskStatus.interrupted
            : TaskStatus.failed,
        partialText: looped ? text.toString() : durableText,
        reasoning: looped ? reasoning.toString() : durableReasoning,
        error: error.toString(),
      );
    } on FormatException {
      await repository.updateTask(
        task.id,
        status: TaskStatus.failed,
        partialText: looped ? text.toString() : durableText,
        reasoning: looped ? reasoning.toString() : durableReasoning,
        error: '返回结果未满足格式要求，原始输出已保留。',
      );
    } catch (_) {
      await repository.updateTask(
        task.id,
        status: TaskStatus.failed,
        partialText: looped ? text.toString() : durableText,
        reasoning: looped ? reasoning.toString() : durableReasoning,
        error: '生成未完成，请检查模型配置后重试。',
      );
    } finally {
      provider?.close();
    }
  }
}

ManuscriptContent _withoutMvuMarkup(ManuscriptContent content) {
  if (!hasMvuMarkup(content.text)) return content;
  return ManuscriptContent.fromDelta([
    for (final op in content.delta)
      if (op['insert'] is String)
        {...op, 'insert': stripMvuMarkup(op['insert'] as String)}
      else
        op,
  ]);
}

/// Derives the chapter's MVU record from the task's base record and the
/// final chapter text, as MVU re-reads a message once the reply has landed.
({Map<String, dynamic> variables, Map<String, dynamic> result}) _applyMvu(
  GenerationTask task,
  String chapterText,
  Map<String, dynamic> variables,
) {
  final input = task.input;
  final base = jsonObject(jsonObject(input['mvu'], 'mvu')['base'], 'mvu.base');
  final data = MvuData.fromJson(base);
  final macro = task.macros(message: chapterText);
  final result = MvuUpdater.apply(chapterText, data, substitute: macro.render);
  final local = (variables['local'] as Map? ?? {}).cast<String, String>();
  return (
    variables: {
      ...variables,
      'local': {...local, ...data.toStored()},
    },
    result: {
      'modified': result.modified,
      'commands': result.commands.map((c) => c.toJson()).toList(),
      'errors': result.errors,
    },
  );
}

({String text, String reasoning, Map<String, dynamic> variables})
_processOutput(GenerationTask task, String text) {
  final input = task.input;
  final variables = input['variableResult'] as Map<String, dynamic>? ?? {};
  final macro = task.macros(
    local: (variables['local'] as Map? ?? {}).cast<String, String>(),
    global: (variables['global'] as Map? ?? {}).cast<String, String>(),
  );
  var output = text;
  var reasoning = '';
  final format = input['reasoningFormat'] as Map<String, dynamic>?;
  if (format != null) {
    final prefix = stringField(format, 'prefix'),
        suffix = stringField(format, 'suffix');
    final trimmed = output.trimLeft();
    if (prefix.isNotEmpty && suffix.isNotEmpty && trimmed.startsWith(prefix)) {
      final end = trimmed.indexOf(suffix, prefix.length);
      if (end < 0) {
        throw const ProviderException(
          'incomplete_reasoning',
          '推理格式未闭合，结果保留为部分输出',
        );
      }
      reasoning = trimmed.substring(prefix.length, end);
      output = trimmed.substring(end + suffix.length);
      final separator = stringField(format, 'separator');
      if (separator.isNotEmpty && output.startsWith(separator)) {
        output = output.substring(separator.length);
      }
    }
  }
  final pipeline = RegexPipeline(
    preset: (input['outputRegex'] as List? ?? []).cast<Map<String, dynamic>>(),
  );
  output = pipeline.apply(
    output,
    placement: 2,
    stage: RegexStage.general,
    macros: macro,
    depth: 0,
  );
  final errors = [
    ...macro.diagnostics,
    ...pipeline.diagnostics,
  ].where((d) => d.severity == DiagnosticSeverity.error);
  if (errors.isNotEmpty) {
    throw ProviderException(
      'output_rules',
      errors.map((d) => d.message).join('\n'),
    );
  }
  return (
    text: output.trim(),
    reasoning: reasoning,
    variables: {'local': macro.local, 'global': macro.global},
  );
}

Map<String, dynamic> _structuredResult(TaskKind kind, String text) {
  if (kind != TaskKind.branches && kind != TaskKind.analysis) {
    return {'text': text};
  }
  final cleaned = text
      .trim()
      .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
      .replaceFirst(RegExp(r'\s*```$'), '');
  final result = jsonObject(jsonDecode(cleaned), 'result');
  if (kind == TaskKind.branches) {
    final candidates = result['candidates'];
    if (candidates is! List || candidates.length < 2 || candidates.length > 6) {
      throw const FormatException('候选数量无效');
    }
    for (final value in candidates) {
      final candidate = jsonObject(value, 'candidate');
      for (final key in ['title', 'summary', 'opening']) {
        if (stringField(candidate, key).trim().isEmpty) {
          throw FormatException('候选缺少 $key');
        }
      }
    }
    if (result.containsKey('recommendation')) {
      final recommendation = jsonObject(
        result['recommendation'],
        'recommendation',
      );
      final index = recommendation['index'];
      if (index is! int ||
          index < 0 ||
          index >= candidates.length ||
          stringField(recommendation, 'reason').trim().isEmpty) {
        throw const FormatException('候选推荐无效');
      }
    }
  } else if (result['entries'] is! List) {
    throw const FormatException('分析缺少 entries');
  }
  return result;
}
