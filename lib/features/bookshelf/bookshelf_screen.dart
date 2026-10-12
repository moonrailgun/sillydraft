import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/sample.dart';
import '../../app/widgets.dart';
import '../editor/workspace_screen.dart';
import '../settings/settings_screen.dart';
import 'novel_dialog.dart';
import '../resources/resource_library_screen.dart';
import '../illustrations/asset_image.dart';

class BookshelfScreen extends ConsumerStatefulWidget {
  const BookshelfScreen({super.key});
  @override
  ConsumerState<BookshelfScreen> createState() => _BookshelfState();
}

class _BookshelfState extends ConsumerState<BookshelfScreen> {
  String _query = '';
  bool _archived = false;
  Future<void> _create() async {
    final novel = await showNovelDialog(context);
    if (novel != null && mounted) _open(novel);
  }

  void _open(Novel novel) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => NovelWorkspace(novelId: novel.id)),
  );
  void _settings() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
  );
  void _resources() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => const ResourceLibraryScreen()),
  );
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
    final scheme = Theme.of(context).colorScheme;
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
                24,
                wide ? 40 : 24,
                16,
              ),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '让故事，慢慢生长。',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: .5,
                          ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '每一个念头，都可以成为下一章。',
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextField(
                      decoration: const InputDecoration(
                        hintText: '搜索作品',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        ChoiceChip(
                          label: Text(
                            '创作中 ${all.where((n) => !n.archived).length}',
                          ),
                          selected: !_archived,
                          onSelected: (_) => setState(() => _archived = false),
                        ),
                        const SizedBox(width: 10),
                        ChoiceChip(
                          label: const Text('已归档'),
                          selected: _archived,
                          onSelected: (_) => setState(() => _archived = true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (novels.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 72,
                        color: scheme.primary.withValues(alpha: .6),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _query.isNotEmpty
                            ? '没有找到这部作品'
                            : _archived
                            ? '这里会保留归档的作品'
                            : '你的第一部作品，从这里开始',
                        style: Theme.of(context).textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '正文会保存在设备上，离线也能写作和阅读。',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                      if (!_archived && _query.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: OutlinedButton.icon(
                            onPressed: _sample,
                            icon: const Icon(Icons.explore_outlined),
                            label: const Text('打开示例小说'),
                          ),
                        ),
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
                        mainAxisExtent: 292,
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
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_rounded, color: scheme.primary),
            const SizedBox(width: 12),
            const Flexible(
              child: Text(
                'SillyDraft',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _resources,
            tooltip: '创作资源库',
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            onPressed: _settings,
            tooltip: '设置',
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        top: false,
        child: wide
            ? Row(
                children: [
                  NavigationRail(
                    selectedIndex: 0,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (i) {
                      if (i == 1) _resources();
                      if (i == 2) _settings();
                    },
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.library_books_outlined),
                        selectedIcon: Icon(Icons.library_books_rounded),
                        label: Text('作品'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.folder_open_outlined),
                        label: Text('资源'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.settings_outlined),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: content),
                ],
              )
            : content,
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create-novel'),
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('新建作品'),
      ),
    );
  }
}

class _NovelCard extends StatelessWidget {
  const _NovelCard({
    required this.novel,
    required this.onOpen,
    required this.onArchive,
  });
  final Novel novel;
  final VoidCallback onOpen, onArchive;
  @override
  Widget build(BuildContext context) {
    final colors = [
      const Color(0xffe2dff0),
      const Color(0xffd9e6df),
      const Color(0xfff0e1d1),
      const Color(0xffdce5ee),
    ];
    final color =
        colors[novel.id.codeUnits.fold(0, (a, b) => a + b) % colors.length];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        label: '打开作品 ${novel.title}',
        onTap: onOpen,
        child: InkWell(
          excludeFromSemantics: true,
          onTap: onOpen,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: novel.coverAssetId != null
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
                            Positioned(
                              right: -12,
                              bottom: -10,
                              child: Icon(
                                Icons.auto_stories_rounded,
                                size: 120,
                                color: Colors.white.withValues(alpha: .4),
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  novel.genre,
                                  style: const TextStyle(
                                    color: Color(0xff514b65),
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  novel.title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 23,
                                    height: 1.35,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xff343044),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            novel.synopsis.isEmpty
                                ? '一个正在生长的故事'
                                : novel.synopsis,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${dateLabel(novel.updatedAt)} 更新',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '作品操作',
                      onSelected: (_) => onArchive(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'archive',
                          child: Text(novel.archived ? '恢复到书架' : '归档作品'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
