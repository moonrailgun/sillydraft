import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

void main() {
  test('publication exports selected accepted branch with portable images, formatting and XML escaping', () async {
    final dir = await Directory.systemTemp.createTemp('sillydraft-export-');
    final repo = StoryRepository.open('${dir.path}/library.sqlite');
    addTearDown(() async {
      await repo.close();
      await dir.delete(recursive: true);
    });
    final assets = AssetLibrary(
      repository: repo,
      directory: Directory('${dir.path}/assets'),
    );
    final novel = await repo.createNovel(title: '海 <雾> & 灯');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '第一章 & 开端',
    );
    var scene = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      title: '港口',
      content: ManuscriptContent.fromDelta([
        {
          'insert': '灯亮了。',
          'attributes': {'bold': true},
        },
        {'insert': '\n'},
        {'insert': '<script>并非脚本</script>'},
        {
          'insert': '\n',
          'attributes': {'blockquote': true},
        },
        {'insert': '第一项'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
        {'insert': '第二项'},
        {
          'insert': '\n',
          'attributes': {'list': 'ordered'},
        },
      ]),
    );
    final image = await assets.importImage(
      branchId: scene.branchId,
      name: '灯塔 & 海',
      bytes: testPicture(),
    );
    scene = await repo.insertIllustration(
      branchId: scene.branchId,
      sceneId: scene.id,
      expectedRevisionId: scene.revisionId,
      assetId: image.id,
      offset: 0,
    );
    await repo.setCover(novel.id, image.id);
    final other = await repo.forkBranch(
      branchId: scene.branchId,
      atSceneId: scene.id,
      name: '另一条路',
    );
    final otherScene = (await repo.getStory(other.id)).scenes.single;
    await repo.saveScene(
      branchId: other.id,
      sceneId: otherScene.id,
      expectedRevisionId: otherScene.revisionId,
      content: ManuscriptContent.plainText('其他分支秘密'),
    );
    await repo.createProposal(
      branchId: scene.branchId,
      sceneId: scene.id,
      baseRevisionId: scene.revisionId,
      content: ManuscriptContent.plainText('未采纳秘密'),
    );
    final conversation = await repo.createConversation(
      branchId: scene.branchId,
      title: '编辑器',
    );
    await repo.appendAgentMessage(
      conversation,
      role: 'user',
      content: '编辑对话秘密',
    );
    final exporter = PublicationExporter(repository: repo, assets: assets);
    final txt = await exporter.export(
      branchId: scene.branchId,
      format: PublicationFormat.text,
    );
    final plain = utf8.decode(txt.bytes);
    expect(plain, contains('灯亮了。'));
    expect(plain, contains('[插图：灯塔 & 海]'));
    for (final secret in ['其他分支秘密', '未采纳秘密', '编辑对话秘密']) {
      expect(plain, isNot(contains(secret)));
    }
    final md = await exporter.export(
      branchId: scene.branchId,
      format: PublicationFormat.markdown,
    );
    final markdown = ZipDecoder().decodeBytes(md.bytes);
    expect(
      utf8.decode(markdown.findFile('book.md')!.content),
      contains('**灯亮了。**'),
    );
    expect(markdown.findFile('assets/${image.hash}.png'), isNotNull);
    final epub = await exporter.export(
      branchId: scene.branchId,
      format: PublicationFormat.epub,
    );
    final onDisk = File('${dir.path}/book.epub');
    await onDisk.writeAsBytes(epub.bytes);
    final archive = ZipDecoder().decodeBytes(await onDisk.readAsBytes());
    expect(archive.files.first.name, 'mimetype');
    expect(epub.bytes[8], 0); // First ZIP entry must be stored, not compressed.
    expect(utf8.decode(archive.files.first.content), 'application/epub+zip');
    final package = utf8.decode(archive.findFile('EPUB/package.opf')!.content);
    expect(package, contains('海 &lt;雾&gt; &amp; 灯'));
    expect(package, contains('properties="cover-image"'));
    expect(archive.findFile('META-INF/container.xml'), isNotNull);
    expect(archive.findFile('EPUB/nav.xhtml'), isNotNull);
    final chapterText = utf8.decode(
      archive.findFile('EPUB/chapter-1.xhtml')!.content,
    );
    expect(chapterText, contains('<strong>灯亮了。</strong>'));
    expect(chapterText, contains('<ol><li>第一项</li><li>第二项</li></ol>'));
    expect(chapterText, contains('&lt;script&gt;并非脚本&lt;/script&gt;'));
    expect(chapterText, isNot(contains('<script>')));
    expect(archive.findFile('EPUB/assets/${image.hash}.png'), isNotNull);
  });
}
