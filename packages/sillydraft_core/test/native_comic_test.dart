import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'comic_store_test.dart' show comicFixture;

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

/// Page 2 continues from page 1, so deleting page 1 must drop the link.
ComicDocument twoPageFixture(String chapterId) {
  final doc = originalFixture(chapterId);
  return doc.edit({
    'panels': [
      ...doc.panels,
      {
        'id': 'p3',
        'factIds': <String>[],
        'sceneId': 'street',
        'description': '女孩下车',
        'continuity': '女孩穿蓝衣',
        'texts': <dynamic>[],
        'previousPanelId': 'p2',
        'referenceAssetIds': <String>[],
      },
    ],
    'pages': [
      ...doc.pages,
      {
        'id': 'page2',
        'panelIds': ['p3'],
        'referenceAssetIds': <String>[],
      },
    ],
  });
}

ComicDocument audited(ComicDocument doc) => ComicDocument.fromJson({
  ...doc.toJson(),
  'audit': {
    'fingerprint': doc.fingerprint,
    'reviews': [
      {'id': 'original', 'unitIds': <String>[], 'issues': <String>[]},
    ],
  },
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
  test('reordering and removing prior episodes keep originals current and preserve copied history', () async {
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
    expect(await repo.comicSourcesCurrent(novel.activeBranchId, doc), isTrue);
    await repo.deleteChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
    );
    expect(await repo.comicSourcesCurrent(novel.activeBranchId, doc), isTrue);
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
      isTrue,
    );
  });
  test('dialogue edits stale a drawn page and preserve its image', () {
    final doc = originalFixture(chapter.id)
        .withImage('page1', assetId: 'image1', taskId: 'task1');
    expect(doc.complete, isTrue);
    expect(doc.stalePageIds, isEmpty);
    final panels = doc.panels;
    (panels.first['texts'] as List).first['text'] = '你是谁？';
    final changed = doc.editPanels(panels);
    expect(changed.pages.single['assetId'], 'image1');
    expect(changed.complete, isTrue);
    expect(changed.stalePageIds, ['page1']);
    expect(doc.complete, isTrue);
    final remapped = remapComicDocument(doc, {
      'image1': 'image2',
      'task1': 'task2',
      chapter.id: 'chapter2',
    });
    expect(remapped.complete, isTrue);
    expect(remapped.assetIds, contains('image2'));
  });
  test('complete ignores review and stale fingerprint for originals', () async {
    final drawn = originalFixture(
      chapter.id,
    ).withImage('page1', assetId: 'image1', taskId: 'task1', needsReview: true);
    final panels = drawn.panels;
    panels.first['description'] = '女孩回头';
    final doc = drawn.editPanels(panels);
    expect(doc.pages.single['visualReview'], isTrue);
    expect(doc.complete, isTrue);
    expect(doc.stalePageIds, ['page1']);
    expect(doc.lastPageId, 'page1');
    final prose = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('门开了。'),
    );
    final adaptation = comicFixture(prose).asPages();
    expect(
      adaptation
          .withImage(
            adaptation.lastPageId!,
            assetId: 'image2',
            taskId: 'task2',
            needsReview: true,
          )
          .complete,
      isFalse,
    );
  });
  test('page characters are validated and not fingerprinted', () {
    final doc = audited(originalFixture(chapter.id))
        .withImage('page1', assetId: 'image1', taskId: 'task1');
    ComicDocument withCast(List<Object?> names) => ComicDocument.fromJson({
      ...doc.toJson(),
      'pages': [
        {...doc.pages.single, 'characters': names},
      ],
    });
    final cast = withCast(['女孩', '列车员']);
    expect(cast.pages.single['characters'], ['女孩', '列车员']);
    // Characters steer reference images, not the storyboard: still checked, fresh.
    expect(cast.checked, isTrue);
    expect(cast.stalePageIds, isEmpty);
    expect(
      cast.pageFingerprint(cast.pages.single),
      doc.pageFingerprint(doc.pages.single),
    );
    expect(withCast([]).fingerprint, cast.fingerprint);
    for (final bad in [
      List.generate(17, (i) => '角色$i'),
      ['女孩', '女孩'],
      [' '],
      ['长' * 101],
      [1],
    ]) {
      expect(() => withCast(bad), throwsFormatException, reason: '$bad');
    }
  });
  test('withoutPage removes the page and its panels', () {
    final doc = audited(twoPageFixture(chapter.id));
    final next = doc.withoutPage('page1');
    expect(next.pages.map((p) => p['id']), ['page2']);
    expect(next.panels.map((p) => p['id']), ['p3']);
    expect(next.panels.single.containsKey('previousPanelId'), isFalse);
    expect(next.toJson()['audit'], isNull);
    expect(next.withoutPage('page2').pages, isEmpty);
    expect(() => doc.withoutPage('missing'), throwsFormatException);
  });
  test('deleting or editing a page never stales its neighbours', () {
    final two = twoPageFixture(chapter.id);
    var doc = two.edit({
      'panels': [
        ...two.panels,
        {
          'id': 'p4',
          'factIds': <String>[],
          'sceneId': 'street',
          'description': '女孩擑伞',
          'continuity': '',
          'texts': <dynamic>[],
          'previousPanelId': 'p3',
          'referenceAssetIds': <String>[],
        },
      ],
      'pages': [
        ...two.pages,
        {
          'id': 'page3',
          'panelIds': ['p4'],
          'referenceAssetIds': <String>[],
        },
      ],
    });
    for (final id in ['page1', 'page2', 'page3']) {
      doc = doc.withImage(id, assetId: 'image-$id', taskId: 'task-$id');
    }
    final deleted = doc.withoutPage('page2');
    expect(deleted.panels.last.containsKey('previousPanelId'), isFalse);
    expect(deleted.stalePageIds, isEmpty);
    // Replacing page 2's only panel drops page 3's link but stales only page 2.
    final edited = doc.editPage('page2', [
      {...doc.panels[2], 'id': 'p3b'},
    ]);
    expect(edited.panels.last.containsKey('previousPanelId'), isFalse);
    expect(edited.stalePageIds, ['page2']);
  });
  test('editPage adds and reorders panels within one page', () {
    final doc = audited(
      twoPageFixture(chapter.id)
          .withImage('page1', assetId: 'image1', taskId: 'task1')
          .withImage('page2', assetId: 'image2', taskId: 'task2'),
    );
    final page2 = doc.panels.where((p) => p['id'] == 'p3').toList();
    expect(doc.editPage('page2', page2).toJson()['audit'], isNotNull);
    final edited = doc.editPage(
      'page2',
      [
        ...page2,
        {
          'id': 'new',
          'factIds': <String>[],
          'sceneId': 'street',
          'description': '雨停了',
          'continuity': '',
          'texts': <dynamic>[],
          'referenceAssetIds': <String>[],
        },
      ].reversed.toList(),
    );
    expect(edited.pages.last['panelIds'], ['new', 'p3']);
    expect(edited.pages.first, doc.pages.first);
    expect(edited.panels.map((p) => p['id']), ['p1', 'p2', 'new', 'p3']);
    expect(edited.pages.last['assetId'], 'image2');
    expect(edited.stalePageIds, ['page2']);
    expect(edited.toJson()['audit'], isNull);
    expect(
      [
        ...edited.pages,
        ...edited.panels,
      ].every((p) => p['visualReview'] != true),
      isTrue,
    );
    expect(() => doc.editPage('page2', []), throwsFormatException);
    expect(() => doc.editPage('missing', page2), throwsFormatException);
  });
  test('restore keeps originals unflagged', () async {
    final branchId = novel.activeBranchId;
    Future<String> picture(String hex) async => (await repo.storeAsset(
      branchId: branchId,
      name: '页',
      prepared: PreparedAsset(
        hash: hex * 64,
        thumbnailHash: hex * 64,
        width: 1,
        height: 1,
        byteLength: 1,
      ),
    )).id;
    ComicDocument drawn(
      ComicDocument doc,
      String assetId, [
      List<String> references = const [],
    ]) {
      final page = {...doc.pages.single, 'referenceAssetIds': references};
      return doc.edit({
        'pages': [
          {
            ...page,
            'assetId': assetId,
            'fingerprint': doc.pageFingerprint(page),
          },
        ],
      });
    }

    final image = await picture('a');
    final first = await repo.saveComic(
      branchId: branchId,
      chapterId: chapter.id,
      document: drawn(originalFixture(chapter.id), image),
      expectedRevisionId: null,
    );
    // A later episode draws from the first page's image.
    final next = await repo.createChapter(branchId: branchId);
    final follower = await repo.saveComic(
      branchId: branchId,
      chapterId: next.id,
      document: drawn(
        originalFixture(next.id).edit({
          'priorComics': [
            {'chapterId': chapter.id, 'revisionId': first.id},
          ],
        }),
        await picture('b'),
        [image],
      ),
      expectedRevisionId: null,
    );
    final panels = first.document.panels;
    panels.first['description'] = '女孩回头';
    final edited = await repo.saveComic(
      branchId: branchId,
      chapterId: chapter.id,
      document: first.document.editPanels(panels),
      expectedRevisionId: first.id,
    );
    final restored = await repo.restoreComic(
      branchId: branchId,
      chapterId: chapter.id,
      revisionId: first.id,
      expectedRevisionId: edited.id,
    );
    for (final doc in [edited.document, restored.document]) {
      expect(doc.pages.every((p) => p['visualReview'] != true), isTrue);
    }
    expect((await repo.getComic(branchId, next.id))!.id, follower.id);
  });
  test('undo delete after newer write conflicts', () async {
    final branchId = novel.activeBranchId;
    Future<ComicRevision> save(ComicDocument doc, String? head) =>
        repo.saveComic(
          branchId: branchId,
          chapterId: chapter.id,
          document: doc,
          expectedRevisionId: head,
        );
    final a = await save(twoPageFixture(chapter.id), null);
    final b = await save(a.document.withoutPage('page1'), a.id);
    final panels = b.document.panels;
    panels.single['description'] = '女孩在雨中下车';
    final c = await save(b.document.editPage('page2', panels), b.id);
    await expectLater(
      repo.restoreComic(
        branchId: branchId,
        chapterId: chapter.id,
        revisionId: a.id,
        expectedRevisionId: b.id,
      ),
      throwsA(isA<ComicConflict>()),
    );
    expect((await repo.getComic(branchId, chapter.id))!.id, c.id);
  });
}
