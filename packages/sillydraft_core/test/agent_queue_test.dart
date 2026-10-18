import 'dart:async';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  for (final (cancelMiddle, outcome) in [
    (false, TaskStatus.completed),
    (true, TaskStatus.completed),
    (false, TaskStatus.cancelled),
    (false, TaskStatus.failed),
  ]) {
    test(
      'agent turns queue with fresh context; cancel middle: $cancelMiddle, head: $outcome',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final novel = await repo.createNovel(title: '排队');
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final other = await repo.createConversation(
          branchId: novel.activeBranchId,
        );
        final connection = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        final entered = Completer<void>(), release = Completer<void>();
        final requests = <List<String>>[];
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (
            request,
            cancellation,
          ) async* {
            final messages = [
              for (final m in request.messages)
                if (m['role'] != 'system') m['content'] as String,
            ];
            requests.add(messages);
            if (messages.last == '第一条') {
              entered.complete();
              final cancelled = Completer<void>();
              final remove = cancellation.onCancel(() => cancelled.complete());
              try {
                await Future.any([release.future, cancelled.future]);
                cancellation.check();
                if (outcome == TaskStatus.failed) {
                  throw const ProviderException('test', '第一轮失败');
                }
              } finally {
                remove();
              }
            }
            yield TextDelta('回复${messages.last}');
            yield const GenerationFinished('stop');
          }),
        );
        addTearDown(runner.close);
        final agent = EditorAgent(repository: repo, runner: runner);
        Future<GenerationTask> send(String message, [String? target]) =>
            agent.send(
              conversationId: target ?? conversation,
              connection: connection,
              message: message,
            );
        final first = await send('第一条');
        await entered.future;
        final second = await send('第二条');
        final third = await send('第三条');
        expect((await repo.getTask(second.id)).status, TaskStatus.queued);
        expect((await repo.getTask(third.id)).status, TaskStatus.queued);
        expect(
          [
            for (final m in await repo.getAgentMessages(conversation))
              m.content,
          ],
          ['第一条'],
        );
        if (cancelMiddle) {
          await runner.cancel(second.id);
          expect((await runner.wait(second.id)).status, TaskStatus.cancelled);
          expect((await repo.getTask(third.id)).status, TaskStatus.queued);
        }
        final separate = await send('另一个会话', other);
        expect((await runner.wait(separate.id)).status, TaskStatus.completed);
        expect(requests.length, 2);
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('排队期间的新正文'),
        );
        if (outcome == TaskStatus.cancelled) {
          await runner.cancel(first.id);
        } else {
          release.complete();
        }
        expect((await runner.wait(first.id)).status, outcome);
        expect((await runner.wait(third.id)).status, TaskStatus.completed);
        expect((await repo.getTask(third.id)).input['sourceRevisions'], [
          {'chapterId': chapter.id, 'revisionId': chapter.revisionId},
        ]);
        expect(requests.last, [
          '第一条',
          if (outcome == TaskStatus.completed) '回复第一条',
          if (!cancelMiddle) ...['第二条', '回复第二条'],
          '第三条',
        ]);
      },
    );
  }
}
