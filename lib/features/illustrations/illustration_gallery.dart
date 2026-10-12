import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../agent/task_screen.dart';
import 'asset_image.dart';
import 'illustration_detail.dart';
import 'illustration_request.dart';

const assetPurposeLabels = {
  AssetPurpose.illustration: '插画',
  AssetPurpose.cover: '封面',
  AssetPurpose.map: '地图',
  AssetPurpose.reference: '参考图',
};
final assetsProvider = FutureProvider.family<List<StoryAsset>, String>((
  ref,
  branchId,
) async {
  ref.watch(repositoryChangesProvider);
  final repo = ref.watch(repositoryProvider),
      branch = await ref.watch(repositoryProvider).getBranch(branchId);
  return repo.listAssets(branch.novelId, includeArchived: true);
});

class IllustrationGallery extends ConsumerStatefulWidget {
  const IllustrationGallery({
    super.key,
    required this.branchId,
    this.picker = false,
    this.purpose = AssetPurpose.illustration,
  });
  final String branchId;
  final bool picker;
  final AssetPurpose purpose;
  @override
  ConsumerState<IllustrationGallery> createState() => _GalleryState();
}

class _GalleryState extends ConsumerState<IllustrationGallery> {
  bool _busy = false, _archived = false;
  Future<void> _cardArtwork() async {
    try {
      final cards = await ref
          .read(repositoryProvider)
          .listResources(kind: ResourceKind.character);
      if (!mounted) return;
      final card = await showModalBottomSheet<LibraryResource>(
        context: context,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('提取角色卡中的图片')),
              if (cards.isEmpty) const ListTile(title: Text('请先在创作资源库导入角色卡')),
              for (final c in cards)
                ListTile(
                  title: Text(c.name),
                  subtitle: Text(c.filename),
                  onTap: () => Navigator.pop(context, c),
                ),
            ],
          ),
        ),
      );
      if (card == null || !mounted) return;
      setState(() => _busy = true);
      final services = ref.read(servicesProvider),
          library = ref.read(servicesProvider).assets;
      if (library == null) throw const FormatException('本地图片目录尚未配置');
      final result = await library.importCardArtwork(
        branchId: widget.branchId,
        resourceId: card.id,
        resources: services.library,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.warnings.isEmpty
                  ? '已找到 ${result.assets.length} 张卡片图片（含已有素材）'
                  : '部分图片无法导入：${result.warnings.join('；')}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AssetPurpose? _purpose;
  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: '图片',
            extensions: ['png', 'jpg', 'jpeg', 'webp'],
            uniformTypeIdentifiers: [
              'public.png',
              'public.jpeg',
              'org.webmproject.webp',
            ],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > AssetLibrary.maxBytes) {
        throw const FormatException('图片不能超过 32 MB');
      }
      final library = ref.read(servicesProvider).assets;
      if (library == null) throw const FormatException('本地图片目录尚未配置');
      final asset = await library.importImage(
        branchId: widget.branchId,
        name: file.name,
        bytes: await file.readAsBytes(),
        purpose: widget.purpose,
        metadata: {'origin': 'import'},
      );
      if (mounted) _open(asset);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(StoryAsset asset) {
    if (widget.picker) {
      Navigator.pop(context, asset);
    } else {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) =>
              IllustrationDetail(assetId: asset.id, branchId: widget.branchId),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.picker ? '选择图片' : '插图与素材'),
      actions: [
        IconButton(
          tooltip: '提取角色卡图片',
          onPressed: _busy ? null : _cardArtwork,
          icon: const Icon(Icons.portrait_outlined),
        ),
        IconButton(
          tooltip: '导入图片',
          onPressed: _busy ? null : _import,
          icon: const Icon(Icons.add_photo_alternate_outlined),
        ),
        IconButton(
          tooltip: '生成插画',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => IllustrationRequestScreen(
                branchId: widget.branchId,
                purpose: widget.purpose,
              ),
            ),
          ),
          icon: const Icon(Icons.auto_awesome_outlined),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _purpose == null,
                  onSelected: (_) => setState(() => _purpose = null),
                ),
                for (final p in AssetPurpose.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(assetPurposeLabels[p]!),
                      selected: _purpose == p,
                      onSelected: (_) => setState(() => _purpose = p),
                    ),
                  ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('已归档'),
                  selected: _archived,
                  onSelected: (v) => setState(() => _archived = v),
                ),
              ],
            ),
          ),
          if (!widget.picker)
            AsyncView(
              value: ref.watch(tasksProvider(widget.branchId)),
              builder: (tasks) {
                final images = tasks
                    .where((t) => t.kind == TaskKind.illustration)
                    .toList();
                return images.isEmpty
                    ? const SizedBox()
                    : ExpansionTile(
                        title: Text('生图任务 · ${images.length}'),
                        children: [
                          SizedBox(
                            height: 220,
                            child: ListView(
                              children: [
                                for (final t in images)
                                  ListTile(
                                    title: Text(
                                      t.input['name'] as String? ?? '插画',
                                    ),
                                    subtitle: Text(taskStatusLabels[t.status]!),
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            TaskScreen(taskId: t.id),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      );
              },
            ),
          Expanded(
            child: AsyncView(
              value: ref.watch(assetsProvider(widget.branchId)),
              builder: (all) {
                final entries = all
                    .where(
                      (a) =>
                          a.archived == _archived &&
                          (_purpose == null || a.purpose == _purpose),
                    )
                    .toList();
                if (entries.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _archived
                            ? '暂无归档图片'
                            : '导入图片，或为人物、场景和地图生成插画。\n图片保存在本地，随时可以插入正文。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 400,
                    mainAxisExtent: 260,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final asset = entries[i];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _open(asset),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: AssetImageView(
                                assetId: asset.id,
                                thumbnail: true,
                                fit: BoxFit.cover,
                                label: asset.name,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    asset.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  Text(
                                    '${assetPurposeLabels[asset.purpose]} · ${asset.width} × ${asset.height}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
