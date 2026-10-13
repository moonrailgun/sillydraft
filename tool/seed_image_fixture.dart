// Local QA only. Creates a clearly labelled novel; does not replace existing work.
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tool/seed_image_fixture.dart DATABASE ASSET_DIRECTORY PNG_FIXTURE',
    );
    exitCode = 64;
    return;
  }
  final repo = StoryRepository.open(args[0]);
  try {
    final novel = await repo.createNovel(
      title: '插画验证（本地测试）',
      synopsis: '用于验证本地图片显示的测试作品，图片为纯色测试数据。',
    );

    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '带插图的章节',
      content: ManuscriptContent.plainText(
        '这是本地图片显示测试。下面的色块用于验证编辑器和阅读器中的插图。\n',
      ),
    );
    final assets = AssetLibrary(
      repository: repo,
      directory: Directory(args[1]),
    );
    final asset = await assets.importImage(
      branchId: novel.activeBranchId,
      name: '本地测试图 · 非模型生成',
      bytes: await File(args[2]).readAsBytes(),
      sourceChapterId: chapter.id,
      sourceRevisionId: chapter.revisionId,
      metadata: {'origin': 'local_test_fixture'},
    );
    await repo.insertIllustration(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      assetId: asset.id,
      offset: chapter.content.text.length - 1,
    );
    await repo.setCover(novel.id, asset.id);
    await repo.saveLoreEntry(
      branchId: chapter.branchId,
      kind: LoreKind.map,
      name: '测试地图',
      content: '验证底图、地点和路线',
      data: {
        'backgroundAssetId': asset.id,
        'backgroundAspect': asset.width / asset.height,
        'points': [
          {'id': 'port', 'x': .2, 'y': .3, 'label': '港口'},
          {'id': 'tower', 'x': .8, 'y': .7, 'label': '灯塔'},
        ],
        'routes': [
          {
            'id': 'trail',
            'name': '海岸小径',
            'pointIds': ['port', 'tower'],
          },
        ],
      },
    );
    stdout.writeln('Created local QA novel: ${novel.id}');
  } finally {
    await repo.close();
  }
}
