import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

void main() {
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
    var scene = (await a.getStory(novel.activeBranchId)).scenes.single;
    final firstRevision = scene.revisionId;
    scene = await a.saveScene(
      branchId: scene.branchId,
      sceneId: scene.id,
      expectedRevisionId: scene.revisionId,
      content: ManuscriptContent.plainText('潮声来了。'),
    );
    final asset = await aa.importImage(
      branchId: scene.branchId,
      name: '插图',
      bytes: testPicture(),
    );
    scene = await a.insertIllustration(
      branchId: scene.branchId,
      sceneId: scene.id,
      expectedRevisionId: scene.revisionId,
      assetId: asset.id,
      offset: 5,
    );
    await a.setCover(novel.id, asset.id);
    await a.archiveAsset(asset.id, archived: true);
    await a.saveLoreEntry(
      branchId: scene.branchId,
      kind: LoreKind.foreshadow,
      name: '旧钟',
      content: '待回收',
      certainty: LoreCertainty.plan,
      provenance: {'sceneId': scene.id, 'revisionId': scene.revisionId},
    );
    await a.setBranchVariables(
      branchId: scene.branchId,
      sceneId: scene.id,
      expectedVersion: (await a.getBranchVariables(scene.branchId)).version,
      local: {'clue': 'bell'},
      global: {},
    );
    await a.addBookmark(
      branchId: scene.branchId,
      sceneId: scene.id,
      label: '线索',
      offset: 2,
    );
    await a.setReadingProgress(
      branchId: scene.branchId,
      sceneId: scene.id,
      fraction: .5,
    );
    await a.forkBranch(
      branchId: scene.branchId,
      name: '另一结局',
      atSceneId: scene.id,
    );
    final task = await a.createTask(
      branchId: scene.branchId,
      kind: TaskKind.analysis,
      input: {
        'sourceRevisions': {scene.id: scene.revisionId},
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
        sceneId: story.scenes.single.id,
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
    final c = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    final s = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: c.id,
      content: ManuscriptContent.plainText('旧正文'),
    );
    final snapshot = await repo.exportProject(novel.id);
    final raw = snapshot.toJson();
    ((raw['tables'] as Map)['branch_scenes'] as List).single['revision_id'] =
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
    await repo.saveScene(
      branchId: s.branchId,
      sceneId: s.id,
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
