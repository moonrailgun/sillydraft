import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../illustrations/asset_image.dart';
import '../illustrations/illustration_gallery.dart';
import '../transfer/file_gateway.dart';
import 'comic_editor.dart';
import 'comic_reader.dart';
import 'comic_requests.dart';

/// Picks one existing illustration of the work, or null when cancelled.
Future<StoryAsset?> pickComicAsset(
  BuildContext context, {
  required String branchId,
}) => Navigator.push<StoryAsset>(
  context,
  MaterialPageRoute(
    builder: (_) => IllustrationGallery(
      branchId: branchId,
      picker: true,
      purpose: AssetPurpose.illustration,
    ),
  ),
);

/// Export reminders: drawn original pages whose storyboard changed since.
/// Adaptations are not listed; the exporter blocks their stale pages.
List<String> comicStaleNotes(String title, ComicDocument? doc) {
  if (doc == null || !doc.isOriginal) return [];
  final stale = doc.stalePageIds.toSet();
  return [
    for (final (i, page) in doc.pages.indexed)
      if (stale.contains(page['id'])) '$title 第 ${i + 1} 页：分镜已改，图未更新',
  ];
}

Widget _preview(ComicDocument? doc) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    if (doc == null) const Text('尚无当前分镜'),
    for (final (i, p) in (doc?.imageItems ?? <Map<String, dynamic>>[]).indexed)
      Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: doc!.hasPages
            ? ComicPageView(document: doc, page: p, number: i + 1)
            : ComicPanelView(panel: p, number: i + 1, details: true),
      ),
  ],
);

/// Compares a finished task's unwritten storyboard with [head]; adopting or
/// discarding it clears the candidate.
Future<void> showComicCandidate(
  BuildContext context,
  WidgetRef ref, {
  required String taskId,
  required String chapterId,
  required ComicRevision? head,
}) async {
  final repo = ref.read(repositoryProvider);
  final task = await repo.getTask(taskId);
  final doc = ComicDocument.fromJson(
    Map<String, dynamic>.from(
      (task.result['comicDocuments'] as Map)[chapterId] as Map,
    ),
  );
  if (!context.mounted) return;
  var saving = false;
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (_, update) {
        Future<void> resolve(bool adopt) async {
          update(() => saving = true);
          try {
            await repo.resolveComicCandidate(
              taskId: task.id,
              chapterId: chapterId,
              expectedRevisionId: head?.id,
              adopt: adopt,
            );
            if (ctx.mounted) Navigator.pop(ctx);
          } catch (e) {
            if (ctx.mounted) showError(ctx, e);
          } finally {
            if (ctx.mounted) update(() => saving = false);
          }
        }

        return AppDialog(
          title: const Text('比较候选分镜'),
          maxWidth: 900,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Originals have no check step to mark.
              Text(
                doc.isOriginal
                    ? '采用后旧版保留在历史中。若当前漫画已更新，请关闭后重新比较。'
                    : '采用后保留旧版历史，并标记待检查。若原文或当前分镜已更新，请关闭后重新比较。',
              ),
              const SizedBox(height: 16),
              const Text('当前分镜'),
              const SizedBox(height: 12),
              _preview(head?.document),
              const Text('候选分镜'),
              const SizedBox(height: 12),
              _preview(doc),
            ],
          ),
          actions: [
            comicButton('关闭', saving ? null : () => Navigator.pop(ctx)),
            comicButton('放弃候选', saving ? null : () => resolve(false)),
            FButton(
              onPress: saving ? null : () => resolve(true),
              child: Text(doc.isOriginal ? '采用' : '采用并标记待检查'),
            ),
          ],
        );
      },
    ),
  );
}

