import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:charset/charset.dart' show gbk;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('TXT', () {
    const book = '''《雾港来信》
作者：某人
内容简介：一封信改变了港口。

第一卷 起雾
第一章 码头
雾从港口升起。
她站在栈桥上。

第二章 灯塔
灯塔熄灭了。

番外 旧事
很多年前。
''';

    test('splits on chapter headings and keeps the blurb as synopsis', () {
      final result = ManuscriptImporter.parse(
        _utf8(book),
        filename: '雾港来信.txt',
      );
      expect(result.title, '雾港来信');
      expect(result.synopsis, contains('一封信改变了港口'));
      expect(result.chapters.map((c) => c.title), [
        '第一卷 起雾 · 第一章 码头',
        '第二章 灯塔',
        '番外 旧事',
      ]);
      expect(result.chapters.first.scenes.single.text, '雾从港口升起。\n她站在栈桥上。');
      expect(result.warnings, isEmpty);
    });

    test('reads GBK and UTF-8 with BOM', () {
      final gbkBytes = Uint8List.fromList(gbk.encode(book));
      expect(
        ManuscriptImporter.parse(gbkBytes, filename: 'a.txt').chapters,
        hasLength(3),
      );
      final bom = Uint8List.fromList([0xef, 0xbb, 0xbf, ..._utf8(book)]);
      expect(ManuscriptImporter.parse(bom, filename: 'a.txt').title, '雾港来信');
    });

    test('a sentence that starts like a heading is not one', () {
      final result = ManuscriptImporter.parse(
        _utf8('第一章 开始\n第一次见到她时，雨下得很大，整条街都没有人，只有远处的钟声。\n'),
        filename: 'a.txt',
      );
      expect(result.chapters.single.scenes.single.text, startsWith('第一次见到她'));
    });

    test('without headings, long text is cut into editable parts', () {
      final paragraph = '${'雾' * 999}\n';
      final result = ManuscriptImporter.parse(
        _utf8(paragraph * 50),
        filename: 'plain.txt',
      );
      expect(result.chapters.length, greaterThan(1));
      for (final c in result.chapters) {
        expect(
          c.scenes.single.text.length,
          lessThanOrEqualTo(ManuscriptImporter.sceneLimit),
        );
      }
      expect(result.characters, 999 * 50);
      expect(result.warnings, isNotEmpty);
    });

    test('rejects empty files and unknown formats', () {
      expect(
        () => ManuscriptImporter.parse(_utf8('  \n'), filename: 'a.txt'),
        throwsFormatException,
      );
      expect(
        () => ManuscriptImporter.parse(_utf8('x'), filename: 'a.docx'),
        throwsFormatException,
      );
    });
  });

  test('Markdown uses headings as chapters and drops markup', () {
    final result = ManuscriptImporter.parse(
      _utf8('''# 雾港来信

## 码头

雾从**港口**升起。![图](a.png)

## 灯塔

> 灯塔熄灭了。
'''),
      filename: 'x.md',
    );
    expect(result.title, '雾港来信');
    expect(result.chapters.map((c) => c.title), ['码头', '灯塔']);
    expect(result.chapters.first.scenes.single.text, '雾从港口升起。');
    expect(result.chapters.last.scenes.single.text, '灯塔熄灭了。');
    expect(result.warnings.single, contains('1 张图片'));
  });

  test('EPUB follows the spine and skips the navigation page', () {
    final archive = Archive()
      ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
      ..addFile(
        ArchiveFile.string(
          'META-INF/container.xml',
          '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
        ),
      )
      ..addFile(
        ArchiveFile.string('OEBPS/content.opf', '''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>雾港来信</dc:title><dc:description>&lt;p&gt;港口的故事&lt;/p&gt;</dc:description></metadata>
<manifest>
<item id="nav" href="nav.xhtml" properties="nav"/>
<item id="c1" href="text/c1.xhtml"/>
<item id="c2" href="text/c2.xhtml"/>
</manifest>
<spine><itemref idref="nav"/><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>'''),
      )
      ..addFile(
        ArchiveFile.string(
          'OEBPS/nav.xhtml',
          '<html><body><h1>目录</h1><p>码头</p></body></html>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'OEBPS/text/c1.xhtml',
          '<html><body><h2>码头</h2><p>雾从港口升起。</p><p>她&nbsp;来了&hellip;</p></body></html>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'OEBPS/text/c2.xhtml',
          '<html><body><p>灯塔熄灭了。</p></body></html>',
        ),
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final result = ManuscriptImporter.parse(bytes, filename: 'book.epub');
    expect(result.title, '雾港来信');
    expect(result.synopsis, '港口的故事');
    expect(result.chapters.map((c) => c.title), ['码头', '第2章']);
    expect(result.chapters.first.scenes.single.text, '雾从港口升起。\n她 来了…');
  });

  test('a whole book becomes one work in one change', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final book = ManuscriptImporter.parse(
      _utf8('第一章 码头\n雾从港口升起。\n第二章 灯塔\n灯塔熄灭了。\n'),
      filename: '雾港来信.txt',
    );
    final novel = await repo.createNovelFromManuscript(book);
    final story = await repo.getStory(novel.activeBranchId);
    expect(novel.title, '雾港来信');
    expect(story.chapters.map((c) => c.title), ['第一章 码头', '第二章 灯塔']);
    expect(story.scenes.map((s) => s.content.text.trim()), [
      '雾从港口升起。',
      '灯塔熄灭了。',
    ]);
    // Imported text is history like any other: the editor can restore it.
    final history = await repo.listRevisions(
      branchId: novel.activeBranchId,
      sceneId: story.scenes.first.id,
    );
    expect(history.single.reason, 'import');
  });
}
