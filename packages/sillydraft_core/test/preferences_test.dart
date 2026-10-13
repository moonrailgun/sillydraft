import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'preferences and reader anchors survive a real database restart',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'sillydraft-preferences-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/library.sqlite';
      var repo = StoryRepository.open(path);
      final novel = await repo.createNovel(title: '阅读');

      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('正文'),
      );
      await repo.setSetting('reader', {'fontSize': 22, 'theme': 'sepia'});
      final bookmark = await repo.addBookmark(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        label: '看到这里',
        offset: 2,
      );
      await repo.setReadingProgress(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        fraction: 0.5,
      );
      await repo.close();
      repo = StoryRepository.open(path);
      try {
        expect((await repo.getSetting('reader'))!['fontSize'], 22);
        expect(
          (await repo.listBookmarks(novel.activeBranchId)).single.id,
          bookmark.id,
        );
        expect(
          (await repo.getReadingProgress(novel.activeBranchId))!['chapterId'],
          chapter.id,
        );
        expect(
          (await repo.getReadingProgress(novel.activeBranchId))!['fraction'],
          0.5,
        );
        await repo.removeBookmark(bookmark.id);
        expect(await repo.listBookmarks(novel.activeBranchId), isEmpty);
      } finally {
        await repo.close();
      }
    },
  );

  test('reader progress rejects foreign chapters and ordinary settings reject credentials', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final a = await repo.createNovel(title: '甲'),
        b = await repo.createNovel(title: '乙');

    final chapter = await repo.createChapter(branchId: b.activeBranchId);
    await expectLater(
      repo.setReadingProgress(
        branchId: a.activeBranchId,
        chapterId: chapter.id,
        fraction: 0,
      ),
      throwsA(isA<StoryNotFound>()),
    );
    await expectLater(
      repo.setSetting('model', {'api_key': 'secret'}),
      throwsArgumentError,
    );
    expect(await repo.getSetting('model'), isNull);
  });
}
