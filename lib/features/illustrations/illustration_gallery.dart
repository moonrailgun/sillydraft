import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
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
    this.embedded = false,
  });
  final String branchId;
  final bool picker;
  final AssetPurpose purpose;
  final bool embedded;
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
      final card = await showAppSheet<LibraryResource>(
        context: context,
        title: '提取角色卡中的图片',
        builder: (context) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            if (cards.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                child: Text(
                  '请先在创作资源库导入角色卡',
                  style: TextStyle(color: context.theme.colors.mutedForeground),
                ),
              ),
            for (final c in cards)
              FItem(
                title: Text(c.name),
                subtitle: Text(c.filename),
                onPress: () => Navigator.pop(context, c),
              ),
          ],
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
        toast(
          context,
          result.warnings.isEmpty
              ? '已找到 ${result.assets.length} 张卡片图片（含已有素材）'
              : '部分图片无法导入：${result.warnings.join('；')}',
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
      showIllustrationDetail(
        context,
        assetId: asset.id,
        branchId: widget.branchId,
      );
    }
  }

  /// A header action, or a plain icon button in the workspace's title row.
  Widget _action({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPress,
  }) => widget.embedded
      ? IconAction(tooltip: tooltip, icon: icon, onPress: onPress)
      : HeaderIconAction(tooltip: tooltip, icon: icon, onPress: onPress);

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: widget.picker ? '选择图片' : '插图与素材',
    embedded: widget.embedded,
    actions: [
      _action(
        tooltip: '提取角色卡图片',
        icon: FLucideIcons.squareUser,
        onPress: _busy ? null : _cardArtwork,
      ),
      _action(
        tooltip: '导入图片',
        icon: FLucideIcons.imagePlus,
        onPress: _busy ? null : _import,
      ),
      _action(
        tooltip: '生成插画',
        icon: FLucideIcons.sparkles,
        onPress: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => IllustrationRequestScreen(
              branchId: widget.branchId,
              purpose: widget.purpose,
            ),
          ),
        ),
      ),
    ],
    body: SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const FProgress(),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ChoicePill(
                  label: '全部',
                  selected: _purpose == null,
                  onPress: () => setState(() => _purpose = null),
                ),
                for (final p in AssetPurpose.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoicePill(
                      label: assetPurposeLabels[p]!,
                      selected: _purpose == p,
                      onPress: () => setState(() => _purpose = p),
                    ),
                  ),
                const SizedBox(width: 8),
                ChoicePill(
                  label: '已归档',
                  icon: FLucideIcons.archive,
                  selected: _archived,
                  onPress: () => setState(() => _archived = !_archived),
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
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: FAccordion(
                          children: [
                            FAccordionItem(
                              title: Text('生图任务 · ${images.length}'),
                              child: SizedBox(
                                height: 220,
                                child: ListView(
                                  children: [
                                    for (final t in images)
                                      FItem(
                                        title: Text(
                                          t.input['name'] as String? ?? '插画',
                                        ),
                                        subtitle: Text(
                                          taskStatusLabels[t.status]!,
                                        ),
                                        suffix: const Icon(
                                          FLucideIcons.chevronRight,
                                        ),
                                        onPress: () => Navigator.push(
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
                            ),
                          ],
                        ),
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
                            : '导入图片，或为人物、章节和地图生成插画。\n图片保存在本地，随时可以插入正文。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: context.theme.colors.mutedForeground,
                        ),
                      ),
                    ),
                  );
                }
                final theme = context.theme;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 400,
                    mainAxisExtent: 260,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final asset = entries[i];
                    return FCard(
                      clipBehavior: Clip.antiAlias,
                      child: FTappable(
                        onPress: () => _open(asset),
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
                                    style: theme.typography.body.md.copyWith(
                                      color: theme.colors.foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    '${assetPurposeLabels[asset.purpose]} · ${asset.width} × ${asset.height}',
                                    style: theme.typography.body.xs.copyWith(
                                      color: theme.colors.mutedForeground,
                                    ),
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
