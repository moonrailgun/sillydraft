import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../assets/asset_library.dart';
import '../model/comic.dart';
import '../storage/story_repository.dart';
import 'publication_exporter.dart';

/// A portable reader containing only the selected comic and its finished images.
final class ComicExporter {
  ComicExporter({required this.repository, required this.assets});
  final StoryRepository repository;
  final AssetLibrary assets;

  Future<PublicationFile> export({
    required String branchId,
    required List<String> chapterIds,
  }) async {
    final story = await repository.getStory(branchId);
    final start = story.chapters.indexWhere(
      (c) => c.id == chapterIds.firstOrNull,
    );
    if (chapterIds.isEmpty ||
        start < 0 ||
        start + chapterIds.length > story.chapters.length ||
        List.generate(
              chapterIds.length,
              (i) => story.chapters[start + i].id,
            ).join(',') !=
            chapterIds.join(',')) {
      throw const FormatException('请选择按阅读顺序排列的连续章节');
    }
    final chapters = story.chapters.sublist(start, start + chapterIds.length);
    final documents = <ComicDocument>[];
    final issues = <String>[];
    for (final chapter in chapters) {
      final doc = (await repository.getComic(branchId, chapter.id))?.document;
      if (doc == null || !doc.checked) {
        issues.add('${chapter.title}：尚未通过分镜检查');
      } else {
        final missing = doc.imageItems
            .where((p) => p['assetId'] == null)
            .length;
        if (doc.hasPages && !doc.complete && missing == 0) {
          issues.add('${chapter.title}：画面过期或待复核，请重画或确认');
        }
        if (missing > 0) issues.add('${chapter.title}：缺少 $missing 张图片');
        documents.add(doc);
      }
    }
    if (issues.isNotEmpty) throw FormatException(issues.join('\n'));
    final paths = <String, String>{};
    final files = <String, Uint8List>{};
    var size = 0;
    for (final id in {
      for (final doc in documents)
        for (final p in doc.imageItems) p['assetId'] as String,
    }) {
      final asset = await repository.getAsset(id);
      if (asset.novelId != story.novel.id) {
        throw const FormatException('漫画图片不属于此作品');
      }
      final path = 'assets/${asset.hash}.png';
      paths[id] = path;
      if (files.containsKey(path)) continue;
      if (size + asset.byteLength > PublicationExporter.maxBytes) {
        throw const FormatException('导出文件超过 256 MB，请减少章节');
      }
      final bytes = await assets.read(id);
      size += bytes.length;
      if (size > PublicationExporter.maxBytes) {
        throw const FormatException('导出文件超过 256 MB');
      }
      files[path] = bytes;
    }
    final html = StringBuffer(
      '''<!doctype html><html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self'; style-src 'unsafe-inline'">
<title>${_escape(story.novel.title)}</title><style>
body{max-width:800px;margin:auto;padding:16px;background:#faf9f6;color:#252321;font:18px/1.7 system-ui,sans-serif}
figure{margin:24px 0}img{display:block;width:100%;height:auto}figcaption{padding:16px;background:white}
p{margin:0 0 8px;white-space:pre-wrap;overflow-wrap:anywhere}h1,h2{overflow-wrap:anywhere}.notice{font-size:14px}
</style></head><body><h1>${_escape(story.novel.title)}</h1>''',
    );
    final text = StringBuffer('${story.novel.title}\n\n');
    for (var i = 0; i < documents.length; i++) {
      final doc = documents[i];
      html.write('<section><h2>${_escape(chapters[i].title)}</h2>');
      text.writeln('${chapters[i].title}\n');
      if (!await repository.comicSourcesCurrent(branchId, doc)) {
        final notice = doc.isOriginal
            ? '依据历史漫画版本；此前漫画或顺序已有修改。'
            : '依据历史正文版本；原文此后已有修改。';
        html.write('<p class="notice">$notice</p>');
        text.writeln(notice);
      }
      for (final (index, p) in doc.imageItems.indexed) {
        if (doc.hasPages) {
          final transcript = doc.pageTranscript(p);
          html.write(
            '<figure><img src="${paths[p['assetId']]}" alt="${_escape(transcript)}"></figure>',
          );
          text.writeln('第 ${index + 1} 页\n$transcript\n');
          continue;
        }
        html.write(
          '<figure><img src="${paths[p['assetId']]}" alt="${_escape(p['description'] as String)}"><figcaption>',
        );
        text.writeln('第 ${index + 1} 格：${p['description']}');
        for (final t in p['texts'] as List) {
          final speaker = t['speaker'] as String;
          final label = switch (t['kind']) {
            'thought' => '心声',
            'narration' => '旁白',
            'sound' => '音效',
            _ => '',
          };
          final prefix = [
            speaker,
            label,
          ].where((s) => s.isNotEmpty).join(' · ');
          final line = '${prefix.isEmpty ? '' : '$prefix：'}${t['text']}';
          html.write('<p>${_escape(line)}</p>');
          text.writeln(line);
        }
        html.write('</figcaption></figure>');
        text.writeln();
      }
      html.write('</section>');
    }
    html.write('</body></html>');
    files['index.html'] = Uint8List.fromList(utf8.encode(html.toString()));
    files['text.txt'] = Uint8List.fromList(utf8.encode(text.toString()));
    if (files.values.fold<int>(0, (n, bytes) => n + bytes.length) >
        PublicationExporter.maxBytes) {
      throw const FormatException('导出文件超过 256 MB');
    }
    return PublicationFile(
      filename: '${safePublicationName(story.novel.title)}-comic.zip',
      mimeType: 'application/zip',
      bytes: await Isolate.run(() {
        final archive = Archive();
        for (final entry in files.entries) {
          archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
        }
        return Uint8List.fromList(ZipEncoder().encode(archive));
      }),
    );
  }
}

String _escape(String value) => const HtmlEscape().convert(value);
