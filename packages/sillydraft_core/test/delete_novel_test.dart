import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('deleting a work removes all of it and leaves other works', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final kept = await repo.createNovel(title: '留下的作品');
    await repo.createChapter(
      branchId: kept.activeBranchId,
      content: ManuscriptContent.plainText('还在'),
    );
    final novel = await repo.createNovel(title: '要删的作品');
    final branch = novel.activeBranchId;
    final chapter = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('正文'),
    );
    await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: '人物',
      content: '介绍',
      atChapterId: chapter.id,
      provenance: {'chapterId': chapter.id, 'revisionId': chapter.revisionId},
    );
    await repo.addBookmark(branchId: branch, chapterId: chapter.id);
    final conversation = await repo.createConversation(branchId: branch);
    await repo.appendAgentMessage(conversation, role: 'user', content: '你好');
    await repo.setSetting('goal/${novel.id}', {'words': 1000});
    await repo.setSetting('syncState/${novel.id}', {'x': 1});
    await repo.setSetting('htmlVariables/$branch', {'x': 1});
    final task = await repo.createTask(
      branchId: branch,
      kind: TaskKind.writing,
      input: {},
    );

    // A running generation must be stopped first.
    await expectLater(repo.deleteNovel(novel.id), throwsStateError);
    await repo.updateTask(task.id, status: TaskStatus.cancelled);

    await repo.deleteNovel(novel.id);
    expect((await repo.listNovels(includeArchived: true)).map((n) => n.id), [
      kept.id,
    ]);
    for (final key in [
      'goal/${novel.id}',
      'syncState/${novel.id}',
      'htmlVariables/$branch',
    ]) {
      expect(await repo.getSetting(key), isNull, reason: key);
    }
    expect(await repo.getStory(kept.activeBranchId), isNotNull);
  });
}
