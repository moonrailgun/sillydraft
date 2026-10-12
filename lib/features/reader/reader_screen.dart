import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../branches/branch_screen.dart';
import '../illustrations/asset_image.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.branchId});
  final String branchId;
  @override
  ConsumerState<ReaderScreen> createState() => _ReaderState();
}

class _ReaderState extends ConsumerState<ReaderScreen> {
  final _scroll = ScrollController();
  final _textKey = GlobalKey(), _viewportKey = GlobalKey();
  late final AppServices _services;
  Timer? _timer;
  int _index = 0;
  double _fontSize = 20, _lineHeight = 1.9;
  String _theme = 'paper';
  bool _initialized = false;
  StorySnapshot? _story;
  @override
  void initState() {
    super.initState();
    _services = ref.read(servicesProvider);
    _services.registerDraft(this, _saveProgress);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _services.unregisterDraft(this);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(
        _saveProgress().catchError((Object error) {
          if (mounted) showError(context, error);
        }),
      ),
    );
  }

  Future<void> _saveProgress() async {
    final story = _story;
    if (story == null || story.scenes.isEmpty || !_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    await _services.repository.setReadingProgress(
      branchId: widget.branchId,
      sceneId: story.scenes[_index.clamp(0, story.scenes.length - 1)].id,
      fraction: extent <= 0 ? 0 : (_scroll.offset / extent).clamp(0, 1),
    );
  }

  Future<void> _initialize(StorySnapshot story) async {
    if (_initialized) return;
    _initialized = true;
    final prefs = await ref.read(repositoryProvider).getSetting('reader');
    final progress = await ref
        .read(repositoryProvider)
        .getReadingProgress(widget.branchId);
    if (!mounted) return;
    setState(() {
      _fontSize = (prefs?['fontSize'] as num? ?? 20).toDouble().clamp(14, 32);
      _lineHeight = (prefs?['lineHeight'] as num? ?? 1.9).toDouble().clamp(
        1.3,
        2.4,
      );
      _theme = prefs?['theme'] as String? ?? 'paper';
      final index = story.scenes.indexWhere(
        (s) => s.id == progress?['sceneId'],
      );
      if (index >= 0) _index = index;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(
          _scroll.position.maxScrollExtent *
              (progress?['fraction'] as num? ?? 0).toDouble().clamp(0, 1),
        );
      }
    });
  }

  RenderParagraph? get _paragraph {
    RenderParagraph? result;
    void visit(RenderObject object) {
      if (object is RenderParagraph) {
        result ??= object;
      } else {
        object.visitChildren(visit);
      }
    }

    final root = _textKey.currentContext?.findRenderObject();
    if (root != null) visit(root);
    return result;
  }

  int _currentTextOffset() {
    final paragraph = _paragraph;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (paragraph == null || viewport is! RenderBox) return 0;
    final top = paragraph.globalToLocal(viewport.localToGlobal(Offset.zero));
    return paragraph
        .getPositionForOffset(Offset(0, top.dy.clamp(0, paragraph.size.height)))
        .offset;
  }

  void _go(int index, {int offset = 0}) {
    if (_story == null || index < 0 || index >= _story!.scenes.length) return;
    setState(() => _index = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (offset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final paragraph = _paragraph;
        final viewport = _viewportKey.currentContext?.findRenderObject();
        if (paragraph == null || viewport is! RenderBox) return;
        final caret = paragraph.getOffsetForCaret(
          TextPosition(
            offset: offset.clamp(0, _story!.scenes[index].content.text.length),
          ),
          Rect.zero,
        );
        final y =
            paragraph.localToGlobal(caret).dy -
            viewport.localToGlobal(Offset.zero).dy;
        _scroll.jumpTo(
          (_scroll.offset + y).clamp(0, _scroll.position.maxScrollExtent),
        );
      });
    }
    unawaited(
      ref
          .read(repositoryProvider)
          .setReadingProgress(
            branchId: widget.branchId,
            sceneId: _story!.scenes[index].id,
            fraction: 0,
          ),
    );
  }

  Future<void> _preferences() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('阅读排版', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 20),
                Text('字号 ${_fontSize.round()}'),
                Slider(
                  value: _fontSize.clamp(14, 32),
                  min: 14,
                  max: 32,
                  divisions: 18,
                  onChanged: (v) {
                    setState(() => _fontSize = v);
                    setSheet(() {});
                  },
                ),
                Text('行距 ${_lineHeight.toStringAsFixed(1)}'),
                Slider(
                  value: _lineHeight.clamp(1.3, 2.4),
                  min: 1.3,
                  max: 2.4,
                  divisions: 11,
                  onChanged: (v) {
                    setState(() => _lineHeight = v);
                    setSheet(() {});
                  },
                ),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final entry in {
                      'paper': '纸白',
                      'sepia': '暖纸',
                      'night': '夜读',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _theme == entry.key,
                        onSelected: (_) {
                          setState(() => _theme = entry.key);
                          setSheet(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await ref.read(repositoryProvider).setSetting('reader', {
      'fontSize': _fontSize,
      'lineHeight': _lineHeight,
      'theme': _theme,
    });
  }

  Future<void> _contents(StorySnapshot story) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: ListView(
            children: [
              const ListTile(
                title: Text(
                  '正文目录',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              for (final chapter in story.chapters) ...[
                ListTile(
                  dense: true,
                  title: Text(
                    chapter.title,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
                for (final scene in story.scenesInChapter(chapter.id))
                  ListTile(
                    title: Text(scene.title),
                    selected: story.scenes.indexOf(scene) == _index,
                    onTap: () {
                      _go(story.scenes.indexOf(scene));
                      Navigator.pop(context);
                    },
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _bookmarks(StorySnapshot story) async {
    final bookmarks = await ref
        .read(repositoryProvider)
        .listBookmarks(story.branch.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('书签'),
              trailing: TextButton.icon(
                onPressed: () async {
                  final scene = story.scenes[_index];
                  await ref
                      .read(repositoryProvider)
                      .addBookmark(
                        branchId: story.branch.id,
                        sceneId: scene.id,
                        label: scene.title,
                        offset: _currentTextOffset(),
                      );
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('添加当前位置'),
              ),
            ),
            if (bookmarks.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('还没有书签。')),
            for (final mark in bookmarks)
              ListTile(
                title: Text(mark.label),
                leading: const Icon(Icons.bookmark_outline),
                onTap: () {
                  _go(
                    story.scenes.indexWhere((s) => s.id == mark.sceneId),
                    offset: mark.offset,
                  );
                  Navigator.pop(context);
                },
                trailing: IconButton(
                  tooltip: '删除书签',
                  icon: const Icon(Icons.close),
                  onPressed: () async {
                    await ref.read(repositoryProvider).removeBookmark(mark.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _search(StorySnapshot story) async {
    final query = await askText(context, title: '搜索正文', label: '关键词');
    if (query == null || !mounted) return;
    final matches = story.scenes
        .where((s) => s.content.text.contains(query))
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text('找到 ${matches.length} 个场景')),
            for (final scene in matches)
              ListTile(
                title: Text(scene.title),
                subtitle: Text(
                  scene.content.text
                      .substring(
                        (scene.content.text.indexOf(query) - 20).clamp(
                          0,
                          scene.content.text.length,
                        ),
                      )
                      .replaceAll('\n', ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  _go(
                    story.scenes.indexOf(scene),
                    offset: scene.content.text.indexOf(query),
                  );
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AsyncView(
    value: ref.watch(storyProvider(widget.branchId)),
    builder: (story) {
      _story = story;
      if (!_initialized) unawaited(_initialize(story));
      final background = _theme == 'night'
          ? const Color(0xff20212a)
          : _theme == 'sepia'
          ? const Color(0xfff1e8d7)
          : const Color(0xfffbfaf7);
      final foreground = _theme == 'night'
          ? const Color(0xffe1dfd7)
          : const Color(0xff34312e);
      if (story.scenes.isEmpty) {
        return Scaffold(
          appBar: AppBar(title: Text(story.novel.title)),
          body: const Center(child: Text('这部作品还没有正文。')),
        );
      }
      _index = _index.clamp(0, story.scenes.length - 1);
      final scene = story.scenes[_index];
      return PopScope(
        canPop: true,
        onPopInvokedWithResult: (popped, _) {
          if (popped) {
            unawaited(
              _saveProgress().catchError((Object error) {
                if (context.mounted) showError(context, error);
              }),
            );
          }
        },
        child: Scaffold(
          backgroundColor: background,
          appBar: AppBar(
            backgroundColor: background,
            foregroundColor: foreground,
            title: Text(
              story.novel.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: '搜索正文',
                onPressed: () => _search(story),
                icon: const Icon(Icons.search),
              ),
              PopupMenuButton<String>(
                tooltip: '阅读设置',
                onSelected: (value) {
                  if (value == 'style') {
                    _preferences();
                  } else {
                    _bookmarks(story);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'style', child: Text('排版与主题')),
                  PopupMenuItem(value: 'bookmarks', child: Text('书签')),
                ],
              ),
            ],
          ),
          body: SelectionArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: SingleChildScrollView(
                  key: _viewportKey,
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(28, 32, 28, 64),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        story.chapters
                            .where((c) => c.id == scene.chapterId)
                            .first
                            .title,
                        style: TextStyle(
                          color: foreground.withValues(alpha: .6),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        scene.title,
                        style: TextStyle(
                          fontSize: _fontSize + 8,
                          fontWeight: FontWeight.w600,
                          color: foreground,
                        ),
                      ),
                      const SizedBox(height: 36),
                      Text.rich(
                        _manuscriptSpan(scene.content, foreground),
                        key: _textKey,
                        style: TextStyle(
                          fontSize: _fontSize,
                          height: _lineHeight,
                          color: foreground,
                          fontFamilyFallback: const [
                            'Songti SC',
                            'Noto Serif CJK SC',
                          ],
                        ),
                      ),
                      const SizedBox(height: 36),
                      Text(
                        _index == story.scenes.length - 1
                            ? '— 当前正文结束 —'
                            : '— 本幕完 —',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: foreground.withValues(alpha: .5),
                          fontSize: 13,
                        ),
                      ),
                      if (_index == story.scenes.length - 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: TextButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => BranchScreen(
                                  novelId: story.novel.id,
                                  sourceBranchId: story.branch.id,
                                ),
                              ),
                            ),
                            icon: const Icon(Icons.fork_right),
                            label: const Text('探索后续走向与结局'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '目录',
                    onPressed: () => _contents(story),
                    icon: Icon(Icons.list_rounded, color: foreground),
                  ),
                  IconButton(
                    tooltip: '上一幕',
                    onPressed: _index > 0 ? () => _go(_index - 1) : null,
                    icon: Icon(Icons.chevron_left, color: foreground),
                  ),
                  Expanded(
                    child: Text(
                      '${_index + 1} / ${story.scenes.length}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: foreground),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一幕',
                    onPressed: _index < story.scenes.length - 1
                        ? () => _go(_index + 1)
                        : null,
                    icon: Icon(Icons.chevron_right, color: foreground),
                  ),
                  IconButton(
                    tooltip: '排版与主题',
                    onPressed: _preferences,
                    icon: Icon(Icons.text_fields_rounded, color: foreground),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  TextSpan _manuscriptSpan(ManuscriptContent content, Color color) => TextSpan(
    children: [
      for (final op in content.delta)
        if (op['insert'] is Map)
          WidgetSpan(
            child: Builder(
              builder: (context) {
                final uri = (op['insert'] as Map)['image'];
                if (uri is! String || !uri.startsWith('asset:')) {
                  return const Text('图片暂不可用');
                }
                return SizedBox(
                  width: (MediaQuery.sizeOf(context).width - 56).clamp(0, 704),
                  child: AssetImageView(assetId: uri.substring(6), height: 300),
                );
              },
            ),
          )
        else if (op['insert'] is String)
          TextSpan(
            text: op['insert'] as String,
            style: TextStyle(
              fontWeight: (op['attributes'] as Map?)?['bold'] == true
                  ? FontWeight.bold
                  : null,
              fontStyle: (op['attributes'] as Map?)?['italic'] == true
                  ? FontStyle.italic
                  : null,
              decoration: (op['attributes'] as Map?)?['underline'] == true
                  ? TextDecoration.underline
                  : null,
            ),
          ),
    ],
  );
}
