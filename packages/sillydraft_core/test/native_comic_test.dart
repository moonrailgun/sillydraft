import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

ComicDocument originalFixture(String chapterId) =>
    ComicDocument.original(chapterId: chapterId, instruction: '雨夜收到未来短信').edit({
      'panels': [
        {
          'id': 'p1',
          'factIds': <String>[],
          'sceneId': 'train',
          'description': '女孩看手机',
          'continuity': '女孩穿蓝衣',
          'texts': [
            {'kind': 'dialogue', 'speaker': '女孩', 'text': '谁？'},
          ],
          'referenceAssetIds': <String>[],
        },
        {
          'id': 'p2',
          'factIds': <String>[],
          'sceneId': 'train',
          'description': '手机亮起',
          'continuity': '手机屏幕有短信',
          'texts': <dynamic>[],
          'referenceAssetIds': <String>[],
        },
      ],
      'pages': [
        {
          'id': 'page1',
          'panelIds': ['p1', 'p2'],
          'referenceAssetIds': <String>[],
        },
      ],
    });

void main() {
  late StoryRepository repo;
  late Novel novel;
  late Chapter chapter;
  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '原创', workFormat: WorkFormat.comic);
    chapter = await repo.createChapter(branchId: novel.activeBranchId);
  });
  tearDown(() => repo.close());
  test('original persists without a prose source and survives copy', () async {
    final saved = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: originalFixture(chapter.id),
      expectedRevisionId: null,
    );
    expect(saved.document.isOriginal, isTrue);
    expect(saved.document.sourceRevisionId, isNull);
    expect(
      (await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text.trim(),
      isEmpty,
    );
    final copy = (await repo.exportProject(novel.id)).copy();
    final imported = await repo.restoreProject(
      copy.snapshot,
      encryptedSources: {},
    );
    final story = await repo.getStory(imported.activeBranchId);
    final result = (await repo.getComic(
      imported.activeBranchId,
      story.chapters.single.id,
    ))!.document;
    expect(result.isOriginal, isTrue);
    expect(result.pages.single['panelIds'], ['p1', 'p2']);
  });
  test('original cannot smuggle novel evidence or invalid page membership', () {
    final doc = originalFixture(chapter.id);
    expect(
      () => doc.edit({'sourceRevisionId': chapter.revisionId}),
      throwsFormatException,
    );
    expect(
      () => doc.edit({
        'pages': [
          {
            'id': 'page1',
            'panelIds': ['p1'],
            'referenceAssetIds': <String>[],
          },
        ],
      }),
      throwsFormatException,
    );
    final legacy = ComicDocument.draft(chapter: chapter).toJson()
      ..remove('sourceRevisionId');
    expect(() => ComicDocument.fromJson(legacy), throwsFormatException);
  });
  test('reordering and removing prior episodes stale context but preserve copied history', () async {
    final first = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: originalFixture(chapter.id),
      expectedRevisionId: null,
    );
    final middle = await repo.createChapter(branchId: novel.activeBranchId);
    final last = await repo.createChapter(branchId: novel.activeBranchId);
    final doc = originalFixture(last.id).edit({
      'priorComics': [
        {'chapterId': chapter.id, 'revisionId': first.id},
        {'chapterId': middle.id, 'revisionId': null},
      ],
    });
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: last.id,
      document: doc,
      expectedRevisionId: null,
    );
    expect(await repo.comicSourcesCurrent(novel.activeBranchId, doc), isTrue);
    await repo.reorderChapters(
      branchId: novel.activeBranchId,
      chapterIds: [middle.id, chapter.id, last.id],
    );
    expect(await repo.comicSourcesCurrent(novel.activeBranchId, doc), isFalse);
    await repo.deleteChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
    );
    expect(await repo.comicSourcesCurrent(novel.activeBranchId, doc), isFalse);
    final copy = (await repo.exportProject(novel.id)).copy();
    final restored = await repo.restoreProject(
      copy.snapshot,
      encryptedSources: {},
    );
    final copied = (await repo.getComic(
      restored.activeBranchId,
      copy.ids[last.id]!,
    ))!;
    expect(
      copied.document.priorComics.first['chapterId'],
      copy.ids[chapter.id],
    );
    expect(copied.document.priorComics.first['revisionId'], copy.ids[first.id]);
    expect(
      await repo.comicSourcesCurrent(restored.activeBranchId, copied.document),
      isFalse,
    );
  });
  test('dialogue edits invalidate a complete page and preserve its image', () {
    final doc = originalFixture(chapter.id)
        .withImage('page1', assetId: 'image1', taskId: 'task1');
    expect(doc.complete, isTrue);
    final panels = doc.panels;
    (panels.first['texts'] as List).first['text'] = '你是谁？';
    final changed = doc.editPanels(panels);
    expect(changed.pages.single['assetId'], 'image1');
    expect(changed.complete, isFalse);
    expect(doc.complete, isTrue);
    final remapped = remapComicDocument(doc, {
      'image1': 'image2',
      'task1': 'task2',
      chapter.id: 'chapter2',
    });
    expect(remapped.complete, isTrue);
    expect(remapped.assetIds, contains('image2'));
  });
}
