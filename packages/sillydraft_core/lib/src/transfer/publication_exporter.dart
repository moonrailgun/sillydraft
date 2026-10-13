import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../assets/asset_library.dart';
import '../model/asset.dart';
import '../model/manuscript.dart';
import '../storage/story_repository.dart';

enum PublicationFormat { text, markdown, epub }

final class PublicationFile {
  PublicationFile({
    required this.filename,
    required this.mimeType,
    required this.bytes,
  });
  final String filename, mimeType;
  final Uint8List bytes;
}

/// Exports only the immutable accepted chapter snapshot, never agent transcripts.
final class PublicationExporter {
  PublicationExporter({required this.repository, required this.assets});
  final StoryRepository repository;
  final AssetLibrary assets;
  static const maxBytes = 256 * 1024 * 1024;

  Future<PublicationFile> export({
    required String branchId,
    required PublicationFormat format,
  }) async {
    final story = await repository.getStory(branchId);
    final ids = <String>{
      if (format == PublicationFormat.epub && story.novel.coverAssetId != null)
        story.novel.coverAssetId!,
      for (final chapter in story.chapters)
        for (final op in chapter.content.delta)
          if (op['insert'] case {'image': final String uri}) uri.substring(6),
    };
    final images = <String, StoryAsset>{};
    final files = <String, Uint8List>{};
    var size = 0;
    for (final id in ids) {
      final asset = await repository.getAsset(id);
      if (asset.novelId != story.novel.id) {
        throw const FormatException('插图不属于此作品');
      }
      images[id] = asset;
      if (format != PublicationFormat.text &&
          !files.containsKey('assets/${asset.hash}.png')) {
        final bytes = await assets.read(id);
        size += bytes.length;
        if (size > maxBytes) throw const FormatException('导出文件超过 256 MB，请减少插图');
        files['assets/${asset.hash}.png'] = bytes;
      }
    }
    final title = story.novel.title;
    final filename = safePublicationName(title);
    if (format == PublicationFormat.text) {
      final buffer = StringBuffer('$title\n\n');
      for (final chapter in story.chapters) {
        if (chapter.title.isNotEmpty) buffer.writeln('${chapter.title}\n');
        for (final op in chapter.content.delta) {
          final insert = op['insert'];
          if (insert is String) {
            buffer.write(insert);
          } else if (insert case {'image': final String uri}) {
            buffer.write('[插图：${images[uri.substring(6)]!.name}]');
          }
        }
        buffer.writeln();
      }
      return PublicationFile(
        filename: '$filename.txt',
        mimeType: 'text/plain',
        bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
      );
    }
    if (format == PublicationFormat.markdown) {
      final buffer = StringBuffer('# ${_md(title)}\n\n');
      for (final chapter in story.chapters) {
        if (chapter.title.isNotEmpty) {
          buffer.writeln('## ${_md(chapter.title)}\n');
        }
        buffer.writeln(_render(chapter.content, images, html: false));
      }
      files['book.md'] = Uint8List.fromList(utf8.encode(buffer.toString()));
      return PublicationFile(
        filename: '$filename-markdown.zip',
        mimeType: 'application/zip',
        bytes: await _zip(files),
      );
    }
    final lang =
        RegExp(r'^[a-zA-Z]{2,8}(?:-[a-zA-Z0-9]{1,8})*$')
            .hasMatch(story.novel.language)
        ? story.novel.language
        : 'zh';
    final epub = <String, Uint8List>{};
    void add(String path, String text) =>
        epub[path] = Uint8List.fromList(utf8.encode(text));
    add('mimetype', 'application/epub+zip');
    add(
      'META-INF/container.xml',
      '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
    );
    add(
      'EPUB/style.css',
      'body { line-height: 1.75; } p { margin: 0 0 .8em; } img { max-width: 100%; height: auto; } blockquote { margin-inline: 1em; } pre { white-space: pre-wrap; } .underline { text-decoration: underline; } .strike { text-decoration: line-through; }',
    );
    final manifest = StringBuffer(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="css" href="style.css" media-type="text/css"/>',
    );
    final spine = StringBuffer(), nav = StringBuffer();
    final cover = images[story.novel.coverAssetId];
    if (cover != null) {
      add(
        'EPUB/cover.xhtml',
        _xhtml(
          title,
          lang,
          '<img src="assets/${cover.hash}.png" alt="${_xml(title)} 封面"/>',
        ),
      );
      manifest.write(
        '<item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="cover"/>');
    }
    for (final (i, chapter) in story.chapters.indexed) {
      final id = 'chapter-${i + 1}';
      final body =
          '<h1>${_xml(chapter.title)}</h1>'
          '${_render(chapter.content, images, html: true)}';
      add('EPUB/$id.xhtml', _xhtml(chapter.title, lang, body));
      manifest.write(
        '<item id="$id" href="$id.xhtml" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="$id"/>');
      nav.write('<li><a href="$id.xhtml">${_xml(chapter.title)}</a></li>');
    }
    if (story.chapters.isEmpty) {
      add(
        'EPUB/empty.xhtml',
        _xhtml(title, lang, '<h1>${_xml(title)}</h1><p>尚无正文。</p>'),
      );
      manifest.write(
        '<item id="empty" href="empty.xhtml" media-type="application/xhtml+xml"/>',
      );
      spine.write('<itemref idref="empty"/>');
      nav.write('<li><a href="empty.xhtml">${_xml(title)}</a></li>');
    }
    for (final entry in files.entries) {
      epub['EPUB/${entry.key}'] = entry.value;
      final hash = entry.key.substring(7, 71);
      manifest.write(
        '<item id="image-$hash" href="${entry.key}" media-type="image/png"${hash == cover?.hash ? ' properties="cover-image"' : ''}/>',
      );
    }
    add(
      'EPUB/nav.xhtml',
      _xhtml(
        '目录',
        lang,
        '<nav epub:type="toc" id="toc"><h1>目录</h1><ol>$nav</ol></nav>',
      ),
    );
    final modified =
        '${DateTime.now().toUtc().toIso8601String().split('.').first}Z';
    add(
      'EPUB/package.opf',
      '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="$lang"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:uuid:${story.branch.id}</dc:identifier><dc:title>${_xml(title)}</dc:title><dc:language>$lang</dc:language><meta property="dcterms:modified">$modified</meta></metadata><manifest>$manifest</manifest><spine>$spine</spine></package>''',
    );
    return PublicationFile(
      filename: '$filename.epub',
      mimeType: 'application/epub+zip',
      bytes: await _zip(epub),
    );
  }

