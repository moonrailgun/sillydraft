import 'dart:async';

import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
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
import 'support/query_gate.dart';

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

/// Answers conversation turns with [replies], and naming requests separately.
class _ReplyProvider implements ModelProvider {
  _ReplyProvider(this.config, this.replies);
  @override
  final ModelConnection config;
  final Iterator<String> replies;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    if (request.executionId?.startsWith('conversation-title-') == true) {
      yield const TextDelta('旧宅伏笔设计');
      yield const GenerationFinished('stop');
      return;
    }
    replies.moveNext();
    yield TextDelta(replies.current);
    yield const GenerationFinished('stop');
  }

  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => ['test'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
}

/// An assistant panel answering with [replies], and its branch.
Future<({StoryRepository repo, String branchId})> _replyingPanel(
  WidgetTester tester,
  List<String> replies, {
  StoryRepository? repository,
}) async {
  final repo = repository ?? StoryRepository.memory();
  final iterator = replies.iterator;
  final services = AppServices(
    repository: repo,
    secrets: MemorySecrets(),
    modelProviderFactory: (c) async => _ReplyProvider(c, iterator),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await services.close();
  });
  await services.saveConnection(
    ModelConnection(
      id: 'test',
      name: '测试模型',
      baseUrl: 'http://localhost:1/v1',
      model: 'test',
    ),
  );
  final novel = await repo.createNovel(title: '重问');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(
        AppScaffold(child: AgentPanel(branchId: novel.activeBranchId)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (repo: repo, branchId: novel.activeBranchId);
}

Future<List<String>> _thread(StoryRepository repo, String branchId) async {
  final id = (await repo.listConversations(branchId)).single['id'] as String;
  return [for (final m in await repo.getAgentMessages(id)) m.content];
}

void main() {
  for (final editing in [false, true]) {
    testWidgets(
      'sending ${editing ? "an edited message" : "a message"} preserves a newer draft',
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      (tester) async {
        final gate = QueryGate();
        final repository = StoryRepository.connect(
          NativeDatabase.memory().interceptWith(gate),
        );
        final (:repo, :branchId) = await _replyingPanel(tester, [
          '回复一',
          '回复二',
          '回复三',
        ], repository: repository);
        addTearDown(gate.release);
        final input = find.byKey(const Key('agent-input'));
        if (editing) {
          await tester.enterText(input, '原问题');
          await tester.tap(findAction('发送给编辑助手'));
          await tester.pumpAndSettle();
          await tester.tap(findAction('修改'));
          await tester.pumpAndSettle();
        }
        await tester.enterText(input, '第一条请求');
        gate.arm((_) => true);
        await tester.tap(findAction('发送给编辑助手'));
        await gate.waitUntilBlocked(tester);
        await tester.enterText(input, '第二条尚未发送的草稿');
        gate.release();
        await tester.pumpAndSettle();
        final controller = tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .controller;
        expect(controller.text, '第二条尚未发送的草稿');
        await tester.tap(findAction('发送给编辑助手'));
        await tester.pumpAndSettle();
        final id =
            (await repo.listConversations(branchId)).single['id'] as String;
        expect(
          [
            for (final message in await repo.getAgentMessages(id))
              if (message.role == 'user') message.content,
          ],
          ['第一条请求', '第二条尚未发送的草稿'],
        );
        expect(controller.text, isEmpty);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'the conversation selector shows the title after the first reply',
    (tester) async {
      final (:repo, :branchId) = await _replyingPanel(tester, ['首轮回复']);
      await tester.enterText(find.byKey(const Key('agent-input')), '设计旧宅的伏笔');
      await tester.tap(findAction('发送给编辑助手'));
      await tester.pumpAndSettle();
      expect(find.text('旧宅伏笔设计 · 1'), findsOneWidget);
      expect(find.text('创作会话 · 1'), findsNothing);
      expect(await _thread(repo, branchId), ['设计旧宅的伏笔', '首轮回复']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('retrying an unsent turn keeps the previous conversation', (
    tester,
  ) async {
    final (:repo, :branchId) = await _replyingPanel(tester, ['原回复', '新回复']);
    final input = find.byKey(const Key('agent-input'));
    await tester.enterText(input, '原问题');
    await tester.tap(findAction('发送给编辑助手'));
    await tester.pumpAndSettle();
    final conversation = (await repo.listConversations(branchId)).single['id'];
    final pending = await repo.createTask(
      branchId: branchId,
      kind: TaskKind.agent,
      input: {
        'connection': ModelConnection(
          id: 'test',
          name: '测试模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'test',
        ).raw,
        'conversationId': conversation,
        'agentMessage': '排队的问题',
        'pendingAgent': <String, dynamic>{},
      },
    );
    await repo.recoverInterruptedTasks();
    await tester.pumpAndSettle();
    expect(await _thread(repo, branchId), ['原问题', '原回复']);
    expect(find.text('待发送：排队的问题'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(await _thread(repo, branchId), ['原问题', '原回复', '排队的问题', '新回复']);
    final retry = (await repo.listTasks(branchId: branchId)).first;
    expect(retry.retryOf, pending.id);
    expect(retry.status, TaskStatus.completed);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'regenerating drops the last reply; editing resends from there',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      final (:repo, :branchId) = await _replyingPanel(tester, [
        '回复一',
        '回复二',
        '回复三',
      ]);
      final input = find.byKey(const Key('agent-input'));
      await tester.enterText(input, '问题');
      await tester.tap(findAction('发送给编辑助手'));
      await tester.pumpAndSettle();
      expect(find.text('回复一'), findsOneWidget);

      await tester.tap(findAction('重新生成'));
      await tester.pumpAndSettle();
      expect(await _thread(repo, branchId), ['问题', '回复二']);

      await tester.tap(findAction('修改'));
      await tester.pumpAndSettle();
      final controller = tester
          .widget<EditableText>(
            find.descendant(of: input, matching: find.byType(EditableText)),
          )
          .controller;
      expect(controller.text, '问题');
      await tester.enterText(input, '改过的问题');
      await tester.tap(findAction('发送给编辑助手'));
      await tester.pumpAndSettle();
      expect(await _thread(repo, branchId), ['改过的问题', '回复三']);
      expect(find.text('回复二'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'on a phone, a long press offers the message actions',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      final copied = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copied.add(call.arguments);
          return null;
        },
      );
      await _replyingPanel(tester, ['新回复']);
      final input = find.byKey(const Key('agent-input'));
      await tester.enterText(input, '问题');
      await tester.tap(findAction('发送给编辑助手'));
      await tester.pumpAndSettle();
      expect(findAction('重新生成'), findsNothing);

      await tester.longPress(find.text('新回复'));
      await tester.pumpAndSettle();
      expect(find.text('重新生成'), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, [
        {'text': '新回复'},
      ]);
      expect(find.text('重新生成'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

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
          hasLength(2),
        );
        expect(controller.text, isEmpty);
        expect(find.text('排队 1 · 等回复后再发'), findsOneWidget);
        expect(find.textContaining('正在检查人物动机'), findsWidgets);
        await tester.tap(findAction('取消排队消息'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('排队 1 · 等回复后再发'), findsNothing);
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
      await tester.tap(findAction('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除当前会话'));
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
