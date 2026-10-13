import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk;
import 'package:xml/xml.dart';

import 'safe_archive.dart';

/// One scene of an imported book.
final class ImportedScene {
  const ImportedScene({required this.title, required this.text});
  final String title, text;
}

final class ImportedChapter {
  const ImportedChapter({required this.title, required this.scenes});
  final String title;
  final List<ImportedScene> scenes;
}

/// A finished or half-finished novel read from a file, ready to become a new
/// work the author continues.
final class ImportedManuscript {
  const ImportedManuscript({
    required this.title,
    required this.chapters,
    this.synopsis = '',
    this.warnings = const [],
  });
  final String title, synopsis;
  final List<ImportedChapter> chapters;
  final List<String> warnings;

  int get characters => chapters.fold(
    0,
    (sum, c) =>
        sum +
        c.scenes.fold(
          0,
          (s, scene) => s + scene.text.replaceAll(_space, '').length,
        ),
  );
  int get sceneCount => chapters.fold(0, (sum, c) => sum + c.scenes.length);
}

final _space = RegExp(r'\s');

/// Reads TXT, Markdown and EPUB books. Chapter headings are recognised the
/// way Chinese web novels and published books write them; a book without any
/// is cut into parts so no single scene becomes too large to edit.
abstract final class ManuscriptImporter {
  static const maxBytes = 64 * 1024 * 1024;
  static const extensions = ['txt', 'md', 'markdown', 'epub'];

  /// Scenes longer than this are split at paragraph boundaries.
  static const sceneLimit = 20000;

  static bool supports(String filename) =>
      extensions.contains(_extension(filename));

  static ImportedManuscript parse(Uint8List bytes, {required String filename}) {
    if (bytes.length > maxBytes) throw const FormatException('小说文件不能超过 64 MB');
    final result = switch (_extension(filename)) {
      'txt' => _plain(decodeText(bytes), _stem(filename), _txtHeading),
      'md' || 'markdown' => _markdown(decodeText(bytes), _stem(filename)),
      'epub' => _epub(bytes, _stem(filename)),
      _ => throw const FormatException('支持 TXT、Markdown 和 EPUB 小说'),
    };
    if (result.characters == 0) throw const FormatException('文件里没有可导入的正文');
    return result;
  }

  /// UTF-8 (with or without BOM) and UTF-16 with BOM; anything that is not
  /// valid UTF-8 is read as GBK/GB18030, the usual encoding of older Chinese
  /// TXT books.
  static String decodeText(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      final little = bytes[0] == 0xff;
      final units = <int>[
        for (var i = 2; i + 1 < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ];
      return String.fromCharCodes(units);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      final text = gbk.decode(bytes, allowMalformed: true);
      if ('�'.allMatches(text).length > text.length / 50) {
        throw const FormatException('无法识别文件编码，请另存为 UTF-8 后再导入');
      }
      return text;
    }
  }

  static final _txtHeading = RegExp(
    r'^(?:正文\s*)?(?:第\s*[0-9０-９零〇一二两三四五六七八九十百千万]+\s*[章回节卷集部篇幕](?=$|[\s:：、.．·]).*'
    r'|(?:序章|序言|序幕|楔子|引子|前言|尾声|后记|终章|番外)(?=$|[\s:：、.．·\d一二三四五六七八九十]).*'
    r'|(?:chapter|CHAPTER|Chapter)\s+[0-9IVXLCivxlc]+\b.*)$',
  );
  static final _volume = RegExp(
    r'^(?:正文\s*)?第\s*[0-9０-９零〇一二两三四五六七八九十百千万]+\s*[卷部集篇]',
  );

