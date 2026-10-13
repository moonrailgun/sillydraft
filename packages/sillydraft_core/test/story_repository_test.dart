import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repository;
  setUp(() => repository = StoryRepository.memory());
  tearDown(() => repository.close());

  Future<({Novel novel, Chapter chapter})> seed() async {
    final novel = await repository.createNovel(title: '雾港来信');

    final chapter = await repository.createChapter(
      branchId: novel.activeBranchId,
      title: '渡口',
      content: ManuscriptContent.plainText('林舟在渡口等一封信。'),
    );
    return (novel: novel, chapter: chapter);
  }

  test(
    'saved manuscript survives closing and reopening the real database',
    () async {
      await repository.close();
      final folder = await Directory.systemTemp.createTemp('sillydraft-store-');
      addTearDown(() => folder.delete(recursive: true));
      final path = '${folder.path}/library.sqlite';
      final first = StoryRepository.open(path);
      final novel = await first.createNovel(title: '持久化小说');

      final chapter = await first.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('不要丢掉这句话。'),
      );
      await first.close();
      final second = StoryRepository.open(path);
      try {
        final story = await second.getStory(novel.activeBranchId);
        expect(story.novel.title, '持久化小说');
        expect(story.chapters.single.id, chapter.id);
        expect(story.chapters.single.content.text, '不要丢掉这句话。\n');
        expect(story.chapters.single.revisionId, chapter.revisionId);
      } finally {
        await second.close();
      }
    },
  );

  test('stale saves preserve newer prose and revision history', () async {
    final s = await seed();
    final revised = await repository.saveChapter(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
      expectedRevisionId: s.chapter.revisionId,
      content: ManuscriptContent.plainText('信已经被雨水打湿。'),
    );
    await expectLater(
      repository.saveChapter(
        branchId: s.novel.activeBranchId,
        chapterId: s.chapter.id,
        expectedRevisionId: s.chapter.revisionId,
        content: ManuscriptContent.plainText('过期的编辑。'),
      ),
      throwsA(isA<RevisionConflict>()),
    );
    final story = await repository.getStory(s.novel.activeBranchId);
    expect(story.chapters.single.content.text, '信已经被雨水打湿。\n');
    expect(story.chapters.single.revisionId, revised.revisionId);
    final history = await repository.listRevisions(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
    );
    expect(history, hasLength(2));
    expect(history.last.content.text, '林舟在渡口等一封信。\n');
  });

  test(
    'creating and rejecting a proposal never changes the readable story',
    () async {
      final s = await seed();
      final proposal = await repository.createProposal(
        branchId: s.novel.activeBranchId,
        chapterId: s.chapter.id,
        baseRevisionId: s.chapter.revisionId,
        content: ManuscriptContent.plainText('主角在候选中失踪。'),
        summary: '悬疑方向',
      );
      expect(
        (await repository.getStory(s.novel.activeBranchId))
            .chapters
            .single
            .content
            .text,
        '林舟在渡口等一封信。\n',
      );
      await repository.rejectProposal(proposal.id);
      expect(
        (await repository.getProposal(proposal.id)).status,
        ProposalStatus.rejected,
      );
      await expectLater(
        repository.acceptProposal(proposal.id),
        throwsA(isA<StateError>()),
      );
      expect(
        (await repository.getStory(s.novel.activeBranchId))
            .chapters
            .single
            .revisionId,
        s.chapter.revisionId,
      );
    },
  );

  test('acceptance is idempotent and creates exactly one revision', () async {
    final s = await seed();
    final proposal = await repository.createProposal(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
      baseRevisionId: s.chapter.revisionId,
      content: ManuscriptContent.plainText('林舟终于等到了信。'),
    );
    final first = await repository.acceptProposal(proposal.id);
    final second = await repository.acceptProposal(proposal.id);
    expect(second.id, first.id);
    expect(
      (await repository.getStory(s.novel.activeBranchId))
          .chapters
          .single
          .content
          .text,
      '林舟终于等到了信。\n',
    );
    expect(
      await repository.listRevisions(
        branchId: s.novel.activeBranchId,
        chapterId: s.chapter.id,
      ),
      hasLength(2),
    );
  });

  test('an old AI proposal cannot overwrite a manual edit', () async {
    final s = await seed();
    final proposal = await repository.createProposal(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
      baseRevisionId: s.chapter.revisionId,
      content: ManuscriptContent.plainText('AI 返回的旧候选。'),
    );
    await repository.saveChapter(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
      expectedRevisionId: s.chapter.revisionId,
      content: ManuscriptContent.plainText('用户刚刚写下的新内容。'),
    );
    await expectLater(
      repository.acceptProposal(proposal.id),
      throwsA(isA<RevisionConflict>()),
    );
    expect(
      (await repository.getProposal(proposal.id)).status,
      ProposalStatus.pending,
    );
    expect(
      (await repository.getStory(s.novel.activeBranchId))
          .chapters
          .single
          .content
          .text,
      '用户刚刚写下的新内容。\n',
    );
  });

  test('forks pin old revisions and exclude later chapters', () async {
    final s = await seed();
    await repository.createChapter(
      branchId: s.novel.activeBranchId,
      title: '秘密',
      content: ManuscriptContent.plainText('送信人其实是他的父亲。'),
    );
    final branch = await repository.forkBranch(
      branchId: s.novel.activeBranchId,
      name: '另一封信',
      atChapterId: s.chapter.id,
    );
    await repository.saveChapter(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
      expectedRevisionId: s.chapter.revisionId,
      content: ManuscriptContent.plainText('主线改为没有来信。'),
    );
    final fork = await repository.getStory(branch.id);
    expect(fork.chapters, hasLength(1));
    expect(fork.chapters.single.revisionId, s.chapter.revisionId);
    expect(fork.chapters.single.content.text, '林舟在渡口等一封信。\n');
    final edited = await repository.saveChapter(
      branchId: branch.id,
      chapterId: s.chapter.id,
      expectedRevisionId: s.chapter.revisionId,
      content: ManuscriptContent.plainText('分支里来了一封蓝色的信。'),
    );
    expect(edited.revisionId, isNot(s.chapter.revisionId));
    expect(
      (await repository.getStory(s.novel.activeBranchId))
          .chapters
          .first
          .content
          .text,
      '主线改为没有来信。\n',
    );
  });

  test('another novel branch cannot write a foreign chapter', () async {
    final s = await seed();
    final other = await repository.createNovel(title: '另一部小说');
    await expectLater(
      repository.saveChapter(
        branchId: other.activeBranchId,
        chapterId: s.chapter.id,
        expectedRevisionId: s.chapter.revisionId,
        content: ManuscriptContent.plainText('错误的跨项目写入'),
      ),
      throwsA(isA<StoryNotFound>()),
    );
    expect(
      (await repository.getStory(s.novel.activeBranchId))
          .chapters
          .single
          .revisionId,
      s.chapter.revisionId,
    );
  });

  test(
    'restoring creates a revision and preserves the intervening edit',
    () async {
      final s = await seed();
      final edit = await repository.saveChapter(
        branchId: s.novel.activeBranchId,
        chapterId: s.chapter.id,
        expectedRevisionId: s.chapter.revisionId,
        content: ManuscriptContent.plainText('第二版'),
      );
      final restored = await repository.restoreRevision(
        branchId: s.novel.activeBranchId,
        chapterId: s.chapter.id,
        expectedRevisionId: edit.revisionId,
        revisionId: s.chapter.revisionId,
      );
      expect(restored.revisionId, isNot(s.chapter.revisionId));
      expect(restored.content.text, '林舟在渡口等一封信。\n');
      expect(
        (await repository.getRevision(edit.revisionId)).content.text,
        '第二版\n',
      );
      expect(
        await repository.listRevisions(
          branchId: s.novel.activeBranchId,
          chapterId: s.chapter.id,
        ),
        hasLength(3),
      );
    },
  );

  test('reorder validates a full permutation of branch chapters', () async {
    final s = await seed();
    final second = await repository.createChapter(
      branchId: s.novel.activeBranchId,
      title: '第二幕',
    );
    await repository.reorderChapters(
      branchId: s.novel.activeBranchId,
      chapterIds: [second.id, s.chapter.id],
    );
    expect(
      (await repository.getStory(s.novel.activeBranchId)).chapters
          .map((s) => s.id),
      [second.id, s.chapter.id],
    );
    await expectLater(
      repository.reorderChapters(
        branchId: s.novel.activeBranchId,
        chapterIds: [s.chapter.id, s.chapter.id],
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      (await repository.getStory(s.novel.activeBranchId)).chapters.first.id,
      second.id,
    );
  });

  test(
    'archived novels can be recovered and empty titles are rejected',
    () async {
      final s = await seed();
      await repository.archiveNovel(s.novel.id, archived: true);
      expect(await repository.listNovels(), isEmpty);
      expect(await repository.listNovels(includeArchived: true), hasLength(1));
      await repository.archiveNovel(s.novel.id, archived: false);
      expect((await repository.listNovels(query: '雾港')).single.id, s.novel.id);
      await expectLater(
        repository.createNovel(title: '  '),
        throwsArgumentError,
      );
    },
  );

  test('rich text remains canonical despite caller mutation', () async {
    final delta = <Map<String, dynamic>>[
      {
        'insert': '加粗',
        'attributes': <String, dynamic>{'bold': true},
      },
      {'insert': '\n'},
    ];
    final content = ManuscriptContent.fromDelta(delta);
    (delta.first['attributes'] as Map<String, dynamic>)['bold'] = false;
    final s = await seed();
    await repository.saveChapter(
      branchId: s.novel.activeBranchId,
      chapterId: s.chapter.id,
      expectedRevisionId: s.chapter.revisionId,
      content: content,
    );
    final restored = (await repository.getStory(s.novel.activeBranchId))
        .chapters
        .single
        .content;
    expect(restored.text, '加粗\n');
    expect(restored.delta.first['attributes'], {'bold': true});
    expect(
      () => ManuscriptContent.fromDelta([
        {'delete': 3},
      ]),
      throwsFormatException,
    );
  });
}
