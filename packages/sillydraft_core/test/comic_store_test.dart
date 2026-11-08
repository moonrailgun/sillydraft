import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

ComicDocument comicFixture(Chapter chapter) {
  final draft = ComicDocument.draft(chapter: chapter, style: '黑白线稿');
  return ComicDocument.fromJson({
    ...draft.toJson(),
    'facts': [
      for (final u in draft.units.where((u) => u['disposition'] == 'story'))
        {
          'id': 'f-${u['id']}',
          'kind': 'action',
          'summary': u['text'],
          'unitIds': [u['id']],
          'evidence': u['text'],
          'dependsOn': <String>[],
        },
    ],
    'panels': [
      for (final u in draft.units.where((u) => u['disposition'] == 'story'))
        {
          'id': 'p-${u['id']}',
          'factIds': ['f-${u['id']}'],
          'sceneId': 'scene-test',
          'description': u['text'],
          'continuity': '门保持关闭',
          'texts': <dynamic>[],
          'referenceAssetIds': <String>[],
        },
    ],
  });
}

void main() {
  late StoryRepository repo;
  late Novel novel;
  late Chapter chapter;
  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '门外', workFormat: WorkFormat.comic);
    chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。\n她按住门闩，没有开门。'),
    );
  });
  tearDown(() => repo.close());

  test('panel changes invalidate audit and dependent visuals safely', () {
    var doc = comicFixture(chapter);
    final panels = doc.panels;
    panels.first['assetId'] = 'old-picture';
    panels.last['assetId'] = 'next-picture';
    panels.last['previousPanelId'] = panels.first['id'];
    doc = ComicDocument.fromJson({...doc.toJson(), 'panels': panels});
    doc = ComicDocument.fromJson({
      ...doc.toJson(),
      'audit': {
        'fingerprint': doc.fingerprint,
        'reviews': [
          for (final scope in doc.reviewScopes.entries)
            {'id': scope.key, 'unitIds': scope.value, 'issues': <String>[]},
        ],
      },
    });
    final linked = doc.panels..first['assetId'] = 'replacement';
    final changed = doc.editPanels(linked);
    expect(changed.checked, isTrue);
    expect(changed.panels.last['visualReview'], isTrue);
    final reordered = doc.editPanels(doc.panels.reversed.toList());
    expect(reordered.checked, isFalse);
    expect(reordered.panels.first['previousPanelId'], isNull);
    expect(reordered.panels.first['visualReview'], isTrue);
    expect(doc.panels.last['previousPanelId'], doc.panels.first['id']);
  });

  test('visual review follows backward chains and cycles without flagging unrelated panels', () async {
    chapter = await repo.saveChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      content: ManuscriptContent.plainText('藏信。锁门。关窗。熄灯。'),
      expectedRevisionId: chapter.revisionId,
    );
    var doc = comicFixture(chapter);
    final panels = doc.panels;
    for (final (i, panel) in panels.indexed) {
      panel['assetId'] = 'image-$i';
      panel['visualReview'] = false;
    }
    panels[0]['referenceAssetIds'] = ['image-1'];
    panels[1]['referenceAssetIds'] = ['image-2'];
    panels[2]['referenceAssetIds'] = ['image-0'];
    doc = ComicDocument.fromJson({...doc.toJson(), 'panels': panels});
    panels[2]['assetId'] = 'replacement';
    final changed = doc.editPanels(panels);
    expect(changed.panels.map((p) => p['visualReview']), [
      true,
      true,
      true,
      false,
    ]);
    final confirmed = changed.panels;
    confirmed.first['visualReview'] = false;
    expect(changed.editPanels(confirmed).panels.first['visualReview'], isFalse);
    expect(doc.panels.every((p) => p['visualReview'] == false), isTrue);
  });

  test('removing a referenced panel flags its earlier dependent', () {
    var doc = comicFixture(chapter);
    final panels = doc.panels;
    panels.first['assetId'] = 'dependent';
    panels.first['referenceAssetIds'] = ['removed'];
    panels.last['assetId'] = 'removed';
    doc = ComicDocument.fromJson({...doc.toJson(), 'panels': panels});
    final changed = doc.editPanels(panels..removeLast());
    expect(changed.panels.single['visualReview'], isTrue);
  });

  test(
    'candidate adoption and discard are atomic and protect preview head',
    () async {
      final doc = comicFixture(chapter);
      final head = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: doc,
        expectedRevisionId: null,
      );
      final task = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.comic,
        input: {
          'comicHeads': {chapter.id: head.id},
        },
      );
      await repo.saveComicTaskDocument(
        task.id,
        doc.edit({'style': '彩色'}),
        candidateOnly: true,
      );
      await repo.updateTask(task.id, status: TaskStatus.completed);
      await expectLater(
        repo.resolveComicCandidate(
          taskId: task.id,
          chapterId: chapter.id,
          expectedRevisionId: 'stale',
          adopt: true,
        ),
        throwsA(isA<ComicConflict>()),
      );
      expect((await repo.getTask(task.id)).result['comicCandidates'], [
        chapter.id,
      ]);
      await repo.resolveComicCandidate(
        taskId: task.id,
        chapterId: chapter.id,
        expectedRevisionId: head.id,
        adopt: true,
      );
      final adopted = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      expect(adopted.parentRevisionId, head.id);
      expect(adopted.document.style, '彩色');
      expect(adopted.document.checked, isFalse);
      expect((await repo.getTask(task.id)).result['comicCandidates'], isEmpty);
      expect(
        (await repo.getTask(task.id)).result['comicDocuments'],
        isNotEmpty,
      );
      final discarded = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.comic,
        input: {
          'comicHeads': {chapter.id: adopted.id},
        },
      );
      await repo.saveComicTaskDocument(discarded.id, doc, candidateOnly: true);
      await repo.updateTask(discarded.id, status: TaskStatus.failed);
      await repo.resolveComicCandidate(
        taskId: discarded.id,
        chapterId: chapter.id,
        expectedRevisionId: adopted.id,
        adopt: false,
      );
      expect(
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
        adopted.id,
      );
      expect(
        (await repo.getTask(discarded.id)).result['comicCandidates'],
        isEmpty,
      );
    },
  );

  test('source splitting preserves all characters and UTF-16 boundaries', () {
    final text = '😀信${'字' * 1500}。\n门外。';
    final units = splitComicSource(text, maxUnitLength: 20);
    expect(units.map((u) => u['text']).join(), text);
    for (final u in units) {
      expect(text.substring(u['start'] as int, u['end'] as int), u['text']);
      expect(
        (u['text'] as String).runes.any((r) => r >= 0xd800 && r <= 0xdfff),
        isFalse,
      );
    }
  });

  for (final repeated in [false, true]) {
    test(
      'dialogue follows source order across panels and within one panel (repeated: $repeated)',
      () async {
        final speeches = [('阿宁', '等一下'), ('哥哥', repeated ? '等一下' : '开门')];
        final source = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText(
            '${speeches.map((s) => '${s.$1}说：“${s.$2}”').join('，')}。',
          ),
        );
        final draft = ComicDocument.draft(chapter: source);
        final facts = [
          for (final (i, speech) in speeches.indexed)
            {
              'id': 'd$i',
              'kind': 'dialogue',
              'summary': speech.$2,
              'unitIds': [draft.units.first['id']],
              'evidence': '${speech.$1}说：“${speech.$2}”',
              'dependsOn': <String>[],
              'speaker': speech.$1,
              'quote': speech.$2,
            },
        ];
        final panels = [
          for (final f in facts)
            {
              'id': 'p-${f['id']}',
              'factIds': [f['id']],
              'sceneId': 'room',
              'description': f['summary'],
              'continuity': '',
              'referenceAssetIds': <String>[],
              'texts': [
                {
                  'kind': 'dialogue',
                  'speaker': f['speaker'],
                  'text': f['quote'],
                  'factId': f['id'],
                },
              ],
            },
        ];
        final doc = draft.edit({'facts': facts, 'panels': panels});
        expect(doc.structuralIssues, isEmpty);
        final reversed = doc.edit({'panels': panels.reversed.toList()});
        expect(reversed.structuralIssues, contains(contains('对白顺序')));
        expect(
          doc.edit({
            'facts': facts.reversed.toList(),
            'panels': panels.reversed.toList(),
          }).structuralIssues,
          contains(contains('对白顺序')),
        );
        final combined = doc.edit({
          'panels': [
            {
              ...panels.first,
              'factIds': facts.map((f) => f['id']).toList(),
              'texts': [
                for (final p in panels.reversed) ...(p['texts'] as List),
              ],
            },
          ],
        });
        expect(combined.structuralIssues, contains(contains('对白顺序')));
        expect(
          () => ComicDocument.fromJson({
            ...reversed.toJson(),
            'audit': {
              'fingerprint': reversed.fingerprint,
              'reviews': [
                for (final scope in reversed.reviewScopes.entries)
                  {
                    'id': scope.key,
                    'unitIds': scope.value,
                    'issues': <String>[],
                  },
              ],
            },
          }),
          throwsFormatException,
        );
      },
    );
  }

  test('rejects invalid references and forged audit approval', () {
    final doc = comicFixture(chapter);
    expect(doc.structuralIssues, isEmpty);
    final bad = doc.toJson();
    (bad['panels'] as List).first['factIds'] = ['missing'];
    expect(() => ComicDocument.fromJson(bad), throwsFormatException);
    expect(
      () => ComicDocument.fromJson({
        ...doc.toJson(),
        'audit': {
          'fingerprint': doc.fingerprint,
          'reviews': <dynamic>[],
          'issues': <String>[],
        },
      }),
      throwsFormatException,
    );
    expect(
      ComicDocument.fromJson({...doc.toJson(), 'panels': <dynamic>[]})
          .structuralIssues,
      isNotEmpty,
    );
  });

  test(
    'versioned saves protect concurrent edits and fork only through cutoff',
    () async {
      final doc = comicFixture(chapter);
      final first = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: doc,
        expectedRevisionId: null,
      );
      final later = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('哥哥离开。'),
      );
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: later.id,
        document: comicFixture(later).edit({
          'priorSources': [
            {'chapterId': chapter.id, 'revisionId': chapter.revisionId},
          ],
        }),
        expectedRevisionId: null,
      );
      final fork = await repo.forkBranch(
        branchId: novel.activeBranchId,
        name: '岔路',
        atChapterId: chapter.id,
      );
      expect((await repo.getComic(fork.id, chapter.id))!.id, first.id);
      expect(await repo.getComic(fork.id, later.id), isNull);
      final second = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: ComicDocument.fromJson(doc.toJson()..['style'] = '彩色'),
        expectedRevisionId: first.id,
      );
      await expectLater(
        repo.saveComic(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          document: doc,
          expectedRevisionId: first.id,
        ),
        throwsA(isA<ComicConflict>()),
      );
      expect((await repo.getComic(fork.id, chapter.id))!.id, first.id);
      expect(
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
        second.id,
      );
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).revisionId,
        chapter.revisionId,
      );
      await repo.deleteChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      );
      expect(await repo.getComic(novel.activeBranchId, chapter.id), isNull);
      expect((await repo.getComic(fork.id, chapter.id))!.id, first.id);
    },
  );

  test(
    'history restore checks ownership and head, preserving stale sources',
    () async {
      final original = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: comicFixture(chapter),
        expectedRevisionId: null,
      );
      final current = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: original.document.edit({'style': '彩色'}),
        expectedRevisionId: original.id,
      );
      await expectLater(
        repo.restoreComic(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          revisionId: original.id,
          expectedRevisionId: original.id,
        ),
        throwsA(isA<ComicConflict>()),
      );
      final other = await repo.createChapter(branchId: novel.activeBranchId);
      await expectLater(
        repo.restoreComic(
          branchId: novel.activeBranchId,
          chapterId: other.id,
          revisionId: original.id,
          expectedRevisionId: null,
        ),
        throwsFormatException,
      );
      expect(await repo.getComic(novel.activeBranchId, other.id), isNull);
      expect(
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
        current.id,
      );
      await repo.saveChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: chapter.revisionId,
        content: ManuscriptContent.plainText('她打开了门。'),
      );
      final restored = await repo.restoreComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        revisionId: original.id,
        expectedRevisionId: current.id,
      );
      expect(restored.parentRevisionId, current.id);
      expect(restored.document.sourceRevisionId, chapter.revisionId);
      expect(
        await repo.comicSourcesCurrent(novel.activeBranchId, restored.document),
        isFalse,
      );
      expect(
        restored.document.panels.every((p) => p['visualReview'] != true),
        isTrue,
      );
    },
  );

  test(
    'backup copy remaps external ids, keeps panel ids, and restores history',
    () async {
      final doc = comicFixture(chapter);
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: doc,
        expectedRevisionId: null,
      );
      final snapshot = await repo.exportProject(novel.id);
      expect(snapshot.toJson()['version'], 2);
      final copy = snapshot.copy();
      final restored = await repo.restoreProject(
        copy.snapshot,
        encryptedSources: {},
      );
      expect(restored.workFormat, WorkFormat.comic);
      final comic = (await repo.getComic(
        restored.activeBranchId,
        copy.ids[chapter.id]!,
      ))!;
      expect(comic.document.sourceRevisionId, copy.ids[chapter.revisionId]);
      expect(comic.document.panels.first['id'], doc.panels.first['id']);
      expect(comic.document.fingerprint, isNot(doc.fingerprint));
      final broken = copy.snapshot.toJson();
      (broken['tables'] as Map)['branch_comics'][0]['comic_revision_id'] =
          'missing';
      await expectLater(
        repo.restoreProject(
          ProjectSnapshot.fromJson(broken),
          encryptedSources: {},
          expectedFingerprint: (await repo.exportProject(restored.id))
              .fingerprint,
        ),
        throwsFormatException,
      );
      expect(
        (await repo.getComic(
          restored.activeBranchId,
          copy.ids[chapter.id]!,
        ))!.id,
        comic.id,
      );
    },
  );

  test(
    'copied completed candidates can be adopted in the copied work',
    () async {
      final doc = comicFixture(chapter);
      final head = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: doc,
        expectedRevisionId: null,
      );
      final task = await repo.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.comic,
        input: {
          'comicHeads': {chapter.id: head.id},
        },
      );
      await repo.saveComicTaskDocument(
        task.id,
        doc.edit({'style': '彩色'}),
        candidateOnly: true,
      );
      await repo.updateTask(task.id, status: TaskStatus.completed);
      final copy = (await repo.exportProject(novel.id)).copy();
      final restored = await repo.restoreProject(
        copy.snapshot,
        encryptedSources: {},
      );
      await repo.resolveComicCandidate(
        taskId: copy.ids[task.id]!,
        chapterId: copy.ids[chapter.id]!,
        expectedRevisionId: copy.ids[head.id],
        adopt: true,
      );
      final adopted = (await repo.getComic(
        restored.activeBranchId,
        copy.ids[chapter.id]!,
      ))!;
      expect(adopted.document.style, '彩色');
      expect(adopted.document.sourceText, doc.sourceText);
      expect(adopted.document.panels.first['id'], doc.panels.first['id']);
      expect(
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
        head.id,
      );
    },
  );

  test(
    'legacy v1 snapshots migrate explicitly; unknown fields still fail',
    () async {
      final old = (await repo.exportProject(novel.id)).toJson();
      old['version'] = 1;
      old['schema'] = 9;
      final tables = old['tables'] as Map;
      tables.remove('comic_revisions');
      tables.remove('branch_comics');
      (tables['novels'] as List).single.remove('work_format');
      final migrated = ProjectSnapshot.fromJson(old).copy();
      final restored = await repo.restoreProject(
        migrated.snapshot,
        encryptedSources: {},
      );
      expect(restored.workFormat, WorkFormat.novel);
      (tables['novels'] as List).single['unexpected'] = true;
      await expectLater(
        repo.restoreProject(
          ProjectSnapshot.fromJson(old).copy().snapshot,
          encryptedSources: {},
        ),
        throwsFormatException,
      );
    },
  );
}
