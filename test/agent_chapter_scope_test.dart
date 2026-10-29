import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

void main() {
  testWidgets('chapter tools move the scope without losing the conversation', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final services = AppServices(repository: repo, secrets: MemorySecrets());
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await services.close();
    });
    final novel = await repo.createNovel(title: '章节范围');
    final branch = novel.activeBranchId;
    final first = await repo.createChapter(branchId: branch, name: '开篇');
    final conversation = await repo.createConversation(
      branchId: branch,
      throughChapterId: first.id,
    );
    await repo.appendAgentMessage(
      conversation,
      role: 'assistant',
      content: '保留当前会话',
    );
    final task = await repo.createTask(
      branchId: branch,
      kind: TaskKind.agent,
      input: {'conversationId': conversation},
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          AppScaffold(
            child: AgentPanel(branchId: branch, chapterId: first.id),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<List<Chapter>?> manage(String operation, {String? id}) async =>
        repo.manageAgentChapter(
          task: task,
          expectedChapters: [
            for (final c in (await repo.getStory(branch)).chapters)
              {'id': c.id, 'title': c.title, 'revisionId': c.revisionId},
          ],
          operation: operation,
          name: '归途',
          chapterId: id,
        );

    final created = (await manage('create_chapter'))!.last;
    await tester.pumpAndSettle();
    expect(findAction('参考范围：截至「${created.title}」'), findsOneWidget);
    expect(find.text('保留当前会话'), findsOneWidget);

    await manage('delete_chapter', id: created.id);
    await tester.pumpAndSettle();
    expect(findAction('参考范围：截至「${first.title}」'), findsOneWidget);
    expect(find.text('保留当前会话'), findsOneWidget);
    await tester.tap(findAction('新建编辑会话'));
    await tester.pumpAndSettle();
    final conversations = await repo.listConversations(branch);
    expect(conversations, hasLength(2));
    expect(
      conversations.every((c) => c['through_chapter_id'] == first.id),
      true,
    );
    expect(tester.takeException(), isNull);
  });
}