/// Whole-chapter comic history; restoring creates a new revision.
Future<void> showComicHistory(
  BuildContext context,
  WidgetRef ref, {
  required String branchId,
  required String chapterId,
}) async {
  final repo = ref.read(repositoryProvider);
  final head = await repo.getComic(branchId, chapterId);
  final revisions = await repo.listComicRevisions(branchId, chapterId);
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => AppDialog(
      title: const Text('漫画历史'),
      maxWidth: 720,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (revisions.isEmpty) const Text('本话还没有漫画版本'),
          for (final revision in revisions)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: FAccordion(
                children: [
                  FAccordionItem(
                    title: Text(
                      '${revision.createdAt.toLocal()} · ${revision.reason}${revision.id == head?.id ? ' · 当前' : ''}',
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _preview(revision.document),
                        if (revision.id != head?.id)
                          comicButton('恢复此版本', () async {
                            if (!await confirmAction(
                              ctx,
                              title: '恢复此漫画版本？',
                              // Originals restore without continuity review.
                              message: revision.document.isOriginal
                                  ? '会创建新的历史记录，当前版本仍可在历史中找回。'
                                  : '会创建新的历史记录，恢复的图片需重新确认画面衔接。原文已改变时标记依据过期。',
                            )) {
                              return;
                            }
                            try {
                              await repo.restoreComic(
                                branchId: branchId,
                                chapterId: chapterId,
                                revisionId: revision.id,
                                expectedRevisionId: head?.id,
                              );
                              if (ctx.mounted) Navigator.pop(ctx);
                            } catch (e) {
                              if (ctx.mounted) showError(ctx, e);
                            }
                          }),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [comicButton('关闭', () => Navigator.pop(ctx))],
    ),
  );
}

/// Exports a chapter range as an offline HTML ZIP, listing stale original
/// pages first; the exporter rejects unchecked or undrawn chapters.
Future<void> showComicExport(
  BuildContext context,
  WidgetRef ref, {
  required String branchId,
  required String chapterId,
}) async {
  final services = ref.read(servicesProvider);
  final files = ref.read(transferFilesProvider);
  final repo = services.repository;
  final story = await repo.getStory(branchId);
  var first = story.chapters.indexWhere((c) => c.id == chapterId), last = first;
  Future<List<String>> notes() async => [
    for (final c in story.chapters.sublist(first, last + 1))
      ...comicStaleNotes(
        c.title,
        (await repo.getComic(branchId, c.id))?.document,
      ),
  ];
  var stale = notes();
  var saving = false;
  if (!context.mounted) return;
  await showAppDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (_, update) => AppDialog(
        title: const Text('导出漫画 HTML ZIP'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ComicChapterRange(
              chapters: story.chapters,
              first: first,
              last: last,
              onChange: (a, b) => update(() {
                first = a;
                last = b;
                stale = notes();
              }),
            ),
            const SizedBox(height: 16),
            const Text('改编漫画须检查通过且图片齐全，原创漫画须每页都有图。导出保留完整文字与阅读顺序；依据过期的漫画会附带说明。'),
            FutureBuilder<List<String>>(
              future: stale,
              builder: (_, notes) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final note in notes.data ?? const <String>[])
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(note),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          comicButton('取消', saving ? null : () => Navigator.pop(ctx)),
          FButton(
            onPress: saving
                ? null
                : () async {
                    update(() => saving = true);
                    try {
                      final file = await services.comicPublications.export(
                        branchId: branchId,
                        chapterIds: story.chapters
                            .sublist(first, last + 1)
                            .map((c) => c.id)
                            .toList(),
                      );
                      if (!ctx.mounted) return;
                      if (await files.save(ctx, file) && ctx.mounted) {
                        Navigator.pop(ctx);
                      }
                    } catch (e) {
                      if (ctx.mounted) showError(ctx, e);
                    } finally {
                      if (ctx.mounted) update(() => saving = false);
                    }
                  },
            child: Text(saving ? '正在导出…' : '导出'),
          ),
        ],
      ),
    ),
  );
}

/// Edits an ordered reference list without saving; null when cancelled.
Future<List<String>?> pickComicReferences(
  BuildContext context, {
  required String branchId,
  required List<String> initial,
}) {
  final ids = List<String>.of(initial);
  return showAppDialog<List<String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (_, update) => AppDialog(
        title: const Text('参考图'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('按所选顺序发送；同场景前格会随后加入。模型参考图上限以生成确认页为准。'),
            const SizedBox(height: 16),
            for (final (i, id) in ids.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Expanded(child: Text('参考图 ${i + 1}')),
                    AssetImageView(
                      assetId: id,
                      width: 64,
                      height: 64,
                      label: '参考图 ${i + 1}',
                    ),
                    const SizedBox(width: 8),
                    comicButton('移除', () => update(() => ids.remove(id))),
                  ],
                ),
              ),
            comicButton(
              '选择参考图',
              ids.length >= 16
                  ? null
                  : () async {
                      final asset = await pickComicAsset(
                        context,
                        branchId: branchId,
                      );
                      if (asset != null &&
                          ctx.mounted &&
                          !ids.contains(asset.id)) {
                        update(() => ids.add(asset.id));
                      }
                    },
            ),
          ],
        ),
        actions: [
          comicButton('取消', () => Navigator.pop(ctx)),
          FButton(
            onPress: () => Navigator.pop(ctx, ids),
            child: const Text('保存参考图'),
          ),
        ],
      ),
    ),
  );
}
