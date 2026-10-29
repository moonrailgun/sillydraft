import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

final _longReply = [
  '**开头：本章的建议**',
  for (var i = 1; i <= 16; i++) '第 $i 段：这里是人物的动作、场景与情绪，保留完整的回复内容，展开后可以继续阅读。',
  '结尾：全部建议已列出。',
].join('\n\n');

Future<({StoryRepository repo, String conversation, String branchId})> _panel(
  WidgetTester tester, {
  required String role,
  required String content,
}) async {
  final repo = StoryRepository.memory();
  final services = AppServices(repository: repo, secrets: MemorySecrets());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await services.close();
  });
  final novel = await repo.createNovel(title: '回复折叠');
  final conversation = await repo.createConversation(
    branchId: novel.activeBranchId,
  );
  await repo.appendAgentMessage(conversation, role: role, content: content);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(
        AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (
    repo: repo,
    conversation: conversation,
    branchId: novel.activeBranchId,
  );
}

void main() {
  for (final width in [420.0, 900.0]) {
    testWidgets(
      'long AI replies expand and collapse at width $width without losing text',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final (:repo, :conversation, branchId: _) = await _panel(
          tester,
          role: 'assistant',
          content: _longReply,
        );

        expect(find.text('展开全部').hitTestable(), findsOneWidget);
        expect(find.text('结尾：全部建议已列出。').hitTestable(), findsNothing);
        await tester.tap(findAction('复制'));
        expect(copied, _longReply);

        await tester.tap(find.text('展开全部'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('结尾：全部建议已列出。'));
        expect(find.text('结尾：全部建议已列出。').hitTestable(), findsOneWidget);
        expect(find.text('收起'), findsOneWidget);

        // New messages must not reset an already expanded reply.
        await repo.appendAgentMessage(
          conversation,
          role: 'assistant',
          content: '简短的补充。',
        );
        await tester.pumpAndSettle();
        expect(find.text('展开全部'), findsNothing);
        await tester.ensureVisible(find.text('收起'));
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.text('展开全部'), findsOneWidget);
        expect(find.text('结尾：全部建议已列出。').hitTestable(), findsNothing);
        expect(
          (await repo.getAgentMessages(conversation)).first.content,
          _longReply,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final role in ['user', 'assistant']) {
    testWidgets(
      '$role ${role == 'user' ? 'messages' : 'short replies'} stay unfolded',
      (tester) async {
        await _panel(
          tester,
          role: role,
          content: role == 'user' ? _longReply : '简短回复。',
        );
        expect(find.text('展开全部'), findsNothing);
        expect(find.text('收起'), findsNothing);
      },
    );
  }

  testWidgets('a streaming reply keeps its expansion as more text arrives', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (:repo, :conversation, :branchId) = await _panel(
      tester,
      role: 'user',
      content: '帮我检查本章',
    );
    final task = await repo.createTask(
      branchId: branchId,
      kind: TaskKind.agent,
      input: {'conversationId': conversation},
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.running,
      partialText: _longReply,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('展开全部'));
    await tester.pump();
    await repo.updateTask(
      task.id,
      status: TaskStatus.interrupted,
      partialText: '$_longReply\n\n最后补充。',
    );
    await tester.pumpAndSettle();
    expect(find.text('展开全部'), findsNothing);
    expect(find.text('收起'), findsOneWidget);
    await tester.ensureVisible(find.text('最后补充。'));
    expect(find.text('最后补充。').hitTestable(), findsOneWidget);
  });
}
