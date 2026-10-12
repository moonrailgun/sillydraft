import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repo;
  late Novel novel;
  late Scene first, later;
  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '世界资料测试');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    first = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      title: '相遇',
      content: ManuscriptContent.plainText('林舟遇见苏雾。'),
    );
    later = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      title: '真相',
      content: ManuscriptContent.plainText('苏雾交出灯塔钥匙。'),
    );
  });
  tearDown(() => repo.close());
  test('reviewed relationship uses valid endpoints and refuses evidence beyond its snapshot', () async {
    final a = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林舟',
      content: '信使',
      atSceneId: first.id,
    );
    final b = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '苏雾',
      content: '守塔人',
      atSceneId: first.id,
    );
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.analysis,
      input: {
        'throughSceneId': first.id,
        'sourceRevisions': [
          {'sceneId': first.id, 'revisionId': first.revisionId},
        ],
      },
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {
        'entries': [
          {
            'kind': 'relationship',
            'name': '信任',
            'content': '愿意托付信件',
            'certainty': 'inference',
            'sourceSceneId': first.id,
            'data': {'fromId': a.id, 'toId': b.id, 'directed': true},
          },
          {
            'kind': 'world',
            'name': '越过快照',
            'content': '不应采纳未来依据',
            'certainty': 'fact',
            'sourceSceneId': later.id,
          },
        ],
      },
    );
    final relation = await repo.acceptAnalysisEntry(taskId: task.id, index: 0);
    expect(relation.kind, LoreKind.relationship);
    expect(relation.data['fromId'], a.id);
    expect(relation.certainty, LoreCertainty.inference);
    await expectLater(
      repo.acceptAnalysisEntry(taskId: task.id, index: 1),
      throwsA(isA<FormatException>()),
    );
    expect((await repo.listLore(novel.activeBranchId)).length, 3);
  });
  test('lore versions follow story position, preserve provenance and reject stale edits', () async {
    final original = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '苏雾',
      content: '身份未知',
      certainty: LoreCertainty.fact,
      atSceneId: first.id,
      provenance: {'type': 'manual'},
    );
    final changed = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      id: original.id,
      expectedRevisionId: original.revisionId,
      kind: LoreKind.character,
      name: '苏雾',
      content: '灯塔守护人',
      certainty: LoreCertainty.fact,
      atSceneId: later.id,
      provenance: {
        'type': 'manuscript',
        'sceneId': later.id,
        'revisionId': later.revisionId,
      },
    );
    expect(
      (await repo.listLore(
        novel.activeBranchId,
        throughSceneId: first.id,
      )).single.content,
      '身份未知',
    );
    expect((await repo.listLore(novel.activeBranchId)).single.content, '灯塔守护人');
    await expectLater(
      repo.saveLoreEntry(
        branchId: novel.activeBranchId,
        id: original.id,
        expectedRevisionId: original.revisionId,
        kind: LoreKind.character,
        name: '苏雾',
        content: '覆盖',
        certainty: LoreCertainty.inference,
        atSceneId: later.id,
      ),
      throwsA(isA<LoreConflict>()),
    );
    await repo.saveScene(
      branchId: novel.activeBranchId,
      sceneId: later.id,
      expectedRevisionId: later.revisionId,
      content: ManuscriptContent.plainText('真相被改写了。'),
    );
    expect(
      (await repo.listLore(novel.activeBranchId)).single.sourceStale,
      isTrue,
    );
    await repo.deleteLoreEntry(
      branchId: novel.activeBranchId,
      id: changed.id,
      expectedRevisionId: changed.revisionId,
      atSceneId: later.id,
    );
    expect(await repo.listLore(novel.activeBranchId), isEmpty);
    expect(
      (await repo.listLore(
        novel.activeBranchId,
        throughSceneId: first.id,
      )).single.content,
      '身份未知',
    );
  });
  test('a historical fork copies visible relationships and variables without later revelations', () async {
    final a = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林舟',
      content: '信使',
      atSceneId: first.id,
    );
    final b = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '苏雾',
      content: '陌生人',
      atSceneId: first.id,
    );
    final relation = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.relationship,
      name: '认识',
      content: '渡口初见',
      atSceneId: first.id,
      data: {'fromId': a.id, 'toId': b.id, 'directed': true},
    );
    await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      id: b.id,
      expectedRevisionId: b.revisionId,
      kind: LoreKind.character,
      name: '苏雾',
      content: '守护人',
      atSceneId: later.id,
    );
    await repo.setBranchVariables(
      branchId: novel.activeBranchId,
      sceneId: first.id,
      expectedVersion: 0,
      local: {'phase': 'meeting'},
    );
    await repo.setBranchVariables(
      branchId: novel.activeBranchId,
      sceneId: later.id,
      expectedVersion: 1,
      local: {'phase': 'reveal', 'secret': 'tower'},
    );
    expect(
      (await repo.getBranchVariables(
        novel.activeBranchId,
        throughSceneId: first.id,
      )).local,
      {'phase': 'meeting'},
    );
    final fork = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: '另一种相遇',
      atSceneId: first.id,
    );
    final lore = await repo.listLore(fork.id);
    expect(lore.firstWhere((e) => e.id == b.id).content, '陌生人');
    expect(lore.firstWhere((e) => e.id == relation.id).data['toId'], b.id);
    expect((await repo.getBranchVariables(fork.id)).local, {
      'phase': 'meeting',
    });
    await repo.setBranchVariables(
      branchId: fork.id,
      sceneId: first.id,
      expectedVersion: (await repo.getBranchVariables(fork.id)).version,
      local: {'phase': 'different'},
    );
    expect(
      (await repo.getBranchVariables(novel.activeBranchId)).local['secret'],
      'tower',
    );
  });
  test('analysis suggestions require review, retain uncertainty, and reject stale sources', () async {
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.analysis,
      input: {
        'sourceRevisions': [
          {'sceneId': first.id, 'revisionId': first.revisionId},
          {'sceneId': later.id, 'revisionId': later.revisionId},
        ],
      },
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {
        'entries': [
          {
            'kind': 'character',
            'name': '苏雾',
            'content': '也许来自灯塔',
            'certainty': 'inference',
            'sourceSceneId': first.id,
          },
          {
            'kind': 'item',
            'name': '钥匙',
            'content': '打开灯塔',
            'certainty': 'fact',
            'sourceSceneId': later.id,
          },
        ],
      },
    );
    expect(await repo.listLore(novel.activeBranchId), isEmpty);
    final entry = await repo.acceptAnalysisEntry(taskId: task.id, index: 0);
    expect(entry.certainty, LoreCertainty.inference);
    expect(
      (await repo.acceptAnalysisEntry(taskId: task.id, index: 0)).id,
      entry.id,
    );
    await repo.saveScene(
      branchId: novel.activeBranchId,
      sceneId: later.id,
      expectedRevisionId: later.revisionId,
      content: ManuscriptContent.plainText('没有钥匙。'),
    );
    await expectLater(
      repo.acceptAnalysisEntry(taskId: task.id, index: 1),
      throwsA(isA<StaleAnalysis>()),
    );
    expect((await repo.listLore(novel.activeBranchId)).length, 1);
  });
  test('map routes reject missing pins and relations cannot refer to another branch', () async {
    final foreignNovel = await repo.createNovel(title: '另一本书');
    final foreign = await repo.saveLoreEntry(
      branchId: foreignNovel.activeBranchId,
      kind: LoreKind.character,
      name: '不相关的人',
      content: '外部',
    );
    final local = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林舟',
      content: '信使',
      atSceneId: first.id,
    );
    await expectLater(
      repo.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.relationship,
        name: '越界',
        content: '错误',
        data: {'fromId': local.id, 'toId': foreign.id},
      ),
      throwsA(isA<StoryNotFound>()),
    );
    await expectLater(
      repo.saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.map,
        name: '雾港',
        content: '地图',
        data: {
          'points': [
            {'id': 'p1', 'x': .2, 'y': .3, 'label': '渡口'},
          ],
          'routes': [
            {
              'id': 'r',
              'pointIds': ['p1', 'missing'],
            },
          ],
        },
      ),
      throwsA(isA<FormatException>()),
    );
  });
  test('selecting one plot candidate creates one isolated branch and is idempotent', () async {
    final task = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.branches,
      input: {
        'sourceRevisions': [
          {'sceneId': first.id, 'revisionId': first.revisionId},
          {'sceneId': later.id, 'revisionId': later.revisionId},
        ],
      },
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {
        'candidates': [
          {'title': '去灯塔', 'summary': '追查真相', 'opening': '他踏上石阶。'},
          {'title': '离开港口', 'summary': '新的旅程', 'opening': '船驶向远方。'},
        ],
      },
    );
    final branch = await repo.branchFromCandidate(taskId: task.id, index: 0);
    expect(
      (await repo.branchFromCandidate(taskId: task.id, index: 0)).id,
      branch.id,
    );
    expect((await repo.getStory(branch.id)).text, contains('他踏上石阶。'));
    expect((await repo.getStory(branch.id)).text, isNot(contains('船驶向远方。')));
    expect((await repo.getStory(novel.activeBranchId)).scenes.length, 2);
    expect(
      (await repo.listLore(branch.id)).single.certainty,
      LoreCertainty.plan,
    );
  });
}
