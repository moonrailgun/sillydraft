import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/library_host.dart';
import '../../app/services.dart';
import '../remote/library_switcher.dart';
import '../remote/share_screen.dart';
import '../../app/sample.dart';
import '../../app/widgets.dart';
import '../branches/branch_screen.dart';
import '../editor/workspace_screen.dart';
import 'novel_dialog.dart';
import 'novel_start.dart';
import 'search_screen.dart';
import '../illustrations/asset_image.dart';
import '../transfer/restore_screen.dart';
import '../transfer/sync_screen.dart';
import '../transfer/transfer_screen.dart';

class BookshelfScreen extends ConsumerStatefulWidget {
  const BookshelfScreen({super.key});
  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfState();
}

class _BookshelfState extends ConsumerState<BookshelfScreen> {
  String _query = '';
  bool _archived = false, _dragging = false;

  Future<void> _drop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final file = details.files.firstOrNull;
    if (file == null) return;
    if (details.files.length > 1) {
      toast(context, '一次开始一部作品，已使用 ${file.name}');
    }
    await startFromFile(context, name: file.name, read: file.readAsBytes);
  }

  void _open(Novel novel) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => NovelWorkspace(novelId: novel.id)),
  );
  Future<void> _delete(Novel novel) async {
    final yes = await confirmAction(
      context,
      title: '删除“${novel.title}”？',
      message: '作品的全部章节、分支、版本历史、资料和编辑会话都会删除，不能撤销。资源库里的卡片和预设会保留。',
      confirmLabel: '删除作品',
      destructive: true,
    );
    if (!yes || !mounted) return;
    try {
      await ref.read(repositoryProvider).deleteNovel(novel.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _sample() async {
    try {
      final novel = await createSample(ref.read(repositoryProvider));
      if (mounted) _open(novel);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final theme = context.theme;
    final content = AsyncView(
      value: ref.watch(novelsProvider),
      retry: () => ref.invalidate(novelsProvider),
      builder: (List<Novel> all) {
        final novels = all
            .where(
              (n) =>
                  n.archived == _archived &&
                  '${n.title} ${n.synopsis}'.toLowerCase().contains(
                    _query.toLowerCase(),
                  ),
            )
            .toList();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                wide ? 40 : 24,
                12,
                wide ? 40 : 24,
                12,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FTextField(
                      hint: '搜索作品',
                      prefixBuilder: (context, style, variants) =>
                          FTextField.prefixIconBuilder(
                            context,
                            style,
                            variants,
                            const Icon(FLucideIcons.search),
                          ),
                      control: FTextFieldControl.managed(
                        onChange: (v) {
                          if (v.text != _query) {
                            setState(() => _query = v.text);
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        ChoicePill(
                          label: '创作中 ${all.where((n) => !n.archived).length}',
                          selected: !_archived,
                          onPress: () => setState(() => _archived = false),
                        ),
                        ChoicePill(
                          label: '已归档',
                          selected: _archived,
                          onPress: () => setState(() => _archived = true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (novels.isEmpty)
              // Scrolls like any page: the ways to begin are taller than a
              // small phone once text is enlarged.
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
                  child: Column(
                    children: [
                      Icon(
                        FLucideIcons.libraryBig,
                        size: 72,
                        color: theme.colors.mutedForeground.withValues(
                          alpha: .6,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _query.isNotEmpty
                            ? '没有找到这部作品'
                            : _archived
                            ? '这里会保留归档的作品'
                            : '你的第一部作品，从这里开始',
                        style: theme.typography.body.xl.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colors.foreground,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '正文会保存在设备上，离线也能写作和阅读。',
                        style: theme.typography.body.sm.copyWith(
                          color: theme.colors.mutedForeground,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (!_archived && _query.isEmpty) ...[
                        const SizedBox(height: 24),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: const NovelStartOptions(),
                        ),
                        const SizedBox(height: 16),
                        FButton(
                          variant: FButtonVariant.ghost,
                          mainAxisSize: MainAxisSize.min,
                          onPress: _sample,
                          prefix: const Icon(FLucideIcons.compass),
                          child: const Text('或者先看看示例小说'),
                        ),
                      ],
                      const SizedBox(height: 80),
                    ],
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 40 : 24,
                  4,
                  wide ? 40 : 24,
                  120,
                ),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.crossAxisExtent / 250)
                        .floor()
                        .clamp(1, 4);
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisExtent:
                            292 +
                            (MediaQuery.textScalerOf(context).scale(100) - 100)
                                .clamp(0, 300),
                        crossAxisSpacing: 20,
                        mainAxisSpacing: 20,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) => _NovelCard(
                          novel: novels[i],
                          onOpen: () => _open(novels[i]),
                          onArchive: () async {
                            await ref
                                .read(repositoryProvider)
                                .archiveNovel(
                                  novels[i].id,
                                  archived: !novels[i].archived,
                                );
                          },
                          onDelete: novels[i].archived
                              ? () => _delete(novels[i])
                              : null,
                        ),
                        childCount: novels.length,
                      ),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
    return AppScaffold(
      header: FHeader(
        // Like an app bar title: legible at large text, never huge.
        // The wide layout's sidebar already carries the app's mark; phones
        // and tablets switch libraries here at any width.
        title: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.34,
          child: isPhone
              ? const LibrarySwitcher()
              : MediaQuery.sizeOf(context).width >= 900
              ? const Text('作品')
              : Row(
                  children: [
                    Icon(
                      FLucideIcons.libraryBig,
                      size: 24,
                      color: theme.colors.foreground,
                    ),
                    const SizedBox(width: 12),
                    const Flexible(
                      child: Text(
                        'SillyDraft',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
        ),
        suffixes: [
          HeaderIconAction(
            icon: FLucideIcons.search,
            tooltip: '搜索正文',
            onPress: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const GlobalSearchScreen(),
              ),
            ),
          ),
          MenuAction(
            header: true,
            tooltip: '导入与同步',
            entries: [
              menuEntry(
                '恢复项目备份',
                () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const RestoreBackupScreen(),
                  ),
                ),
                icon: FLucideIcons.archiveRestore,
              ),
              menuEntry(
                '连接远端作品',
                () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ProjectSyncScreen(),
                  ),
                ),
                icon: FLucideIcons.cloudSync,
              ),
              if (isPhone)
                menuEntry(
                  '扫码',
                  () => scanLink(context, ref),
                  icon: FLucideIcons.scanLine,
                ),
              menuEntry(
                '粘贴链接',
                () => pasteLink(context, ref),
                icon: FLucideIcons.clipboardPaste,
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingAction(
        key: const Key('create-novel'),
        icon: FLucideIcons.plus,
        label: '新建作品',
        onPress: () => showNovelStart(context),
      ),
      child: SafeArea(
        top: false,
        child: canDropFiles
            ? DropTarget(
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                onDragDone: _drop,
                child: Stack(
                  children: [
                    Positioned.fill(child: content),
                    if (_dragging) const Positioned.fill(child: _DropHint()),
                  ],
                ),
              )
            : content,
      ),
    );
  }
}

/// Shown while a file is dragged over the shelf.
class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colors.secondary.withValues(alpha: .92),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: theme.colors.primary, width: 2),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                FLucideIcons.fileDown,
                size: 56,
                color: theme.colors.primary,
              ),
              const SizedBox(height: 16),
              Text(
                '松开以开始一部作品',
                style: theme.typography.body.xl.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colors.secondaryForeground,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '小说 TXT、Markdown、EPUB：导入后续写\n角色卡 PNG、JSON、CHARX：选开场开始故事',
                textAlign: TextAlign.center,
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.secondaryForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NovelCard extends ConsumerWidget {
  const _NovelCard({
    required this.novel,
    required this.onOpen,
    required this.onArchive,
    this.onDelete,
  });
  final Novel novel;

  /// Only archived works can be deleted.
  final VoidCallback? onDelete;

  final VoidCallback onOpen, onArchive;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = [
      const Color(0xffe2dff0),
      const Color(0xffd9e6df),
      const Color(0xfff0e1d1),
      const Color(0xffdce5ee),
    ];
    final color =
        colors[novel.id.codeUnits.fold(0, (a, b) => a + b) % colors.length];
    return FCard(
      clipBehavior: Clip.antiAlias,
      child: FTappable(
        semanticsLabel: '打开作品 ${novel.title}',
        onPress: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _cover(color)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
              child: _footer(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cover(Color color) => novel.coverAssetId != null
      ? AssetImageView(
          assetId: novel.coverAssetId!,
          thumbnail: true,
          fit: BoxFit.cover,
          label: '${novel.title}的封面',
        )
      : Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, color.withValues(alpha: .5)],
            ),
          ),
          padding: const EdgeInsets.all(24),
          child: Stack(
            children: [
              const Positioned(
                right: -12,
                bottom: -10,
                child: Icon(
                  FLucideIcons.bookOpen,
                  size: 120,
                  color: Color(0x66ffffff),
                ),
              ),
            ],
          ),
        );

  Widget _footer(BuildContext context) {
    final theme = context.theme;
    final synopsis = novel.synopsis.trim();
    final genre = novel.genre.trim();
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                novel.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body.md.copyWith(
                  color: theme.colors.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (synopsis.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  synopsis,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body.sm.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                '${genre.isEmpty ? '' : '$genre · '}${dateLabel(novel.updatedAt)} 更新',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.body.xs.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
        MenuAction(
          tooltip: '作品操作',
          entries: [
            menuEntry(
              '作品信息',
              () => showNovelDialog(context, novel: novel),
              icon: FLucideIcons.info,
            ),
            menuEntry(
              '故事分支',
              () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => BranchScreen(novelId: novel.id),
                ),
              ),
              icon: FLucideIcons.gitBranch,
            ),
            menuEntry(
              '导出、备份与同步',
              () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => TransferScreen(novelId: novel.id),
                ),
              ),
              icon: FLucideIcons.share2,
            ),
            menuEntry(
              novel.archived ? '恢复到书架' : '归档作品',
              onArchive,
              icon: novel.archived
                  ? FLucideIcons.archiveRestore
                  : FLucideIcons.archive,
            ),
            if (onDelete case final delete?)
              menuEntry(
                '删除作品',
                delete,
                icon: FLucideIcons.trash2,
                destructive: true,
              ),
          ],
        ),
      ],
    );
  }
}
