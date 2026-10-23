import 'dart:async';
import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

typedef _Script = Stream<ProviderEvent> Function(
  ProviderRequest,
  GenerationCancellation,
);

Future<({StoryRepository repo, TaskRunner runner, GenerationTask task})> _start(
  _Script script, {
  TaskKind kind = TaskKind.sidecar,
  int contextWindow = 200000,
  List<Map<String, dynamic>>? messages,
}) async {
  final repo = StoryRepository.memory();
  addTearDown(repo.close);
  final novel = await repo.createNovel(title: '长任务');
  final chapter = await repo.createChapter(
    branchId: novel.activeBranchId,
    content: ManuscriptContent.plainText('正文保持不变'),
  );
  final conversation = await repo.createConversation(
    branchId: novel.activeBranchId,
  );
  final connection = ModelConnection(
    id: 'test',
    name: 'test',
    baseUrl: 'http://localhost:1',
    model: 'test',
    contextWindow: contextWindow,
    maxOutputTokens: 512,
  );
  final runner = TaskRunner(
    repository: repo,
    providerFactory: (c) async => ScriptProvider(c, script),
  );
  addTearDown(runner.close);
  final task = await runner.start(
    branchId: novel.activeBranchId,
    chapterId: chapter.id,
    baseRevisionId: chapter.revisionId,
    kind: kind,
    input: {
      'connection': connection.raw,
      'conversationId': conversation,
      'duties': [SidecarDuty.memory.name],
      'request': ProviderRequest(
        messages:
            messages ??
            [
              {'role': 'system', 'content': '只整理现有资料'},
              {'role': 'user', 'content': '检查完整后再答复'},
            ],
      ).raw,
    },
  );
  return (repo: repo, runner: runner, task: task);
}

bool _isSummary(ProviderRequest request) =>
    request.executionId?.startsWith('agent-compaction-') == true;

List<Map<String, dynamic>> _history() => [
  {'role': 'system', 'content': '系统规则不可丢失'},
  {'role': 'user', 'content': '旧请求'},
  {'role': 'assistant', 'content': '旧资料' * 2000},
  {'role': 'user', 'content': '当前请求必须逐字保留'},
  {
    'role': 'assistant',
    'content': '',
    'tool_calls': [ToolCallReady('recent', 'list_lore', {}).toOpenAI()],
  },
  {'role': 'tool', 'tool_call_id': 'recent', 'content': '最近的完整工具结果'},
  {'role': 'developer', 'content': '末尾规则不可丢失'},
];

void _expectToolPairs(List<Map<String, dynamic>> messages) {
  final pending = <String>{};
  for (final message in messages) {
    if (message['role'] == 'tool') {
      expect(pending.remove(message['tool_call_id']), isTrue);
    } else {
      expect(pending, isEmpty);
      for (final call in message['tool_calls'] as List? ?? []) {
        pending.add(call['id'] as String);
      }
    }
  }
  expect(pending, isEmpty);
}

