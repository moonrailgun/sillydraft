import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

Uint8List testPicture() => img.encodePng(
  img.Image(
    width: 16,
    height: 12,
    numChannels: 4,
    textData: {'api_key': 'card-source-secret'},
  )..setPixelRgba(1, 1, 255, 80, 40, 255),
);

void main() {
  test(
    'inserting a block illustration preserves the split paragraph heading',
    () {
      final content = ManuscriptContent.fromDelta([
        {'insert': '标题文字'},
        {
          'insert': '\n',
          'attributes': {'header': 1},
        },
      ]).insertImage(2, 'illustration');
      final lineBreaks = content.delta
          .where((op) => op['insert'] == '\n')
          .toList();
      expect(lineBreaks.first['attributes'], {'header': 1});
      expect(lineBreaks.last['attributes'], {'header': 1});
      expect(content.text, '标题\n\uFFFC\n文字\n');
    },
  );
  late Directory dir;
  late StoryRepository repo;
  late AssetLibrary assets;
  late Novel novel;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sillydraft-assets-');
    repo = StoryRepository.open('${dir.path}/test.sqlite');
    assets = AssetLibrary(
      repository: repo,
      directory: Directory('${dir.path}/assets'),
    );
    novel = await repo.createNovel(title: '插画');
  });
  tearDown(() async {
    await repo.close();
    await dir.delete(recursive: true);
  });
  test('startup cleanup removes only aged unreferenced files, keeping archived assets', () async {
    final asset = await assets.importImage(
      branchId: novel.activeBranchId,
      name: '保留插图',
      bytes: testPicture(),
    );
    await repo.archiveAsset(asset.id, archived: true);
    final orphan = File('${assets.directory.path}/${'c' * 64}.png');
    await orphan.writeAsBytes(testPicture());
    await orphan.setLastModified(
      DateTime.now().subtract(const Duration(days: 2)),
    );
    final pending = File('${assets.directory.path}/${'d' * 64}.png');
    await pending.writeAsBytes(testPicture());
    expect(await assets.pruneOrphans(), 1);
    expect(await orphan.exists(), false);
    expect(await pending.exists(), true);
    expect(await assets.read(asset.id), isNotEmpty);
  });
  test(
    'PNG card artwork is extracted without exposing original card metadata',
    () async {
      final resources = ResourceLibrary(
        repository: repo,
        keyProvider: () async => List.filled(32, 9),
      );
      final png = img.encodePng(
        img.Image(
          width: 8,
          height: 8,
          textData: {
            'chara': base64Encode(
              utf8.encode(
                jsonEncode({
                  'name': '苏雾',
                  'description': '守塔人',
                  'api_key': 'card-secret',
                }),
              ),
            ),
          },
        ),
      );
      final card = await resources.import(
        png,
        filename: 'su.png',
        kind: ResourceKind.character,
      );
      final result = await assets.importCardArtwork(
        branchId: novel.activeBranchId,
        resourceId: card.id,
        resources: resources,
      );
      expect(result.assets.length, 1);
      expect(result.warnings, isEmpty);
      expect(
        img.decodePng(await assets.read(result.assets.single.id))!.textData,
        isNull,
      );
      final repeated = await assets.importCardArtwork(
        branchId: novel.activeBranchId,
        resourceId: card.id,
        resources: resources,
      );
      expect(repeated.assets.single.id, result.assets.single.id);
      expect((await repo.listAssets(novel.id)).length, 1);
    },
  );
  test('assets normalize raster data, survive restart, and archive without breaking revisions', () async {
    final asset = await assets.importImage(
      branchId: novel.activeBranchId,
      name: '../../harbor.png',
      bytes: testPicture(),
    );
    expect(asset.width, 16);
    expect(asset.height, 12);
    expect(
      img.decodePng(await assets.read(asset.id))!.textData?['api_key'],
      isNull,
    );
    expect(
      (await assets.file(asset.id)).path,
      startsWith('${dir.path}/assets/'),
    );
    expect((await assets.file(asset.id)).path, isNot(contains('harbor')));

    final s = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('港口。'),
    );
    final inserted = await repo.insertIllustration(
      branchId: s.branchId,
      chapterId: s.id,
      expectedRevisionId: s.revisionId,
      assetId: asset.id,
      offset: 3,
    );
    expect(
      inserted.content.delta.any(
        (op) =>
            op['insert'] is Map &&
            (op['insert'] as Map)['image'] == 'asset:${asset.id}',
      ),
      true,
    );
    await expectLater(
      repo.insertIllustration(
        branchId: s.branchId,
        chapterId: s.id,
        expectedRevisionId: s.revisionId,
        assetId: asset.id,
        offset: 0,
      ),
      throwsA(isA<RevisionConflict>()),
    );
    await repo.archiveAsset(asset.id, archived: true);
    expect(await repo.listAssets(novel.id), isEmpty);
    expect(await assets.read(asset.id), isNotEmpty);
    await repo.close();
    repo = StoryRepository.open('${dir.path}/test.sqlite');
    assets = AssetLibrary(
      repository: repo,
      directory: Directory('${dir.path}/assets'),
    );
    expect(await assets.read(asset.id), isNotEmpty);
    expect(
      (await repo.getChapter(branchId: s.branchId, chapterId: s.id)).revisionId,
      inserted.revisionId,
    );
  });
  test(
    'invalid data and symlinks cannot become trusted local assets',
    () async {
      await expectLater(
        assets.importImage(
          branchId: novel.activeBranchId,
          name: 'bad.png',
          bytes: Uint8List.fromList([1, 2, 3]),
        ),
        throwsFormatException,
      );
      expect(await repo.listAssets(novel.id), isEmpty);
      final asset = await assets.importImage(
        branchId: novel.activeBranchId,
        name: '地图',
        bytes: testPicture(),
      );
      final image = await assets.file(asset.id);
      await image.delete();
      final outside = File('${dir.path}/private.txt');
      await outside.writeAsString('private');
      await Link(image.path).create(outside.path);
      await expectLater(assets.read(asset.id), throwsFormatException);
    },
  );
  test('another novel cannot reference an asset and unknown URI embeds are rejected', () async {
    final asset = await assets.importImage(
      branchId: novel.activeBranchId,
      name: '甲的插画',
      bytes: testPicture(),
    );
    final other = await repo.createNovel(title: '乙');

    final s = await repo.createChapter(branchId: other.activeBranchId);
    await expectLater(
      repo.saveLoreEntry(
        branchId: other.activeBranchId,
        kind: LoreKind.map,
        name: '越界底图',
        content: '',
        data: {'backgroundAssetId': asset.id},
      ),
      throwsA(isA<StoryNotFound>()),
    );
    await expectLater(
      repo.insertIllustration(
        branchId: s.branchId,
        chapterId: s.id,
        expectedRevisionId: s.revisionId,
        assetId: asset.id,
        offset: 0,
      ),
      throwsA(isA<StoryNotFound>()),
    );
    await expectLater(
      repo.saveChapter(
        branchId: s.branchId,
        chapterId: s.id,
        expectedRevisionId: s.revisionId,
        content: ManuscriptContent.fromDelta([
          {
            'insert': {'image': 'file:///private.txt'},
          },
        ]),
      ),
      throwsFormatException,
    );
    expect(
      (await repo.getChapter(branchId: s.branchId, chapterId: s.id)).revisionId,
      s.revisionId,
    );
  });
}
