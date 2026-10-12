import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sillydraft_core/src/storage/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  late StoryRepository store;
  late Novel novel;
  late Scene scene;
  setUp(() async {
    store = StoryRepository.memory();
    novel = await store.createNovel(title: '任务测试');
    final chapter = await store.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    scene = await store.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      content: ManuscriptContent.plainText('原文'),
    );
  });
  tearDown(() => store.close());

  test(
    'version-one databases migrate without losing existing novels',
    () async {
      await store.close();
      final dir = await Directory.systemTemp.createTemp(
        'sillydraft-migration-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/old.sqlite';
      final old = sqlite.sqlite3.open(path);
      for (final statement in StoryDatabase.schema) {
        old.execute(statement);
      }
      old.execute(
        "INSERT INTO novels (id,title,synopsis,genre,language,style,point_of_view,active_branch_id,created_at,updated_at) VALUES ('old','旧项目','','','','','','branch',1,1)",
      );
      old.execute(
        "INSERT INTO branches (id,novel_id,name,created_at) VALUES ('branch','old','主线',1)",
      );
      old.execute('PRAGMA user_version = 1');
      old.close();
      store = StoryRepository.open(path);
      expect((await store.getNovel('old')).title, '旧项目');
      final task = await store.createTask(
        branchId: 'branch',
        kind: TaskKind.analysis,
        input: {},
      );
      expect(task.status, TaskStatus.queued);
      expect(await store.listTasks(), hasLength(1));
    },
  );
  Future<GenerationTask> queued() => store.createTask(
    branchId: novel.activeBranchId,
    kind: TaskKind.writing,
    sceneId: scene.id,
    baseRevisionId: scene.revisionId,
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
      (await store.getScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
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
      (await store.getScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
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
      final chapter = await store.createChapter(
        branchId: novel.activeBranchId,
        title: '一',
      );
      scene = await store.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      );
      final task = await queued();
      await store.updateTask(
        task.id,
        status: TaskStatus.running,
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
      expect(restored.baseRevisionId, scene.revisionId);
      expect(restored.input['variableBaseVersion'], 0);
    },
  );

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
        (await store.getScene(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
        )).content.text,
        '原文\n',
      );
    },
  );
}
