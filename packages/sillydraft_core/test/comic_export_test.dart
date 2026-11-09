import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'comic_store_test.dart' show comicFixture;
import 'native_comic_test.dart' show twoPageFixture;

ComicDocument checkedComic(ComicDocument doc) => ComicDocument.fromJson({
  ...doc.toJson(),
  'audit': {
    'fingerprint': doc.fingerprint,
    'reviews': [
      for (final scope in doc.reviewScopes.entries)
        {'id': scope.key, 'unitIds': scope.value, 'issues': <String>[]},
    ],
  },
});

void main() {
  late Directory dir;
  late StoryRepository repo;
  late AssetLibrary assets;
  late Novel novel;
  late Chapter chapter;
  late ComicExporter exporter;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('comic-export-');
    repo = StoryRepository.memory();
    assets = AssetLibrary(repository: repo, directory: dir);
    novel = await repo.createNovel(title: '门外 <夜>');
    chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '第一章',
      content: ManuscriptContent.plainText('小说原文秘密。门仍关着。'),
    );
    exporter = ComicExporter(repository: repo, assets: assets);
  });
  tearDown(() async {
    await repo.close();
    await dir.delete(recursive: true);
  });

  Future<void> save(ComicDocument doc) async {
    await repo.saveComic(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      document: doc,
      expectedRevisionId: (await repo.getComic(
        chapter.branchId,
        chapter.id,
      ))?.id,
    );
  }

  test(
    'page export keeps dialogue only in alt and transcript; rejects stale page',
    () async {
      final image = await assets.importImage(
        branchId: chapter.branchId,
        name: '页',
        bytes: testPicture(),
      );
      var doc = checkedComic(comicFixture(chapter).asPages());
      doc = ComicDocument.fromJson({
        ...doc.toJson(),
        'pages': [
          {
            ...doc.pages.first,
            'assetId': image.id,
            'fingerprint': doc.pageFingerprint(doc.pages.first),
          },
        ],
      });
      await save(doc);
      final file = await exporter.export(
        branchId: chapter.branchId,
        chapterIds: [chapter.id],
      );
      final zip = ZipDecoder().decodeBytes(file.bytes);
      final html = utf8.decode(zip.findFile('index.html')!.content);
      expect(html, isNot(contains('<figcaption>')));
      expect(html, contains(doc.pageTranscript(doc.pages.first)));
      final panels = doc.panels;
      panels.first['description'] = '新的画面';
      await save(checkedComic(doc.editPanels(panels)));
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: [chapter.id]),
        throwsFormatException,
      );
    },
  );

  test(
    'original export ignores stale pages and blocks missing images',
    () async {
      final image = await assets.importImage(
        branchId: chapter.branchId,
        name: '页',
        bytes: testPicture(),
      );
      final plan = twoPageFixture(chapter.id);
      final page = plan.pages.first;
      final panels = plan.panels;
      panels.first['description'] = '女孩回头';
      // Page 1 was drawn and flagged under the old rules, then edited.
      final doc = plan
          .edit({
            'pages': [
              {
                ...page,
                'assetId': image.id,
                'fingerprint': plan.pageFingerprint(page),
                'visualReview': true,
              },
              plan.pages.last,
            ],
          })
          .editPanels(panels);
      await save(doc);
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: [chapter.id]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('缺少 1 张图片'),
          ),
        ),
      );
      await save(doc.withoutPage('page2'));
      final head = (await repo.getComic(chapter.branchId, chapter.id))!;
      expect(head.document.stalePageIds, ['page1']);
      final file = await exporter.export(
        branchId: chapter.branchId,
        chapterIds: [chapter.id],
      );
      final zip = ZipDecoder().decodeBytes(file.bytes);
      expect(zip.findFile('assets/${image.hash}.png'), isNotNull);
    },
  );

  test(
    'offline comic preserves panel/text order, escapes HTML and omits source',
    () async {
      final image = await assets.importImage(
        branchId: chapter.branchId,
        name: '门',
        bytes: testPicture(),
      );
      final doc = comicFixture(chapter);
      final panels = doc.panels;
      final longText = '${'很长的中文台词' * 300}<script>alert(1)</script>';
      for (final (i, panel) in panels.indexed) {
        panel['assetId'] = image.id;
        panel['description'] = '画面 ${i + 1}';
        panel['texts'] = [
          {
            'kind': 'narration',
            'speaker': '',
            'text': i == 0 ? longText : '门没有打开。',
            'factId': panel['factIds'][0],
          },
        ];
      }
      await save(checkedComic(doc.edit({'panels': panels})));
      await repo.saveChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
        expectedRevisionId: chapter.revisionId,
        content: ManuscriptContent.plainText('新的原文'),
      );
      final file = await exporter.export(
        branchId: chapter.branchId,
        chapterIds: [chapter.id],
      );
      final zip = ZipDecoder().decodeBytes(file.bytes);
      final html = utf8.decode(zip.findFile('index.html')!.content);
      final text = utf8.decode(zip.findFile('text.txt')!.content);
      expect(file.mimeType, 'application/zip');
      expect(html, contains('门外 &lt;夜&gt;'));
      expect(html, contains('&lt;script&gt;alert(1)&lt;&#47;script&gt;'));
      expect(html, isNot(contains('<script>')));
      expect(html, isNot(contains('小说原文秘密')));
      expect(html, contains('依据历史正文版本'));
      expect(html.indexOf('画面 1'), lessThan(html.indexOf('画面 2')));
      expect(text, contains(longText));
      expect(zip.findFile('assets/${image.hash}.png'), isNotNull);
      expect(zip.files.length, 3);
    },
  );

  test(
    'rejects unchecked, missing images and noncontinuous selection explicitly',
    () async {
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: [chapter.id]),
        throwsFormatException,
      );
      final doc = comicFixture(chapter);
      await save(doc);
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: [chapter.id]),
        throwsFormatException,
      );
      await save(checkedComic(doc));
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: [chapter.id]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('缺少'),
          ),
        ),
      );
      final second = await repo.createChapter(branchId: chapter.branchId);
      final third = await repo.createChapter(branchId: chapter.branchId);
      await expectLater(
        exporter.export(
          branchId: chapter.branchId,
          chapterIds: [chapter.id, third.id],
        ),
        throwsFormatException,
      );
      await expectLater(
        exporter.export(
          branchId: chapter.branchId,
          chapterIds: [second.id, chapter.id],
        ),
        throwsFormatException,
      );
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: []),
        throwsFormatException,
      );
    },
  );

  test(
    'size guard refuses oversized assets before allocating archive',
    () async {
      final asset = await repo.storeAsset(
        branchId: chapter.branchId,
        name: '过大',
        prepared: PreparedAsset(
          hash: 'a' * 64,
          thumbnailHash: 'b' * 64,
          width: 1,
          height: 1,
          byteLength: 256 * 1024 * 1024 + 1,
        ),
      );
      final doc = comicFixture(chapter);
      final panels = doc.panels;
      for (final panel in panels) {
        panel['assetId'] = asset.id;
      }
      await save(checkedComic(doc.edit({'panels': panels})));
      await expectLater(
        exporter.export(branchId: chapter.branchId, chapterIds: [chapter.id]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('256 MB'),
          ),
        ),
      );
    },
  );

  test('foreign assets cannot enter an exportable comic', () async {
    final other = await repo.createNovel(title: '其他作品');
    final image = await assets.importImage(
      branchId: other.activeBranchId,
      name: '私有图',
      bytes: testPicture(),
    );
    final doc = comicFixture(chapter);
    final panels = doc.panels;
    for (final p in panels) {
      p['assetId'] = image.id;
    }
    await expectLater(
      save(checkedComic(doc.edit({'panels': panels}))),
      throwsFormatException,
    );
  });
}
