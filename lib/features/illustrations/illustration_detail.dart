import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
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
      if (story.scenes.isEmpty) throw const FormatException('请先创建正文场景');
      final scene = await showModalBottomSheet<Scene>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('插入到场景末尾')),
              for (final s in story.scenes)
                ListTile(
                  title: Text(s.title),
                  onTap: () => Navigator.pop(context, s),
                ),
            ],
          ),
        ),
      );
      if (scene == null) return;
      await ref
          .read(repositoryProvider)
          .insertIllustration(
            branchId: branchId,
            sceneId: scene.id,
            expectedRevisionId: scene.revisionId,
            assetId: asset.id,
            offset: scene.content.text.length - 1,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('插画已加入正文')));
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(assetProvider(assetId)),
    builder: (asset) => Scaffold(
      appBar: AppBar(
        title: Text(asset.name),
        actions: [
          IconButton(
            tooltip: '导出图片',
            onPressed: () => _export(context, ref, asset),
            icon: const Icon(Icons.ios_share),
          ),
          IconButton(
            tooltip: asset.archived ? '恢复图片' : '归档图片',
            onPressed: () async {
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
            icon: Icon(
              asset.archived
                  ? Icons.unarchive_outlined
                  : Icons.archive_outlined,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          SizedBox(
            height: 360,
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 5,
              child: AssetImageView(assetId: asset.id, label: asset.name),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '${asset.width} × ${asset.height} · ${(asset.byteLength / 1024 / 1024).toStringAsFixed(1)} MB',
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
              FilledButton.icon(
                onPressed: () => _insert(context, ref, asset),
                icon: const Icon(Icons.post_add),
                label: const Text('插入正文'),
              ),
              OutlinedButton(
                onPressed: () async {
                  try {
                    await ref
                        .read(repositoryProvider)
                        .setCover(asset.novelId, asset.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('已设为作品封面')));
                    }
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('设为封面'),
              ),
              OutlinedButton(
                onPressed: () => Navigator.push(
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
            Text('生成提示词', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            SelectableText(prompt),
          ],
          if (asset.metadata['model'] case final String model)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text('模型：$model'),
            ),
          if (asset.sourceRevisionId != null)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('已保存生成时的正文版本依据'),
            ),
          if (asset.metadata.isNotEmpty)
            ExpansionTile(
              title: const Text('来源与生成参数'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(asset.metadata),
                ),
              ],
            ),
        ],
      ),
    ),
  );
}