  Future<Uint8List> _zip(Map<String, Uint8List> files) async {
    if (files.values.fold<int>(0, (n, b) => n + b.length) > maxBytes) {
      throw const FormatException('导出文件超过 256 MB');
    }
    return Isolate.run(() {
      final archive = Archive();
      for (final entry in files.entries) {
        final file = ArchiveFile.bytes(entry.key, entry.value);
        if (entry.key == 'mimetype') file.compression = CompressionType.none;
        archive.addFile(file);
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    });
  }
}

String safePublicationName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  return cleaned.isEmpty
      ? 'novel'
      : String.fromCharCodes(cleaned.runes.take(80));
}

String _xml(String text) =>
    const HtmlEscape(HtmlEscapeMode.element)
        .convert(text.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), ''))
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
String _md(String text) => text
    .replaceAllMapped(RegExp(r'[\\`*_{}\[\]()#+.!>|~-]'), (m) => '\\${m[0]}')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
String _xhtml(String title, String lang, String body) =>
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="$lang" xml:lang="$lang"><head><title>${_xml(title)}</title><link rel="stylesheet" type="text/css" href="style.css"/></head><body>$body</body></html>''';

String _render(
  ManuscriptContent content,
  Map<String, StoryAsset> images, {
  required bool html,
}) {
  final out = StringBuffer(), line = StringBuffer();
  String? openList;
  void closeList() {
    if (openList != null) out.write('</$openList>');
    openList = null;
  }

  void flush(Map attributes) {
    final text = line.toString();
    line.clear();
    if (html) {
      final header = attributes['header'];
      final tag = header is int && header >= 1 && header <= 6
          ? 'h$header'
          : attributes['blockquote'] == true
          ? 'blockquote'
          : attributes['code-block'] != null &&
                attributes['code-block'] != false
          ? 'pre'
          : 'p';
      final list = attributes['list'];
      if (list == 'bullet' ||
          list == 'ordered' ||
          list == 'checked' ||
          list == 'unchecked') {
        final wrapper = list == 'ordered' ? 'ol' : 'ul';
        if (openList != wrapper) {
          closeList();
          out.write('<$wrapper>');
          openList = wrapper;
        }
        out.write('<li>$text</li>');
      } else {
        closeList();
        out.write('<$tag>${text.isEmpty ? '<br/>' : text}</$tag>');
      }
    } else {
      final header = attributes['header'];
      final prefix = header is int && header >= 1 && header <= 6
          ? '${'#' * header} '
          : attributes['blockquote'] == true
          ? '> '
          : attributes['list'] == 'ordered'
          ? '1. '
          : attributes['list'] == 'checked'
          ? '- [x] '
          : attributes['list'] == 'unchecked'
          ? '- [ ] '
          : attributes['list'] == 'bullet'
          ? '- '
          : '';
      out.write('$prefix$text\n\n');
    }
  }

  for (final op in content.delta) {
    final attributes = op['attributes'] as Map? ?? const {};
    final insert = op['insert'];
    if (insert case {'image': final String uri}) {
      final image = images[uri.substring(6)]!;
      line.write(
        html
            ? '<img src="assets/${image.hash}.png" alt="${_xml(image.name)}"/>'
            : '![${_md(image.name)}](assets/${image.hash}.png)',
      );
    } else if (insert is String) {
      final pieces = insert.split('\n');
      for (final (i, piece) in pieces.indexed) {
        if (piece.isNotEmpty) {
          var text = html ? _xml(piece) : _md(piece);
          for (final entry in [
            ('bold', 'strong', '**'),
            ('italic', 'em', '*'),
            ('underline', 'span', ''),
            ('strike', 'del', '~~'),
          ]) {
            if (attributes[entry.$1] == true) {
              text = html
                  ? (entry.$1 == 'underline'
                        ? '<span class="underline">$text</span>'
                        : '<${entry.$2}>$text</${entry.$2}>')
                  : '${entry.$3}$text${entry.$3}';
            }
          }
          if (attributes['code'] == true) {
            text = html ? '<code>$text</code>' : '`$text`';
          }
          final link = attributes['link'];
          final url = link is String ? Uri.tryParse(link) : null;
          if (url != null && ['https', 'http', 'mailto'].contains(url.scheme)) {
            text = html
                ? '<a href="${_xml(url.toString())}">$text</a>'
                : '[$text](${url.toString().replaceAll('(', '%28').replaceAll(')', '%29')})';
          }
          line.write(text);
        }
        if (i < pieces.length - 1) flush(attributes);
      }
    }
  }
  if (line.isNotEmpty) flush(const {});
  closeList();
  return out.toString();
}
