import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'task_screen_test.dart' show showTask;

final class ScriptProvider implements ModelProvider {
  ScriptProvider(this.config, this.script);
  @override
  final ModelConnection config;
  final Stream<ProviderEvent> Function(ProviderRequest, GenerationCancellation)
  script;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => script(request, cancellation ?? GenerationCancellation());
  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

final model = ModelConnection(
  id: 'review-local',
  name: 'Review local script',
  baseUrl: 'http://localhost:1',
  model: 'fixture',
);

void main() {
  for (final view in [
    'original',
    'next turn',
    'retry',
    'retry after editing',
  ]) {
    testWidgets('$view shows only its own execution after a retry', (
      tester,
    ) async {
      final repo = StoryRepository.memory();
      final task = await tester.runAsync(() async {
        final novel = await repo.createNovel(title: 'Review retry');
        final conversation = await repo.createConversation(
          branchId: novel.activeBranchId,
          title: 'Review retry',
        );
        var call = 0;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            expect(
              request.messages.any((m) => m.containsKey('taskId')),
              isFalse,
            );
            switch (call++) {
              case 0:
                throw const ProviderException(
                  'offline',
                  'First attempt failed',
                );
              case 1:
                yield ToolCallReady(
                  'next-turn',
                  view == 'original' ? 'read_novel' : 'list_lore',
                  {},
                );
                yield const GenerationFinished('tool_calls');
              case 3:
                yield ToolCallReady('retry-only', 'read_novel', {});
                yield const GenerationFinished('tool_calls');
              default:
                yield const TextDelta('Finished');
                yield const GenerationFinished('stop');
            }
          }),
        );
        try {
          final agent = EditorAgent(repository: repo, runner: runner);
          final first = await agent.send(
            conversationId: conversation,
            connection: model,
            message: '帮我看看这本作品',
          );
          final failed = await runner.wait(first.id);
          expect(failed.status, TaskStatus.failed, reason: failed.error);
          final later = view == 'original'
              ? null
              : await runner.wait(
                  (await agent.send(
                    conversationId: conversation,
                    connection: model,
                    message: '找一找已有设定',
                  )).id,
                );
          if (later != null) {
            expect(later.status, TaskStatus.completed, reason: later.error);
          }
          final retried = await runner.wait(
            (await runner.resume(failed.id)).id,
          );
          expect(retried.status, TaskStatus.completed, reason: retried.error);
          expect(
            retried.input['sourceMessageId'],
            failed.input['sourceMessageId'],
          );
          final messages = await repo.getAgentMessages(conversation);
          expect(
            messages.where((m) => m.role == 'user'),
            hasLength(view == 'original' ? 1 : 2),
          );
          expect(
            messages.where((m) => m.role == 'tool'),
            hasLength(view == 'original' ? 1 : 2),
          );
          if (view == 'retry after editing') {
            await repo.deleteAgentMessagesFrom(
              conversation,
              failed.input['sourceMessageId'] as String,
            );
          }
          return switch (view) {
            'original' => failed,
            'next turn' => later!,
            _ => retried,
          };
        } finally {
          await runner.close();
        }
      });
      await showTask(tester, repo, task!);
      await tester.pumpAndSettle();
      expect(
        find.text('读取作品信息'),
        view.startsWith('retry') ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('查找资料'),
        view == 'next turn' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('执行过程'),
        view == 'original' ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final conflict in [true, false]) {
    testWidgets('sidecar batch save shows per-entry failure: $conflict', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final task = await tester.runAsync(() async {
        final novel = await repo.createNovel(title: 'Review sidecar');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          title: '第一章',
          content: ManuscriptContent.plainText('角色出场。'),
        );
        final lore = await repo.saveLoreEntry(
          branchId: novel.activeBranchId,
          kind: LoreKind.character,
          name: '林岚',
          content: '原资料',
        );
        var call = 0;
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (_, _) async* {
            if (call++ == 0) {
              yield ToolCallReady('save', 'save_lore', {
                'entries': [
                  {
                    'id': lore.id,
                    'expectedRevisionId': conflict
                        ? 'stale-revision'
                        : lore.revisionId,
                    'kind': 'character',
                    'name': '林岚',
                    'content': '修改资料',
                    'certainty': 'fact',
                  },
                  {
                    'kind': 'character',
                    'name': '新人物',
                    'content': '新资料',
                    'certainty': 'fact',
                  },
                ],
              });
              yield const GenerationFinished('tool_calls');
            } else {
              yield const TextDelta('已结束整理。');
              yield const GenerationFinished('stop');
            }
          }),
        );
        try {
          final started = await runner.start(
            branchId: novel.activeBranchId,
            kind: TaskKind.sidecar,
            chapterId: chapter.id,
            baseRevisionId: chapter.revisionId,
            input: {
              'connection': model.raw,
              'request': ProviderRequest(
                messages: [
                  {'role': 'user', 'content': '整理资料'},
                ],
              ).raw,
              'duties': [SidecarDuty.characters.name],
            },
          );
          final completed = await runner.wait(started.id);
          expect(
            completed.status,
            TaskStatus.completed,
            reason: completed.error,
          );
          final tool = (completed.result['transcript'] as List)
              .cast<Map>()
              .singleWhere((m) => m['role'] == 'tool');
          final result = jsonDecode(tool['content'] as String) as Map;
          expect(
            (result['results'] as List).first['error'],
            conflict ? contains('版本冲突') : isNull,
          );
          expect((result['results'] as List).last['error'], isNull);
          return completed;
        } finally {
          await runner.close();
        }
      });
      await showTask(tester, repo, task!);
      await tester.pumpAndSettle();
      expect(find.text('工具 · save_lore'), findsOneWidget);
      expect(
        find.text('未完成'),
        conflict ? findsOneWidget : findsNothing,
        reason: 'Each batch entry must contribute to the tool status.',
      );
      expect(
        find.text('版本冲突：资料已被修改，请重新读取后再写'),
        conflict ? findsOneWidget : findsNothing,
      );
      expect(find.text('已完成'), conflict ? findsNothing : findsOneWidget);
      expect(find.text('本次任务已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
