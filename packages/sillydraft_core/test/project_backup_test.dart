import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

void main() {
  test('authenticated malformed nested data cannot replace a healthy project', () async {
    final dir = await Directory.systemTemp.createTemp(
      'sillydraft-invalid-backup-',
    );
    final repo = StoryRepository.memory();
    addTearDown(() async {
      await repo.close();
      await dir.delete(recursive: true);
    });
    final novel = await repo.createNovel(title: '不能破坏的作品');

    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('完整正文'),
    );
    final other = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('第二场'),
    );
    await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '人物',
      content: '介绍',
      atChapterId: chapter.id,
      provenance: {'chapterId': chapter.id, 'revisionId': chapter.revisionId},
    );
    await repo.setBranchVariables(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedVersion: 0,
      local: {'name': '人物'},
    );
    await repo.setSetting('writing/${novel.activeBranchId}', {
      'userName': '主角',
    });
    await repo.setReadingProgress(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      fraction: .5,
    );
    final backup = ProjectBackup(
      repository: repo,
      assets: AssetLibrary(repository: repo, directory: dir),
      resources: ResourceLibrary(
        repository: repo,
        keyProvider: () async => List.filled(32, 1),
      ),
    );
    final original = await repo.exportProject(novel.id);
    final mutations = <(String, String, Map<String, dynamic>, String?)>[
      ('lore_versions', 'provenance_json', {'chapterId': 42}, null),
      (
        'lore_versions',
        'provenance_json',
        {'chapterId': chapter.id, 'revisionId': other.revisionId},
        null,
      ),
      ('lore_versions', 'data_json', {'appearance': <dynamic>[]}, null),
      ('variable_revisions', 'local_json', {'name': 42}, null),
      ('branch_variables', 'global_json', {'state': <dynamic>[]}, null),
      (
        'app_settings',
        'value_json',
        {'userName': <dynamic>[]},
        'writing/${novel.activeBranchId}',
      ),
      (
        'app_settings',
        'value_json',
        {'selectedOrderId': 'bad'},
        'writing/${novel.activeBranchId}',
      ),
      (
        'app_settings',
        'value_json',
        {'chapterId': chapter.id, 'fraction': 'bad'},
        'progress/${novel.activeBranchId}',
      ),
      (
        'revisions',
        'content_json',
        {
          'version': 1,
          'delta': [
            {
              'insert': '损坏的标题\n',
              'attributes': {'header': <dynamic>[]},
            },
          ],
        },
        null,
      ),
    ];
    for (final (table, column, value, key) in mutations) {
      final raw = original.toJson(), tables = raw['tables'] as Map;
      final rows = tables[table] as List;
      final row = key == null
          ? rows.first as Map
          : rows.singleWhere((r) => r['key'] == key) as Map;
      row[column] = jsonEncode(value);
      // Deliberately valid encryption/MAC and manifest: schema validation must
      // reject the payload, rather than relying on transport authentication.
      final bytes = await backup.createSnapshot(
        ProjectSnapshot.fromJson(raw),
        passphrase: 'valid test passphrase',
      );
      await expectLater(
        backup.restore(
          bytes,
          passphrase: 'valid test passphrase',
          asCopy: false,
          expectedFingerprint: original.fingerprint,
        ),
        throwsFormatException,
        reason: '$table.$column $value',
      );
      expect(
        (await repo.exportProject(novel.id)).fingerprint,
        original.fingerprint,
      );
      expect((await repo.listLore(novel.activeBranchId)).single.name, '人物');
    }
  });

  test('encrypted project restores complete branches, history, lore, assets and ST originals with a different local key', () async {
    final dir = await Directory.systemTemp.createTemp('sillydraft-backup-');
    final a = StoryRepository.open('${dir.path}/a.sqlite');
    var b = StoryRepository.open('${dir.path}/b.sqlite');
    addTearDown(() async {
      await a.close();
      await b.close();
      await dir.delete(recursive: true);
    });
    final aa = AssetLibrary(
      repository: a,
      directory: Directory('${dir.path}/a-assets'),
    );
    final ba = AssetLibrary(
      repository: b,
      directory: Directory('${dir.path}/b-assets'),
    );
    final ar = ResourceLibrary(
      repository: a,
      keyProvider: () async => List.filled(32, 1),
    );
    final br = ResourceLibrary(
      repository: b,
      keyProvider: () async => List.filled(32, 2),
    );
    final source = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'name': '苏雾',
          'first_mes': '雾来了。',
          'api_key': 'original-only-secret',
          'extensions': {'unknown': 42},
        }),
      ),
    );
    final card = await ar.import(
      source,
      filename: 'card.json',
      kind: ResourceKind.character,
    );
    final novel = await a.createNovelFromCard(resourceId: card.id, title: '雾港');
    var chapter = (await a.getStory(novel.activeBranchId)).chapters.single;
    final firstRevision = chapter.revisionId;
    chapter = await a.saveChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('潮声来了。'),
    );
    final asset = await aa.importImage(
      branchId: chapter.branchId,
      name: '插图',
      bytes: testPicture(),
    );
    chapter = await a.insertIllustration(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      assetId: asset.id,
      offset: 5,
    );
    await a.setCover(novel.id, asset.id);
    await a.archiveAsset(asset.id, archived: true);
    await a.saveLoreEntry(
      branchId: chapter.branchId,
      kind: LoreKind.foreshadow,
      name: '旧钟',
      content: '待回收',
      certainty: LoreCertainty.plan,
      provenance: {'chapterId': chapter.id, 'revisionId': chapter.revisionId},
    );
    await a.setBranchVariables(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedVersion: (await a.getBranchVariables(chapter.branchId)).version,
      local: {'clue': 'bell'},
      global: {},
    );
    await a.addBookmark(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      label: '线索',
      offset: 2,
    );
    await a.setReadingProgress(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      fraction: .5,
    );
    await a.forkBranch(
      branchId: chapter.branchId,
      name: '另一结局',
      atChapterId: chapter.id,
    );
    final task = await a.createTask(
      branchId: chapter.branchId,
      kind: TaskKind.analysis,
      input: {
        'sourceRevisions': {chapter.id: chapter.revisionId},
      },
    );
    await a.updateTask(
      task.id,
      status: TaskStatus.running,
      partialText: '未完成的整理',
    );
    final before = await a.exportProject(novel.id);
    final backup = ProjectBackup(repository: a, assets: aa, resources: ar);
    final bytes = await backup.create(
      novel.id,
      passphrase: 'correct horse battery staple',
    );
    expect(latin1.decode(bytes), isNot(contains('original-only-secret')));
    final file = File('${dir.path}/novel.sillydraft');
    await file.writeAsBytes(bytes);
    final restore = ProjectBackup(repository: b, assets: ba, resources: br);
    await b.createNovel(title: '现有作品不能消失');
    final restored = await restore.restore(
      await file.readAsBytes(),
      passphrase: 'correct horse battery staple',
    );
    expect(restored.id, isNot(novel.id));
    expect((await b.listNovels()).length, 2);
    final story = await b.getStory(restored.activeBranchId);
    expect(story.text, (await a.getStory(novel.activeBranchId)).text);
    expect((await b.listBranches(restored.id)).length, 2);
    expect(
      (await b.listRevisions(
        branchId: story.branch.id,
        chapterId: story.chapters.single.id,
      )).length,
      3,
    );
    expect(
      (await b.listLore(story.branch.id))
          .any((e) => e.name == '旧钟' && e.certainty == LoreCertainty.plan),
      true,
    );
    expect((await b.getBranchVariables(story.branch.id)).local['clue'], 'bell');
    expect((await b.listBookmarks(story.branch.id)).single.offset, 2);
    expect((await b.getReadingProgress(story.branch.id))?['fraction'], .5);
    final restoredAsset = (await b.listAssets(
      restored.id,
      includeArchived: true,
    )).single;
    expect(restoredAsset.archived, true);
    expect(
      await ba.read(restoredAsset.id),
      orderedEquals(await aa.read(asset.id)),
    );
    expect(restored.coverAssetId, restoredAsset.id);
    final profile = await b.getSetting('writing/${story.branch.id}');
    expect(
      await br.original(profile!['cardId'] as String),
      orderedEquals(source),
    );
    expect(
      (await b.listTasks(branchId: story.branch.id)).single.status,
      TaskStatus.interrupted,
    );
    expect((await a.getRevision(firstRevision)).content.text.trim(), '雾来了。');
    expect((await a.exportProject(novel.id)).fingerprint, before.fingerprint);
    await expectLater(
      restore.restore(bytes, passphrase: 'wrong password'),
      throwsFormatException,
    );
    final corrupted = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
    await expectLater(
      restore.restore(corrupted, passphrase: 'correct horse battery staple'),
      throwsFormatException,
    );
    expect((await b.listNovels()).length, 2);
    await b.close();
    b = StoryRepository.open('${dir.path}/b.sqlite');
    expect((await b.getStory(restored.activeBranchId)).text, story.text);
    final reopened = ResourceLibrary(
      repository: b,
      keyProvider: () async => List.filled(32, 2),
    );
    expect(
      await reopened.original(profile['cardId'] as String),
      orderedEquals(source),
    );
    expect(
      latin1.decode(await File('${dir.path}/b.sqlite').readAsBytes()),
      isNot(contains('original-only-secret')),
    );
  });

  test('snapshot restore refuses foreign references atomically and replacement requires exact local revision', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '保存中的作品');

    final s = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('旧正文'),
    );
    final snapshot = await repo.exportProject(novel.id);
    final raw = snapshot.toJson();
    ((raw['tables'] as Map)['branch_chapters'] as List).single['revision_id'] =
        'outside-project';
    await expectLater(
      repo.restoreProject(ProjectSnapshot.fromJson(raw), encryptedSources: {}),
      throwsFormatException,
    );
    expect((await repo.listNovels()).length, 1);
    final embedded = snapshot.copy().snapshot.toJson();
    ((embedded['tables'] as Map)['revisions'] as List).single['content_json'] =
        ManuscriptContent.fromDelta([
          {
            'insert': {'image': 'file:///private-data.png'},
          },
        ]).encoded;
    await expectLater(
      repo.restoreProject(
        ProjectSnapshot.fromJson(embedded),
        encryptedSources: {},
      ),
      throwsFormatException,
    );
    expect(
      (await repo.listNovels()).length,
      1,
      reason:
          'Late validation failure must roll back all inserted project rows',
    );
    await repo.saveChapter(
      branchId: s.branchId,
      chapterId: s.id,
      expectedRevisionId: s.revisionId,
      content: ManuscriptContent.plainText('用户的新正文'),
    );
    await expectLater(
      repo.restoreProject(
        snapshot,
        encryptedSources: {},
        expectedFingerprint: snapshot.fingerprint,
      ),
      throwsA(isA<ProjectConflict>()),
    );
    expect((await repo.getStory(s.branchId)).text.trim(), '用户的新正文');
  });
}
