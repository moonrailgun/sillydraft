import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/task_screen.dart';
import 'package:sillydraft/features/illustrations/asset_image.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

Future<void> showTask(
  WidgetTester tester,
  StoryRepository repo,
  GenerationTask task, {
  Brightness brightness = Brightness.light,
}) async {
  final services = AppServices(repository: repo, secrets: MemorySecrets());
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await services.close();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(TaskScreen(taskId: task.id), brightness: brightness),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('comic tasks expose checkpoints, candidates and their chapter', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '漫画');
    final chapter = await repo.createChapter(branchId: novel.activeBranchId);
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.comic,
      input: {
        'comicHeads': {chapter.id: null},
      },
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.interrupted,
      result: {
        'stage': 'audit',
        'comicCandidates': [chapter.id],
      },
    );
    await showTask(tester, repo, task);
    await tester.pumpAndSettle();
    expect(find.text('继续未完成部分'), findsOneWidget);
    expect(find.text('阶段：对照原文检查'), findsOneWidget);
    expect(find.text('1 章候选待处理'), findsOneWidget);
    expect(find.text('打开漫画'), findsOneWidget);
    // A novel's chapter opens the adaptation panel.
    await tester.tap(find.text('打开漫画'));
    await tester.pumpAndSettle();
    expect(find.text('编排分镜 → 检查改编 → 绘制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an original comic task opens the comic canvas', (tester) async {
    final repo = StoryRepository.memory();
    final novel = await repo.createNovel(
      title: '末班地铁',
      workFormat: WorkFormat.comic,
    );
    final chapter = await repo.createChapter(branchId: novel.activeBranchId);
    await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('她在陆生站台下车。'),
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.comic,
      input: {
        'comicAction': 'compose',
        'comicHeads': {chapter.id: null},
      },
    );
    await repo.updateTask(task.id, status: TaskStatus.failed, error: '超时');
    await showTask(tester, repo, task);
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开漫画'));
    await tester.pumpAndSettle();
    expect(find.text('第一页发生了什么？'), findsOneWidget);
    expect(find.text('这一话是原创漫画，请在漫画画布中创作。'), findsNothing);

    // The next episode has prose only: both of its entries work.
    await tester.ensureVisible(find.text('下一话'));
    await tester.tap(find.text('下一话'));
    await tester.pumpAndSettle();
    expect(find.text('本话有小说正文，还没有漫画'), findsOneWidget);
    for (final label in ['阅读正文', '改编为漫画']) {
      final button = find.widgetWithText(FButton, label);
      expect(tester.widget<FButton>(button).onPress, isNotNull, reason: label);
    }
    await tester.tap(find.text('改编为漫画'));
    await tester.pumpAndSettle();
    expect(find.text('编排分镜 → 检查改编 → 绘制'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('阅读正文'));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'waiting for approval opens the task conversation, not the latest',
    (tester) async {
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '任务测试');
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '画一张书房插图',
      );
      final task = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {
          'conversationId': conversation,
          'agentMessage': '画一张书房插图',
          'image': {
            'connection': ModelConnection(
              id: 'image',
              name: '测试引擎',
              baseUrl: 'http://localhost:1',
              model: 'fixture',
            ).raw,
          },
        },
      );
      await repo.updateTask(
        task.id,
        status: TaskStatus.running,
        result: {
          'imageConfirmation': {
            'id': 'approval',
            'name': '书房',
            'prompt': 'A library',
          },
        },
      );
      await repo.createConversation(
        branchId: novel.activeBranchId,
        title: '另一个会话',
      );
      await showTask(tester, repo, task);
      expect(find.text('等待你确认插画'), findsOneWidget);
      expect(find.text('尚未收到内容'), findsNothing);
      expect(find.byType(FProgress), findsNothing);
      await tester.tap(find.text('前往确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('agent-image-confirmation')), findsOneWidget);
      expect(find.text('确认生成').hitTestable(), findsOneWidget);
      expect(
        (await repo.getTask(task.id)).result['imageConfirmation'],
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('tool activity stops at the next user turn', (tester) async {
    final repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '任务测试');
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    await repo.appendAgentMessage(conversation, role: 'user', content: '读这一章');
    final source = (await repo.getAgentMessages(conversation)).single;
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.agent,
      input: {
        'conversationId': conversation,
        'sourceMessageId': source.id,
        'agentMessage': source.content,
      },
    );
    await repo.appendAgentMessage(
      conversation,
      role: 'assistant',
      content: '',
      metadata: {
        'tool_calls': [
          {
            'id': 'read',
            'function': {'name': 'read_chapter', 'arguments': '{}'},
          },
        ],
      },
    );
    await repo.appendAgentMessage(
      conversation,
      role: 'tool',
      content: '{"text":"正文"}',
      metadata: {'tool_call_id': 'read', 'tool_name': 'read_chapter'},
    );
    await repo.updateTask(task.id, status: TaskStatus.completed);
    await repo.appendAgentMessage(conversation, role: 'user', content: '下一轮');
    await repo.appendAgentMessage(
      conversation,
      role: 'assistant',
      content: '',
      metadata: {
        'tool_calls': [
          {
            'id': 'later',
            'function': {'name': 'generate_images', 'arguments': '{}'},
          },
        ],
      },
    );
    await showTask(tester, repo, task);
    await tester.pumpAndSettle();
    expect(find.text('读取章节'), findsOneWidget);
    expect(find.text('批量生成插画'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'owned tool progress crosses user turns and keeps recovered errors',
    (tester) async {
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '任务测试');
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '查找资料',
      );
      final source = (await repo.getAgentMessages(conversation)).single;
      final task = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {'conversationId': conversation, 'sourceMessageId': source.id},
      );
      await repo.updateTask(task.id, status: TaskStatus.running);
      await repo.appendAgentMessage(
        conversation,
        role: 'user',
        content: '另一个请求',
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: '',
        metadata: {
          'taskId': task.id,
          'tool_calls': [
            {
              'id': 'read',
              'function': {'name': 'read_lore'},
            },
          ],
        },
      );
      await showTask(tester, repo, task);
      expect(find.text('正在读取资料'), findsOneWidget);
      expect(find.text('进行中'), findsOneWidget);
      await repo.appendAgentMessage(
        conversation,
        role: 'tool',
        content: '{"error":"资料不存在，请重新查找"}',
        metadata: {'taskId': task.id, 'tool_call_id': 'read'},
      );
      await repo.appendAgentMessage(
        conversation,
        role: 'assistant',
        content: '',
        metadata: {
          'taskId': task.id,
          'tool_calls': [
            {
              'id': 'list',
              'function': {'name': 'list_lore'},
            },
          ],
        },
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在查找资料'), findsOneWidget);
      expect(find.text('资料不存在，请重新查找'), findsOneWidget);
      await repo.appendAgentMessage(
        conversation,
        role: 'tool',
        content: '{"items":[]}',
        metadata: {'taskId': task.id, 'tool_call_id': 'list'},
      );
      await repo.updateTask(task.id, status: TaskStatus.completed);
      await tester.pumpAndSettle();
      expect(find.text('本次任务已完成'), findsOneWidget);
      expect(find.text('部分操作未完成'), findsNothing);
      expect(find.text('未完成'), findsOneWidget);
      expect(find.text('已完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing source turn uses only the saved task transcript', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '任务测试');
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    await repo.appendAgentMessage(conversation, role: 'user', content: '别的任务');
    await repo.appendAgentMessage(
      conversation,
      role: 'assistant',
      content: '',
      metadata: {
        'tool_calls': [
          {
            'id': 'other',
            'function': {'name': 'delete_chapter'},
          },
        ],
      },
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.agent,
      input: {'conversationId': conversation, 'agentMessage': '读作品信息'},
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {
        'transcript': [
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'novel',
                'function': {'name': 'read_novel'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'novel', 'content': '{}'},
        ],
      },
    );
    await showTask(tester, repo, task);
    await tester.pumpAndSettle();
    expect(find.text('读取作品信息'), findsOneWidget);
    expect(find.text('删除章节'), findsNothing);
    expect(find.text('别的任务'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('child outputs retain draft, review and failed task actions', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '任务测试');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      name: '书房',
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.agent,
      input: {'agentMessage': '续写并整理资料'},
    );
    final writing = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      chapterId: chapter.id,
      input: {},
    );
    final proposal = await repo.createProposal(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('未写入的正文'),
      taskId: writing.id,
    );
    await repo.updateTask(
      writing.id,
      status: TaskStatus.completed,
      result: {'proposalId': proposal.id},
    );
    final analysis = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.analysis,
      input: {'parentTaskId': task.id},
    );
    await repo.updateTask(analysis.id, status: TaskStatus.completed);
    final illustration = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.illustration,
      input: {'name': '书房插画'},
    );
    await repo.updateTask(
      illustration.id,
      status: TaskStatus.failed,
      error: '图片服务暂不可用',
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {
        'transcript': [
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'write',
                'function': {'name': 'propose_chapter'},
              },
              {
                'id': 'image',
                'function': {'name': 'generate_images'},
              },
            ],
          },
          {
            'role': 'tool',
            'tool_call_id': 'write',
            'content': jsonEncode({'taskId': writing.id, 'accepted': false}),
          },
          {
            'role': 'tool',
            'tool_call_id': 'image',
            'content': jsonEncode({
              'images': [
                {'taskId': illustration.id, 'status': 'failed'},
              ],
            }),
          },
        ],
      },
    );
    await showTask(tester, repo, task);
    await tester.pumpAndSettle();
    expect(find.text('正文尚未写入'), findsOneWidget);
    expect(find.text('处理未写入的正文'), findsOneWidget);
    expect(find.text('审阅资料提取'), findsOneWidget);
    expect(find.text('未采纳'), findsOneWidget);
    expect(find.text('图片服务暂不可用'), findsOneWidget);
    await tester.ensureVisible(find.text('查看任务'));
    await tester.tap(find.text('查看任务'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TaskScreen>(find.byType(TaskScreen)).taskId,
      illustration.id,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1024.0]) {
    testWidgets('failure retains multiple outputs at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '任务测试');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        name: '书房',
      );
      final task = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {'agentMessage': '续写并生成两张插图'},
      );
      await repo.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: '第二张图片生成失败',
        result: {
          'assetIds': ['first-image', 'second-image'],
          'assetId': 'first-image',
          'writtenChapters': {chapter.id: chapter.revisionId},
        },
      );
      await showTask(
        tester,
        repo,
        task,
        brightness: width == 320 ? Brightness.light : Brightness.dark,
      );
      await tester.pumpAndSettle();
      expect(find.text('第二张图片生成失败'), findsOneWidget);
      expect(find.text(chapter.title), findsOneWidget);
      final images = tester
          .widgetList<AssetImageView>(find.byType(AssetImageView))
          .map((w) => w.assetId)
          .toList();
      expect(images, ['first-image', 'second-image']);
      expect(find.text('查看正文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a completed but unaccepted draft asks for handling', (
    tester,
  ) async {
    final repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '任务测试');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      name: '书房',
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      kind: TaskKind.writing,
      input: {'brief': '续写书房的故事'},
    );
    final proposal = await repo.createProposal(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('新的正文'),
      taskId: task.id,
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {'proposalId': proposal.id},
    );
    await showTask(tester, repo, task);
    await tester.pumpAndSettle();
    expect(find.text('正文尚未写入'), findsOneWidget);
    expect(find.text('处理未写入的正文'), findsOneWidget);
    expect(find.text('续写书房的故事'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
