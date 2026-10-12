import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/agent/agent_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

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
        title: '一',
      );
      final scene = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        content: ManuscriptContent.plainText('唯一的正文'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: MaterialApp(home: AgentScreen(branchId: novel.activeBranchId)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('agent-input')), '帮我看看人物动机');
      await tester.tap(find.byTooltip('发送给编辑助手'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('正在检查人物动机'), findsWidgets);
      await tester.tap(find.byTooltip('停止编辑回复'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listTasks(branchId: novel.activeBranchId)).single.status,
        TaskStatus.cancelled,
      );
      await tester.tap(find.byTooltip('删除当前会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除会话'));
      await tester.pumpAndSettle();
      expect(
        (await repo.getScene(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
        )).content.text.trim(),
        '唯一的正文',
      );
      expect(find.text('帮我看看人物动机'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
