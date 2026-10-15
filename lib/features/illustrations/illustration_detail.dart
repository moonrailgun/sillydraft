import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_screen.dart' show imageEngineLabel;
import '../agent/task_screen.dart' show taskProvider;
import 'asset_image.dart';
import 'illustration_request.dart';

final assetProvider = FutureProvider.family<StoryAsset, String>((ref, id) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getAsset(id);
});
final _sourceCurrent = FutureProvider.family<bool, String>((ref, id) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).assetSourceCurrent(id);
});

/// Opens the image over the current page instead of navigating away: inset
/// on wide screens, full screen on phones. A tap outside closes it.
Future<void> showIllustrationDetail(
  BuildContext context, {
  required String assetId,
  required String branchId,
}) => showAppDialog<void>(
  context: context,
  builder: (context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Padding(
      padding: EdgeInsets.all(wide ? 40 : 0),
      child: ClipRRect(
        borderRadius: wide
            ? context.theme.style.borderRadius.lg
            : BorderRadius.zero,
        child: IllustrationDetail(assetId: assetId, branchId: branchId),
      ),
    );
  },
);

class IllustrationDetail extends ConsumerWidget {
  const IllustrationDetail({
    super.key,
    required this.assetId,
    required this.branchId,
  });
  final String assetId, branchId;
  Future<void> _export(
    BuildContext context,
    WidgetRef ref,
    StoryAsset asset,
  ) async {
    try {
      final library = ref.read(servicesProvider).assets;
      if (library == null) throw const FormatException('图片目录未配置');
      final bytes = await library.read(asset.id);
      final file = XFile.fromData(
        bytes,
        mimeType: 'image/png',
        name: 'illustration.png',
      );
      if (!context.mounted) return;
      if (Platform.isAndroid || Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [file],
            fileNameOverrides: ['illustration.png'],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(
          suggestedName: 'illustration.png',
        );
        if (location != null) await File(location.path).writeAsBytes(bytes);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _insert(
    BuildContext context,
    WidgetRef ref,
    StoryAsset asset,
  ) async {
    try {
      await ref.read(servicesProvider).flushDrafts();
      final story = await ref.read(repositoryProvider).getStory(branchId);
      if (!context.mounted) return;
      if (story.chapters.isEmpty) throw const FormatException('请先创建正文章节');
      final chapter = await showAppSheet<Chapter>(
        context: context,
        title: '插入到章节末尾',
        builder: (context) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            for (final s in story.chapters)
              FItem(
                title: Text(s.title),
                onPress: () => Navigator.pop(context, s),
              ),
          ],
        ),
      );
      if (chapter == null) return;
      await ref
          .read(repositoryProvider)
          .insertIllustration(
            branchId: branchId,
            chapterId: chapter.id,
            expectedRevisionId: chapter.revisionId,
            assetId: asset.id,
            offset: chapter.content.text.length - 1,
          );
      if (context.mounted) toast(context, '插画已加入正文');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  /// The engine as the task froze it, which also names a ComfyUI workflow;
  /// the stored model alone for an image without its task.
  String? _engine(WidgetRef ref, StoryAsset asset) {
    final task = asset.taskId == null
        ? null
        : ref.watch(taskProvider(asset.taskId!)).value;
    if (task?.input['connection'] case final Map<String, dynamic> raw) {
      return imageEngineLabel(
        ModelConnection.fromJson(raw),
        workflow: asset.metadata['workflow'] as String?,
      );
    }
    return asset.metadata['model'] as String?;
  }

  /// Everything about the image besides the image itself: size, actions and
  /// how it was generated. The side panel on wide screens, a sheet otherwise.
  List<Widget> _details(
    BuildContext context,
    WidgetRef ref,
    StoryAsset asset,
  ) => [
    Text(
      '${asset.width} × ${asset.height} · ${(asset.byteLength / 1024 / 1024).toStringAsFixed(1)} MB',
      style: TextStyle(color: context.theme.colors.mutedForeground),
    ),
    if (ref.watch(_sourceCurrent(asset.id)).value == false)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('依据的正文版本已变化。这张图片仍保留原有来源，可继续使用或重新生成。'),
      ),
    const SizedBox(height: 16),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: () => _insert(context, ref, asset),
          prefix: const Icon(FLucideIcons.filePlus),
          child: const Text('插入正文'),
        ),
        FButton(
          variant: FButtonVariant.outline,
          mainAxisSize: MainAxisSize.min,
          onPress: () async {
            try {
              await ref
                  .read(repositoryProvider)
                  .setCover(asset.novelId, asset.id);
              if (context.mounted) toast(context, '已设为作品封面');
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          child: const Text('设为封面'),
        ),
        FButton(
          variant: FButtonVariant.outline,
          mainAxisSize: MainAxisSize.min,
          onPress: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => IllustrationRequestScreen(
                branchId: branchId,
                referenceIds: [asset.id],
                purpose: asset.purpose,
                initialPrompt: asset.metadata['prompt'] as String? ?? '',
              ),
            ),
          ),
          child: const Text('参考此图创作'),
        ),
      ],
    ),
    const SizedBox(height: 24),
    if (asset.metadata['prompt'] case final String prompt) ...[
      Text(
        '生成提示词',
        style: context.theme.typography.body.md.copyWith(
          color: context.theme.colors.foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 12),
      SelectableText(prompt),
    ],
    if (_engine(ref, asset) case final engine?)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Text('生图引擎：$engine'),
      ),
    if (asset.sourceRevisionId != null)
      const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('已保存生成时的正文版本依据'),
      ),
    if (asset.metadata.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FAccordion(
          children: [
            FAccordionItem(
              title: const Text('来源与生成参数'),
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(asset.metadata),
              ),
            ),
          ],
        ),
      ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(assetProvider(assetId)),
    builder: (asset) {
      final wide = MediaQuery.sizeOf(context).width >= 900;
      final preview = InteractiveViewer(
        minScale: .5,
        maxScale: 5,
        child: Center(
          child: AssetImageView(assetId: asset.id, label: asset.name),
        ),
      );
      return PageScaffold(
        title: asset.name,
        leading: HeaderIconAction(
          tooltip: '关闭',
          icon: FLucideIcons.x,
          onPress: () => Navigator.pop(context),
        ),
        actions: [
          if (!wide)
            HeaderIconAction(
              tooltip: '图片详情',
              icon: FLucideIcons.info,
              onPress: () => showAppSheet<void>(
                context: context,
                title: '图片详情',
                // Its own ref: the sheet is not part of this page's element.
                builder: (_) => Consumer(
                  builder: (context, ref, _) => ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    children: _details(context, ref, asset),
                  ),
                ),
              ),
            ),
          HeaderIconAction(
            tooltip: '导出图片',
            icon: FLucideIcons.share,
            onPress: () => _export(context, ref, asset),
          ),
          HeaderIconAction(
            tooltip: asset.archived ? '恢复图片' : '归档图片',
            icon: asset.archived
                ? FLucideIcons.archiveRestore
                : FLucideIcons.archive,
            onPress: () async {
              try {
                await ref
                    .read(repositoryProvider)
                    .archiveAsset(asset.id, archived: !asset.archived);
                if (context.mounted && Navigator.canPop(context)) {
                  Navigator.pop(context);
                }
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
        ],
        body: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: preview,
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: context.theme.colors.border),
                      ),
                    ),
                    child: SizedBox(
                      width: 360,
                      child: ListView(
                        padding: const EdgeInsets.all(24),
                        children: _details(context, ref, asset),
                      ),
                    ),
                  ),
                ],
              )
            : Padding(padding: const EdgeInsets.all(12), child: preview),
      );
    },
  );
}
