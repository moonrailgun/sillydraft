import 'dart:async';

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

void main() {
  for (final kind in [TaskKind.agent, TaskKind.sidecar]) {
    test('$kind finishes after more than eight tool rounds', () async {
      var rounds = 0;
      final b = await _start((request, cancel) async* {
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
}
