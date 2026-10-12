import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../agent/writing_service.dart';
import '../assets/asset_library.dart';
import '../model/asset.dart';
import '../providers/image_provider.dart';

import '../model/manuscript.dart';
import '../model/task.dart';
import '../providers/provider.dart';
import '../providers/remote_provider.dart';
import '../st/import_types.dart';
import '../st/card_importer.dart';
import '../st/preset_importer.dart';
import '../st/macro_engine.dart';
import '../st/regex_pipeline.dart';
import '../st/world_book_engine.dart';
import '../st/world_book.dart';
import '../storage/story_repository.dart';

part 'agent_runner.dart';
part 'illustration_runner.dart';

typedef ProviderFactory = Future<ModelProvider> Function(
  ModelConnection connection,
);
typedef ImageProviderFactory = Future<ImageProvider> Function(
  ModelConnection connection,
);

final class TaskRunner {
  TaskRunner({
    required this.repository,
    required this.providerFactory,
    this.imageProviderFactory,
    this.assetLibrary,
  });
  final StoryRepository repository;
  final ProviderFactory providerFactory;
  final ImageProviderFactory? imageProviderFactory;
  final AssetLibrary? assetLibrary;
  final _running = <String, Future<void>>{};
  final _cancellations = <String, GenerationCancellation>{};
  bool _closing = false;

  Future<int> recoverInterrupted() {
    if (_running.isNotEmpty) throw StateError('运行中不能恢复旧任务');
    return repository.recoverInterruptedTasks();
  }

  Future<GenerationTask> start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
    String? sceneId,
    String? baseRevisionId,
    String? retryOf,
  }) async {
    if (_closing) throw StateError('任务执行器已关闭');
    final task = await repository.createTask(
      branchId: branchId,
      kind: kind,
      input: input,
      sceneId: sceneId,
      baseRevisionId: baseRevisionId,
      retryOf: retryOf,
    );
    return _launch(task);
  }

  Future<GenerationTask> _launch(GenerationTask task) async {
    if (_closing) throw StateError('任务执行器已关闭');
    final cancel = GenerationCancellation();
    _cancellations[task.id] = cancel;
    final future = _execute(task, cancel);
    _running[task.id] = future;
    unawaited(
      future.whenComplete(() {
        _running.remove(task.id);
        _cancellations.remove(task.id);
      }),
    );
    return task;
  }

  Future<GenerationTask> wait(String id) async {
    await _running[id];
    return repository.getTask(id);
  }

  Future<void> cancel(String id) async {
    final task = await repository.getTask(id);
    if (task.isRemote) {
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
      await repository.acknowledgeRemoteCancellation(id);
      return;
    }
    _cancellations[id]?.cancel();
    await repository.updateTask(id, status: TaskStatus.cancelled);
  }

  Future<GenerationTask> reconnectRemote(String id) async {
    if (_closing) throw StateError('任务执行器已关闭');
    if (_running.containsKey(id)) return repository.getTask(id);
    return _launch(await repository.requeueRemoteTask(id));
  }

  /// Retry explicitly starts a new network request and a new durable task. It
  /// never pretends a broken stream can be resumed or silently retries billing.
  Future<GenerationTask> resume(String id) async {
    final old = await repository.getTask(id);
    if (old.isActive || old.status == TaskStatus.completed) {
      throw StateError('此任务无需重新生成');
    }
    return start(
      branchId: old.branchId,
      kind: old.kind,
      input: old.input,
      sceneId: old.sceneId,
      baseRevisionId: old.baseRevisionId,
      retryOf: old.id,
    );
  }

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
    ModelProvider? provider;
    final text = StringBuffer(), reasoning = StringBuffer();
    try {
      final current = await repository.updateTask(
        task.id,
        status: TaskStatus.running,
      );
      if (current.status != TaskStatus.running) return;
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
      GenerationFinished? finish;
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
        await repository.updateTask(
          task.id,
          status: TaskStatus.running,
          partialText: text.toString(),
          reasoning: reasoning.toString(),
        );
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
      if (text.toString().trim().isEmpty) {
        throw const ProviderException('empty_output', '模型没有返回正文内容');
      }
      if ([TaskKind.writing, TaskKind.rewrite].contains(task.kind)) {
        final processed = _processOutput(task, text.toString());
        reasoning.write(processed.reasoning);
        final original = input['originalContent'] == null
            ? ManuscriptContent.plainText('')
            : ManuscriptContent.fromJson(
                jsonObject(input['originalContent'], 'originalContent'),
              );
        final range = input['replacementRange'] as Map<String, dynamic>?;
        final content = range != null
            ? original.replaceRange(
                range['start'] as int,
                range['end'] as int,
                processed.text,
              )
            : input['append'] == true && original.text.trim().isNotEmpty
            ? ManuscriptContent.fromDelta([
                ...original.delta,
                {'insert': '\n${processed.text}\n'},
              ])
            : ManuscriptContent.plainText(processed.text);
        await repository.completeWritingTask(
          task.id,
          content: content,
          rawText: text.toString(),
          reasoning: reasoning.toString(),
          summary: input['brief'] as String? ?? '',
          variableResult: processed.variables,
        );
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
        partialText: text.toString(),
        reasoning: reasoning.toString(),
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
        partialText: text.toString(),
        reasoning: reasoning.toString(),
        error: error.toString(),
      );
    } on FormatException {
      await repository.updateTask(
        task.id,
        status: TaskStatus.failed,
        partialText: text.toString(),
        reasoning: reasoning.toString(),
        error: '返回结果未满足格式要求，原始输出已保留。',
      );
    } catch (_) {
      await repository.updateTask(
        task.id,
        status: TaskStatus.failed,
        partialText: text.toString(),
        reasoning: reasoning.toString(),
        error: '生成未完成，请检查模型配置后重试。',
      );
    } finally {
      provider?.close();
    }
  }
}

({String text, String reasoning, Map<String, dynamic> variables})
_processOutput(GenerationTask task, String text) {
  final input = task.input;
  final variables = input['variableResult'] as Map<String, dynamic>? ?? {};
  final macro = MacroEngine(
    values: (input['macroValues'] as Map? ?? {}).cast<String, String>(),
    clock: DateTime.parse(input['clock'] as String),
    seed: input['seed'] as int,
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
  } else if (result['entries'] is! List) {
    throw const FormatException('分析缺少 entries');
  }
  return result;
}
