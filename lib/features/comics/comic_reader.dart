import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../illustrations/asset_image.dart';

/// A chapter with its comic, as [comicProvider] reads it.
typedef ComicChapter = ({
  Chapter chapter,
  ComicRevision? comic,
  bool sourceCurrent,
  bool original,
});

/// Whether a chapter's comic is made on the canvas: an original, or a comic
/// work's chapter with neither comic nor prose. The rest are adapted from
/// their prose in the adaptation panel.
bool comicOnCanvas(ComicChapter data) =>
    data.comic?.document.isOriginal ??
    data.original && data.chapter.content.text.trim().isEmpty;

final comicProvider = FutureProvider.family<ComicChapter, (String, String)>((
  ref,
  key,
) async {
  ref.watch(repositoryContentChangesProvider);
  final repo = ref.watch(repositoryProvider);
  final chapter = await repo.getChapter(branchId: key.$1, chapterId: key.$2);
  final comic = await repo.getComic(key.$1, key.$2);
  return (
    original:
        comic?.document.isOriginal ??
        (await repo.getStory(key.$1)).novel.workFormat == WorkFormat.comic,
    chapter: chapter,
    comic: comic,
    sourceCurrent:
        comic == null || await repo.comicSourcesCurrent(key.$1, comic.document),
  );
});

/// A chapter's saved comic, if any, without [comicProvider]'s source checks:
/// cheap enough to watch for every chapter of an outline.
final comicHeadProvider =
    FutureProvider.family<ComicRevision?, (String, String)>((ref, key) {
      ref.watch(repositoryContentChangesProvider);
      return ref.watch(repositoryProvider).getComic(key.$1, key.$2);
    });

/// The same ordered, unabridged content is used in previews and the reader.
class ComicPanelView extends StatelessWidget {
  const ComicPanelView({
    super.key,
    required this.panel,
    required this.number,
    this.details = false,
    this.storyboardOnly = false,
  });
  final Map<String, dynamic> panel;
  final int number;
  final bool details;
  final bool storyboardOnly;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('第 $number 格', style: context.theme.typography.body.sm),
      const SizedBox(height: 12),
      if (storyboardOnly)
        Text('画面：${panel['description']}')
      else if (panel['assetId'] case final String id)
        AssetImageView(assetId: id, label: panel['description'] as String)
      else
        Container(
          padding: const EdgeInsets.all(24),
          color: context.theme.colors.secondary,
          child: Text('尚未生成画面\n${panel['description']}'),
        ),
      if (panel['visualReview'] == true) ...[
        const SizedBox(height: 12),
        const Text('衔接待复核：请检查人物、物品和前后画面。'),
      ],
      for (final text in panel['texts'] as List) ...[
        const SizedBox(height: 12),
        Text(
          [
            const {
              'dialogue': '对白',
              'thought': '心理',
              'narration': '旁白',
              'sound': '拟声',
            }[text['kind']]!,
            if ((text['speaker'] as String).isNotEmpty)
              text['speaker'] as String,
          ].join(' · '),
          style: context.theme.typography.body.sm,
        ),
        const SizedBox(height: 4),
        Text(text['text'] as String, style: const TextStyle(height: 1.7)),
      ],
      if (details) ...[
        const SizedBox(height: 16),
        if (!storyboardOnly) Text('画面：${panel['description']}'),
        if ((panel['continuity'] as String).isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('衔接：${panel['continuity']}'),
        ],
      ],
    ],
  );
}

class ComicPageView extends StatelessWidget {
  const ComicPageView({
    super.key,
    required this.document,
    required this.page,
    required this.number,
  });
  final ComicDocument document;
  final Map<String, dynamic> page;
  final int number;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('第 $number 页', style: context.theme.typography.body.sm),
      const SizedBox(height: 12),
      if (page['assetId'] case final String id)
        AssetImageView(assetId: id, label: document.pageTranscript(page))
      else
        Padding(
          padding: const EdgeInsets.all(24),
          // Originals have no 生成漫画 button: pages are redrawn on the canvas.
          child: Text(
            document.isOriginal ? '这一页还没画好，可以在漫画画布里重试。' : '尚未绘制，请生成漫画页。',
          ),
        ),
      if (page['assetId'] != null &&
          page['fingerprint'] != document.pageFingerprint(page))
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('分镜已修改，请重画此页。'),
        )
      // Originals ignore legacy continuity flags.
      else if (page['visualReview'] == true && !document.isOriginal)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('画面衔接待复核。'),
        ),
    ],
  );
}

class ComicReader extends ConsumerWidget {
  const ComicReader({
    super.key,
    required this.branchId,
    required this.chapterId,
  });
  final String branchId, chapterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '漫画阅读',
    body: AsyncView(
      value: ref.watch(comicProvider((branchId, chapterId))),
      builder: (data) {
        final doc = data.comic?.document;
        final chapters =
            ref.watch(storyProvider(branchId)).value?.chapters ?? <Chapter>[];
        final index = chapters.indexWhere((c) => c.id == chapterId);
        void open(Chapter chapter) => Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                ComicReader(branchId: branchId, chapterId: chapter.id),
          ),
        );
        return ContentLayout(
          maxWidth: 760,
          builder: (_, inset) => SingleChildScrollView(
            padding: inset + const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  data.chapter.title,
                  style: context.theme.typography.body.xl,
                ),
                const SizedBox(height: 16),
                // Originals have no source to go stale and no check gate.
                if (doc?.isOriginal != true) ...[
                  if (!data.sourceCurrent) const Text('依据已过期：这里保留的是先前版本的漫画。'),
                  if (doc != null && !doc.checked)
                    const Text('分镜尚未通过检查，以下是创作预览。'),
                ],
                if (doc == null || doc.panels.isEmpty)
                  const Text('本章还没有分镜，请在漫画工作区开始创作。'),
                for (final (i, panel)
                    in (doc?.imageItems ?? <Map<String, dynamic>>[]).indexed)
                  Padding(
                    padding: const EdgeInsets.only(top: 24, bottom: 16),
                    child: doc!.hasPages
                        ? ComicPageView(
                            document: doc,
                            page: panel,
                            number: i + 1,
                          )
                        : ComicPanelView(panel: panel, number: i + 1),
                  ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    if (index > 0)
                      FButton(
                        onPress: () => open(chapters[index - 1]),
                        child: const Text('上一章'),
                      ),
                    if (index >= 0 && index + 1 < chapters.length)
                      FButton(
                        onPress: () => open(chapters[index + 1]),
                        child: const Text('下一章'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
