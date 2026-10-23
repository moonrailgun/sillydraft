import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

void main() {
  testWidgets(
    'consecutive tool calls collapse and keep their state as they grow',
    (tester) async {
      tester.view.physicalSize = const Size(600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      final novel = await repo.createNovel(title: '工具分组');
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      Future<void> calls(List<String> names) => repo.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: '先查看相关资料。',
        metadata: {
          'tool_calls': [
            for (final name in names)
              {
                'id': name,
                'type': 'function',
                'function': {'name': name, 'arguments': '{}'},
              },
          ],
        },
      );
      Future<void> result(String name) => repo.appendAgentMessage(
        conversation,
        role: 'tool',
        content: '{"text":"$name 的完整结果"}',
        metadata: {'tool_call_id': name, 'tool_name': name},
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '帮我检查这一章',
      );
      await calls(['list_chapters', 'read_chapter']);
      await result('list_chapters');
      await result('read_chapter');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('调用了 2 个工具'), findsOneWidget);
      expect(find.textContaining('完整结果').hitTestable(), findsNothing);
      await tester.tap(find.text('调用了 2 个工具'));
      await tester.pumpAndSettle();
      expect(find.text('结果 · read_chapter'), findsOneWidget);
      await tester.tap(find.text('结果 · read_chapter'));
      await tester.pumpAndSettle();
      expect(
        find.text('{"text":"read_chapter 的完整结果"}').hitTestable(),
        findsOneWidget,
      );

      // A later round can reuse a call ID; count invocations, not unique IDs.
      await calls(['read_chapter']);
      await tester.pumpAndSettle();
      expect(find.text('调用了 3 个工具'), findsOneWidget);
      expect(
        find.text('{"text":"read_chapter 的完整结果"}').hitTestable(),
        findsOneWidget,
      );
      await result('read_chapter');
      await tester.pumpAndSettle();
      expect(find.text('调用了 3 个工具'), findsOneWidget);

      await tester.tap(find.text('调用了 3 个工具'));
      await tester.pumpAndSettle();
      expect(find.textContaining('完整结果').hitTestable(), findsNothing);
      await calls(['list_lore']);
      await tester.pumpAndSettle();
      expect(find.text('调用了 4 个工具'), findsOneWidget);
      expect(find.text('结果 · read_chapter').hitTestable(), findsNothing);

      await repo.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: '这一章检查完了。',
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '再检查一次',
      );
      await calls(['read_chapter']);
      await tester.pumpAndSettle();
      expect(find.text('调用了 4 个工具'), findsOneWidget);
      expect(find.text('调用了 1 个工具'), findsOneWidget);
      expect(find.text('这一章检查完了。'), findsOneWidget);
      expect(find.text('再检查一次'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