  static ImportedManuscript _plain(
    String text,
    String fallbackTitle,
    RegExp heading,
  ) {
    final lines = const LineSplitter().convert(text);
    final sections = <({String title, List<String> lines})>[];
    final front = <String>[];
    String? volume;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isNotEmpty && line.length <= 40 && heading.hasMatch(line)) {
        if (_volume.hasMatch(line)) {
          // A volume heading opens the chapters below it; it carries no text.
          volume = line;
          continue;
        }
        sections.add((
          title: volume == null ? line : '$volume · $line',
          lines: [],
        ));
        volume = null;
        continue;
      }
      (sections.isEmpty ? front : sections.last.lines).add(raw);
    }
    final warnings = <String>[];
    var title = fallbackTitle;
    var synopsis = '';
    final chapters = <ImportedChapter>[];
    final frontText = _clean(front.join('\n'));
    if (sections.isEmpty) {
      warnings.add('没有识别到章节标题，已按长度分成若干部分');
      final parts = _split(frontText);
      for (final (i, part) in parts.indexed) {
        chapters.add(
          ImportedChapter(
            title: parts.length == 1 ? '正文' : '第${i + 1}部分',
            scenes: [ImportedScene(title: '正文', text: part)],
          ),
        );
      }
    } else {
      // Web-novel files open with the book name, author and blurb.
      final named = RegExp(r'^\s*《(.+?)》').firstMatch(frontText);
      if (named != null) title = named.group(1)!.trim();
      if (frontText.isNotEmpty && frontText.length <= 1500) {
        synopsis = frontText;
      } else if (frontText.isNotEmpty) {
        chapters.add(_chapter('开篇', frontText));
      }
      for (final s in sections) {
        final body = _clean(s.lines.join('\n'));
        if (body.isEmpty) continue;
        chapters.add(_chapter(s.title, body));
      }
      if (chapters.isEmpty) {
        throw const FormatException('章节标题下都没有正文');
      }
    }
    return ImportedManuscript(
      title: title,
      synopsis: synopsis,
      chapters: chapters,
      warnings: warnings,
    );
  }

  static ImportedChapter _chapter(String title, String body) {
    final parts = _split(body);
    return ImportedChapter(
      title: title,
      scenes: [
        for (final (i, part) in parts.indexed)
          ImportedScene(
            title: parts.length == 1 ? title : '$title（${i + 1}）',
            text: part,
          ),
      ],
    );
  }

  static ImportedManuscript _markdown(String text, String fallbackTitle) {
    final lines = const LineSplitter().convert(text);
    final h1 = lines.where((l) => l.startsWith('# ')).toList();
    final h2 = lines.where((l) => l.startsWith('## ')).isNotEmpty;
    // A single top heading over second-level ones is the book title.
    final bookTitle = h1.length == 1 && h2
        ? h1.single.substring(2).trim()
        : null;
    final heading = bookTitle == null
        ? RegExp(r'^#{1,3}\s+(.+)$')
        : RegExp(r'^#{2,3}\s+(.+)$');
    final body = <String>[];
    var images = 0;
    for (final line in lines) {
      if (bookTitle != null && line.startsWith('# ')) continue;
      final match = heading.firstMatch(line);
      if (match != null) {
        // Reuse the plain-text splitter with a marker it always recognises.
        body.add('\u0000${match.group(1)!.trim()}');
        continue;
      }
      final stripped = line.replaceAllMapped(RegExp(r'!\[[^\]]*\]\([^)]*\)'), (
        _,
      ) {
        images++;
        return '';
      });
      body.add(
        stripped
            .replaceAll(RegExp(r'^>\s?'), '')
            .replaceAllMapped(
              RegExp(r'(\*\*|__|\*)(\S(?:.*?\S)?)\1'),
              (m) => m.group(2)!,
            )
            .replaceAllMapped(
              RegExp(r'\[([^\]]*)\]\([^)]*\)'),
              (m) => m.group(1)!,
            ),
      );
    }
    final result = _plain(
      body.join('\n'),
      bookTitle ?? fallbackTitle,
      RegExp('^\u0000(.+)\$'),
    );
    return ImportedManuscript(
      title: bookTitle ?? result.title,
      synopsis: result.synopsis,
      chapters: [
        for (final c in result.chapters)
          ImportedChapter(
            title: c.title.replaceAll('\u0000', ''),
            scenes: [
              for (final s in c.scenes)
                ImportedScene(
                  title: s.title.replaceAll('\u0000', ''),
                  text: s.text,
                ),
            ],
          ),
      ],
      warnings: [
        ...result.warnings,
        if (images > 0) '$images 张图片引用未导入，可在插图中另行添加',
      ],
    );
  }

  static ImportedManuscript _epub(Uint8List bytes, String fallbackTitle) {
    final files = readSafeZip(bytes);
    String read(String path) {
      final data = files[path];
      if (data == null) throw FormatException('EPUB 缺少 $path');
      return utf8.decode(data, allowMalformed: true);
    }

    try {
      final container = XmlDocument.parse(read('META-INF/container.xml'));
      final opfPath = container
          .findAllElements('rootfile')
          .first
          .getAttribute('full-path')!;
      final base = opfPath.contains('/')
          ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
          : '';
      final opf = XmlDocument.parse(read(opfPath));
      final title =
          opf
              .findAllElements('title', namespaceUri: '*')
              .firstOrNull
              ?.innerText
              .trim() ??
          fallbackTitle;
      final description =
          opf
              .findAllElements('description', namespaceUri: '*')
              .firstOrNull
              ?.innerText ??
          '';
      final manifest = {
        for (final item in opf.findAllElements('item', namespaceUri: '*'))
          item.getAttribute('id'): item,
      };
      final chapters = <ImportedChapter>[];
      for (final ref in opf.findAllElements('itemref', namespaceUri: '*')) {
        final item = manifest[ref.getAttribute('idref')];
        final href = item?.getAttribute('href');
        if (item == null ||
            href == null ||
            item.getAttribute('properties')?.contains('nav') == true) {
          continue;
        }
        final path = Uri.decodeFull('$base$href');
        if (!files.containsKey(path)) continue;
        final (heading, text) = _xhtml(read(path));
        if (text.replaceAll(_space, '').isEmpty) continue;
        chapters.add(
          _chapter(
            heading.isEmpty ? '第${chapters.length + 1}章' : heading,
            text,
          ),
        );
      }
      if (chapters.isEmpty) throw const FormatException('EPUB 中没有找到正文');
      return ImportedManuscript(
        title: title.isEmpty ? fallbackTitle : title,
        synopsis: _clean(_stripTags(description)),
        chapters: chapters,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('无法读取这个 EPUB 文件');
    }
  }

  /// The first heading and the readable text of one XHTML document.
  static (String, String) _xhtml(String source) {
    final body =
        RegExp(
          r'<body[^>]*>([\s\S]*)</body>',
          caseSensitive: false,
        ).firstMatch(source)?.group(1) ??
        source;
    final headingMatch = RegExp(
      r'<h[1-3][^>]*>([\s\S]*?)</h[1-3]>',
      caseSensitive: false,
    ).firstMatch(body);
    final heading = headingMatch == null
        ? ''
        : _clean(_stripTags(headingMatch.group(1)!)).replaceAll('\n', ' ');
    final withoutHeading = headingMatch == null
        ? body
        : body.replaceFirst(headingMatch.group(0)!, '');
    return (heading, _clean(_stripTags(withoutHeading)));
  }

  static String _stripTags(String html) => html
      .replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(
          r'<br\s*/?>|</(p|div|h[1-6]|li|blockquote)>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-z]+);'), (m) {
        final e = m.group(1)!;
        if (e.startsWith('#x')) {
          return String.fromCharCode(int.parse(e.substring(2), radix: 16));
        }
        if (e.startsWith('#')) {
          return String.fromCharCode(int.parse(e.substring(1)));
        }
        return const {
              'amp': '&',
              'lt': '<',
              'gt': '>',
              'quot': '"',
              'apos': "'",
              'nbsp': ' ',
              'hellip': '…',
              'mdash': '—',
              'ldquo': '“',
              'rdquo': '”',
              'lsquo': '‘',
              'rsquo': '’',
            }[e] ??
            m.group(0)!;
      });

  /// Trims each line and collapses runs of blank lines.
  static String _clean(String text) => text
      .split('\n')
      .map((l) => l.trimRight().replaceFirst(RegExp(r'^[ \t]+'), ''))
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  /// Cuts text longer than [sceneLimit] at paragraph boundaries.
  static List<String> _split(String text) {
    if (text.length <= sceneLimit) return [text];
    final parts = <String>[];
    final buffer = StringBuffer();
    for (final paragraph in text.split('\n')) {
      if (buffer.length > 0 && buffer.length + paragraph.length > sceneLimit) {
        parts.add(buffer.toString().trim());
        buffer.clear();
      }
      buffer.writeln(paragraph);
    }
    if (buffer.toString().trim().isNotEmpty) {
      parts.add(buffer.toString().trim());
    }
    return parts;
  }

  static String _extension(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  }

  static String _stem(String filename) {
    final name = filename.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final stem = (dot <= 0 ? name : name.substring(0, dot))
        .replaceAll(RegExp(r'[《》]'), '')
        .trim();
    return stem.isEmpty ? '导入的小说' : stem;
  }
}