void main() {
  for (final kind in [TaskKind.agent, TaskKind.sidecar]) {
    test('$kind finishes after more than eight tool rounds', () async {
      var rounds = 0;
      final b = await _start((request, cancel) async* {
        expect(_isSummary(request), isFalse);
        if (++rounds <= 12) {
          yield ToolCallReady('call-$rounds', 'list_lore', {});
          yield const GenerationFinished('tool_calls');
        } else {
          yield const TextDelta('检查完成');
          yield const GenerationFinished('stop');
        }
      }, kind: kind);
      final done = await b.runner.wait(b.task.id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(done.result['rounds'], 13);
      expect(done.partialText, '检查完成');
    });
  }

  test(
    'compacts repeatedly, keeps rules and tool pairs, preserves raw records',
    () async {
      var summaries = 0, rounds = 0;
      final summaryInputs = <String>[];
      final requests = <ProviderRequest>[];
      final original = _history();
      final b = await _start(
        (request, cancel) async* {
          requests.add(request);
          if (_isSummary(request)) {
            summaryInputs.add(jsonEncode(request.messages));
            yield TextDelta('已检查的资料摘要${++summaries}，接下来继续核对');
            yield const GenerationFinished('stop');
            return;
          }
          if (++rounds <= 12) {
            yield TextDelta('待核对资料' * 250);
            yield ToolCallReady('call-$rounds', 'list_lore', {});
            yield const GenerationFinished('tool_calls');
          } else {
            yield const TextDelta('检查完成');
            yield const GenerationFinished('stop');
          }
        },
        contextWindow: 12000,
        messages: original,
      );
      final done = await b.runner.wait(b.task.id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(_isSummary(requests.first), isTrue);
      for (final request in requests) {
        if (_isSummary(request)) {
          expect(request.tools, isEmpty);
          continue;
        }
        expect(request.messages, contains(equals(original.first)));
        expect(request.messages, contains(equals(original[3])));
        expect(request.messages, contains(equals(original.last)));
        _expectToolPairs(request.messages);
        expect(
          estimateTokens(jsonEncode(request.messages)) +
              estimateTokens(jsonEncode(request.tools)) +
              512,
          lessThanOrEqualTo(12000),
        );
      }
      expect(summaries, greaterThan(1));
      expect(summaryInputs[1], contains('资料摘要1'));
      expect(done.input['request']['messages'], original);
      final transcript = (done.result['transcript'] as List).cast<Map>();
      expect(transcript.where((m) => m['role'] == 'tool'), hasLength(12));
      expect(
        transcript.where((m) => m['role'] == 'assistant').first['content'],
        '待核对资料' * 250,
      );
      expect(done.partialText, isNot(contains('资料摘要')));
    },
  );

  test(
    'current user request allows an older large reply to be compressed',
    () async {
      var summaries = 0;
      final b = await _start(
        (request, cancel) async* {
          if (_isSummary(request)) {
            summaries++;
            yield const TextDelta('之前已完成资料核对');
          } else {
            yield const TextDelta('继续完成');
          }
          yield const GenerationFinished('stop');
        },
        contextWindow: 12000,
        messages: _history().take(4).toList(),
      );
      final done = await b.runner.wait(b.task.id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(summaries, 1);
    },
  );

  test(
    'keeps usable original context when a summary would make it longer',
    () async {
      var summaries = 0;
      final original = [
        {'role': 'system', 'content': '系统规则'},
        {'role': 'user', 'content': '旧请求'},
        {'role': 'user', 'content': '甲' * 5500},
      ];
      final b = await _start(
        (request, cancel) async* {
          if (_isSummary(request)) {
            summaries++;
            yield TextDelta('之前已完成资料核对' * 20);
          } else {
            expect(request.messages, original);
            yield const TextDelta('完成');
          }
          yield const GenerationFinished('stop');
        },
        contextWindow: 12000,
        messages: original,
      );
      final done = await b.runner.wait(b.task.id);
      expect(summaries, 1);
      expect(done.status, TaskStatus.completed, reason: done.error);
    },
  );

  test(
    'a cut within sibling tool results retains the complete call batch',
    () async {
      final original = _history();
      original[4]['tool_calls'] = [
        ToolCallReady('first', 'list_lore', {}).toOpenAI(),
        ToolCallReady('second', 'list_lore', {}).toOpenAI(),
      ];
      original[5] = {
        'role': 'tool',
        'tool_call_id': 'first',
        'content': '甲' * 2300,
      };
      original.insert(6, {
        'role': 'tool',
        'tool_call_id': 'second',
        'content': '乙' * 2000,
      });
      final requests = <ProviderRequest>[];
      final b = await _start(
        (request, cancel) async* {
          requests.add(request);
          yield TextDelta(_isSummary(request) ? '旧资料已核对' : '完成');
          yield const GenerationFinished('stop');
        },
        contextWindow: 12000,
        messages: original,
      );
      final done = await b.runner.wait(b.task.id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(requests, hasLength(2));
      _expectToolPairs(requests.last.messages);
      expect(
        requests.last.messages.where((m) => m['role'] == 'tool'),
        hasLength(2),
      );
    },
  );

  for (final failure in ['empty', 'length', 'error']) {
    test(
      'failed summary ($failure) does not resume tools or replace history',
      () async {
        var calls = 0;
        final original = _history();
        final b = await _start(
          (request, cancel) async* {
            calls++;
            expect(_isSummary(request), isTrue);
            if (failure == 'error') {
              throw const ProviderException('http_error', '摘要服务不可用');
            }
            if (failure != 'empty') yield const TextDelta('未完成的摘要');
            yield GenerationFinished(failure == 'length' ? 'length' : 'stop');
          },
          contextWindow: 12000,
          messages: original,
        );
        final done = await b.runner.wait(b.task.id);
        expect(done.status, TaskStatus.failed);
        expect(done.error, contains('压缩'));
        expect(calls, 1);
        expect(done.input['request']['messages'], original);
      },
    );
  }

  test(
    'cancelling summary stops the task without another model request',
    () async {
      final started = Completer<void>();
      var calls = 0;
      final b = await _start(
        (request, cancel) async* {
          calls++;
          expect(_isSummary(request), isTrue);
          started.complete();
          final cancelled = Completer<void>();
          final remove = cancel.onCancel(cancelled.complete);
          try {
            await cancelled.future;
            cancel.check();
          } finally {
            remove();
          }
        },
        contextWindow: 12000,
        messages: _history(),
      );
      await started.future.timeout(const Duration(seconds: 5));
      await b.runner.cancel(b.task.id);
      expect((await b.runner.wait(b.task.id)).status, TaskStatus.cancelled);
      expect(calls, 1);
    },
  );

  test(
    'oversized current instruction fails explicitly without discarding it',
    () async {
      var calls = 0;
      final original = [
        {'role': 'system', 'content': '系统规则'},
        {'role': 'user', 'content': '当前请求' * 4000},
      ];
      final b = await _start(
        (request, cancel) async* {
          calls++;
          yield const GenerationFinished('stop');
        },
        contextWindow: 12000,
        messages: original,
      );
      final done = await b.runner.wait(b.task.id);
      expect(done.status, TaskStatus.failed);
      expect(done.error, contains('上下文'));
      expect(calls, 0);
      expect(done.input['request']['messages'], original);
    },
  );
}
