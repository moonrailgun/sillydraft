import 'dart:io';

import 'package:drift/native.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository store;
  late Novel novel;
  late Chapter chapter;
  setUp(() async {
    store = StoryRepository.memory();
    novel = await store.createNovel(title: '任务测试');

    chapter = await store.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('原文'),
    );
  });
  tearDown(() => store.close());

  Future<GenerationTask> queued() => store.createTask(
    branchId: novel.activeBranchId,
    kind: TaskKind.writing,
    chapterId: chapter.id,
    baseRevisionId: chapter.revisionId,
    input: {
      'request': {'messages': <Object?>[]},
      'variableBaseVersion': 0,
      'variableResult': {
        'local': {'n': '1'},
        'global': <String, String>{},
      },
    },
  );

  test('task completion creates a proposal without publishing and commits variables on acceptance', () async {
    final task = await queued();
    await store.updateTask(
      task.id,
      status: TaskStatus.running,
      partialText: '候选',
    );
    final finished = await store.completeWritingTask(
      task.id,
      content: ManuscriptContent.plainText('候选'),
      rawText: '候选',
      reasoning: '仅任务可见',
    );
    expect(finished.status, TaskStatus.completed);
    expect(
      (await store.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text,
      '原文\n',
    );
    expect(
      (await store.getBranchVariables(novel.activeBranchId)).local,
      isEmpty,
    );
    final proposal = (await store.listProposals(novel.activeBranchId)).single;
    await store.acceptProposal(proposal.id);
    expect((await store.getBranchVariables(novel.activeBranchId)).local, {
      'n': '1',
    });
    expect(
      (await store.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text,
      '候选\n',
    );
    await store.acceptProposal(proposal.id);
    expect((await store.getBranchVariables(novel.activeBranchId)).version, 1);
  });

  test(
    'cancelled work cannot transition to completed or create a late proposal',
    () async {
      final task = await queued();
      await store.updateTask(
        task.id,
        status: TaskStatus.running,
        partialText: '部分',
      );
      await store.updateTask(task.id, status: TaskStatus.cancelled);
      final result = await store.completeWritingTask(
        task.id,
        content: ManuscriptContent.plainText('迟到'),
        rawText: '迟到',
      );
      expect(result.status, TaskStatus.cancelled);
      expect(result.partialText, '部分');
      expect(await store.listProposals(novel.activeBranchId), isEmpty);
    },
  );

  test(
    'partial output and source snapshot survive restart and become interrupted',
    () async {
      await store.close();
      final dir = await Directory.systemTemp.createTemp('sillydraft-jobs-');
      addTearDown(() => dir.delete(recursive: true));
      store = StoryRepository.open('${dir.path}/jobs.sqlite');
      novel = await store.createNovel(title: '恢复任务');

      chapter = await store.createChapter(branchId: novel.activeBranchId);
      final task = await queued();
      await store.updateTask(task.id, status: TaskStatus.running);
      await store.saveTaskProgress(
        task.id,
        partialText: '已经收到',
        reasoning: '旁路内容',
      );
      await store.close();
      store = StoryRepository.open('${dir.path}/jobs.sqlite');
      expect(await store.recoverInterruptedTasks(), 1);
      final restored = await store.getTask(task.id);
      expect(restored.status, TaskStatus.interrupted);
      expect(restored.partialText, '已经收到');
      expect(restored.reasoning, '旁路内容');
      expect(restored.baseRevisionId, chapter.revisionId);
      expect(restored.input['variableBaseVersion'], 0);
      // Recovery moves the text onto the task row, which backups copy.
      final exported = (await store.exportProject(novel.id))
          .tables['generation_tasks']!
          .single;
      expect(exported['partial_text'], '已经收到');
      expect(exported['reasoning'], '旁路内容');
    },
  );

  test(
    'streamed progress is saved beside the task, not over its snapshot',
    () async {
      await store.close();
      final dir = await Directory.systemTemp.createTemp('sillydraft-progress-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/library.sqlite';
      // No checkpoints: the WAL keeps every page the saves wrote.
      store = StoryRepository.connect(
        NativeDatabase(
          File(path),
          setup: (db) => db.execute('PRAGMA wal_autocheckpoint = 0'),
        ),
      );
      novel = await store.createNovel(title: '流式进度');
      final snapshot = 'x' * 512 * 1024;
      final task = await store.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.writing,
        input: {
          'brief': '写下一段',
          'preset': {'prompts': snapshot},
        },
      );
      await store.updateTask(task.id, status: TaskStatus.running);
      final wal = File('$path-wal');
      final before = wal.lengthSync();
      var text = '';
      for (var i = 0; i < 20; i++) {
        text += '雾港的灯在夜里亮着，';
        await store.saveTaskProgress(
          task.id,
          partialText: text,
          reasoning: '想$i',
        );
      }
      // SQLite rewrites a row whose size changes: saved on the task row,
      // each save rewrote the snapshot, 20 times its size in all.
      expect(wal.lengthSync() - before, lessThan(snapshot.length));
      final listed = (await store.listTasks(branchId: novel.activeBranchId))
          .single;
      expect((listed.partialText, listed.reasoning), (text, '想19'));
      expect((await store.getTask(task.id)).partialText, text);

      // Stopping keeps the last progress; progress after that is dropped.
      await store.updateTask(task.id, status: TaskStatus.cancelled);
      await store.saveTaskProgress(task.id, partialText: '迟到', reasoning: '');
      final done = await store.getTask(task.id);
      expect(
        (done.status, done.partialText, done.reasoning),
        (TaskStatus.cancelled, text, '想19'),
      );
      expect(
        (await store.exportProject(novel.id))
            .tables['generation_tasks']!
            .single['partial_text'],
        text,
      );
    },
  );

  test('a remote run cancelled mid-stream keeps its progress', () async {
    final task = await store.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.writing,
      input: {
        'connection': {'protocol': ModelProtocol.sillyDraftRunner.name},
      },
    );
    await store.updateTask(task.id, status: TaskStatus.running);
    await store.saveTaskProgress(task.id, partialText: '部分', reasoning: '想');
    await store.acknowledgeRemoteCancellation(task.id);
    final row = (await store.exportProject(novel.id))
        .tables['generation_tasks']!
        .single;
    expect(
      (row['status'], row['partial_text'], row['reasoning']),
      ('cancelled', '部分', '想'),
    );
  });

  test(
    'completed task cannot duplicate proposals on repeated delivery',
    () async {
      final task = await queued();
      await store.updateTask(task.id, status: TaskStatus.running);
      for (var i = 0; i < 2; i++) {
        await store.completeWritingTask(
          task.id,
          content: ManuscriptContent.plainText('结果'),
          rawText: '结果',
        );
      }
      expect(await store.listProposals(novel.activeBranchId), hasLength(1));
    },
  );

  test(
    'deleting an editor conversation leaves accepted manuscript intact',
    () async {
      final session = await store.createConversation(
        branchId: novel.activeBranchId,
      );
      await store.appendAgentMessage(session, role: 'user', content: '写作要求');
      await store.appendAgentMessage(
        session,
        role: 'assistant',
        content: '编辑说明',
      );
      expect(await store.getAgentMessages(session), hasLength(2));
      await store.deleteConversation(session);
      expect(
        (await store.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text,
        '原文\n',
      );
    },
  );
}
