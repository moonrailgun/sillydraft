import 'dart:async';

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

class _StreamingProvider implements ModelProvider {
  _StreamingProvider(this.config);
  @override
  final ModelConnection config;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    final done = Completer<void>();
    final remove = cancellation!.onCancel(() => done.complete());
    try {
      yield const TextDelta('正在检查人物动机');
      await done.future;
      cancellation.check();
    } finally {
      remove();
    }
  }

  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => ['test'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
}

void main() {
  for (final enter in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
  ]) {
    testWidgets(
      '${enter.keyLabel} sends while Shift preserves multiline input',
      (tester) async {
        final repo = StoryRepository.memory();
        final services = AppServices(
          repository: repo,
          secrets: MemorySecrets(),
          modelProviderFactory: (c) async => _StreamingProvider(c),
        );
        addTearDown(services.close);
        await services.saveConnection(
          ModelConnection(
            id: 'test',
            name: '测试模型',
            baseUrl: 'http://localhost:1/v1',
            model: 'test',
          ),
        );
        final novel = await repo.createNovel(title: '键盘发送');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(
              AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('agent-input'));
        final editable = find.descendant(
          of: input,
          matching: find.byType(EditableText),
        );
        final controller = tester.widget<EditableText>(editable).controller;

        await tester.enterText(input, '   ');
        await tester.sendKeyEvent(enter);
        await tester.pumpAndSettle();
        expect(await repo.listConversations(novel.activeBranchId), isEmpty);

        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ni',
            selection: TextSelection.collapsed(offset: 2),
            composing: TextRange(start: 0, end: 2),
          ),
        );
        await tester.pump();
        expect(await tester.sendKeyEvent(enter), isFalse);
        await tester.pumpAndSettle();
        expect(await repo.listConversations(novel.activeBranchId), isEmpty);
        expect(controller.text, 'ni');

        await tester.enterText(input, '第一行');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        expect(await tester.sendKeyEvent(enter), isFalse);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        // Native text input supplies the newline after the unhandled key event.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: '第一行\n第二行',
            selection: TextSelection.collapsed(offset: 7),
          ),
        );
        await tester.pumpAndSettle();
        expect(await repo.listConversations(novel.activeBranchId), isEmpty);
        expect(controller.text, '第一行\n第二行');

        await tester.sendKeyEvent(enter);
        await tester.sendKeyEvent(enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final conversations = await repo.listConversations(
          novel.activeBranchId,
        );
        expect(conversations, hasLength(1));
        final messages = await repo.getAgentMessages(
          conversations.single['id'] as String,
        );
        expect(
          messages.where((m) => m.role == 'user').single.content,
          '第一行\n第二行',
        );
        expect(controller.text, isEmpty);
        expect(
          tester.widget<EditableText>(editable).focusNode.hasFocus,
          isTrue,
        );

        await tester.enterText(input, '等回复后再发');
        await tester.sendKeyEvent(enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          await repo.listTasks(branchId: novel.activeBranchId),
          hasLength(1),
        );
        expect(controller.text, '等回复后再发');
        await tester.tap(findAction('停止编辑回复'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'agent streams separately, cancels, and deleting chat retains the manuscript',
    (tester) async {
      final repo = StoryRepository.memory();
      final services = AppServices(
        repository: repo,
        secrets: MemorySecrets(),
        modelProviderFactory: (c) async => _StreamingProvider(c),
      );
      addTearDown(services.close);
      await services.saveConnection(
        ModelConnection(
          id: 'test',
          name: '测试模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'test',
        ),
      );
      final novel = await repo.createNovel(title: '会话隔离');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('唯一的正文'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('agent-input')), '帮我看看人物动机');
      await tester.tap(findAction('发送给编辑助手'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('正在检查人物动机'), findsWidgets);
      await tester.tap(findAction('停止编辑回复'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listTasks(branchId: novel.activeBranchId)).single.status,
        TaskStatus.cancelled,
      );
      await tester.tap(findAction('删除当前会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除会话'));
      await tester.pumpAndSettle();
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text.trim(),
        '唯一的正文',
      );
      expect(find.text('帮我看看人物动机'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
