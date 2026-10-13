import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show MaterialPageRoute, SelectionArea;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../agent/agent_providers.dart';
import '../agent/task_screen.dart';
import '../agent/writing_request_screen.dart';
import '../html/html_block_view.dart';
import '../html/tavern_host.dart';
import 'reader_document.dart';
import 'reader_settings.dart';
import 'reader_style.dart';
import 'next_chapter.dart';
import 'story_directions.dart';
import '../illustrations/asset_image.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../app/widgets.dart';

final _revisionPresentationProvider =
    FutureProvider.family<ManuscriptPresentation, String>(
      (ref, id) => ref.watch(repositoryProvider).presentRevision(id),
    );
typedef _ReaderBook = ({
  StorySnapshot story,
  List<ManuscriptPresentation> pages,
  DisplayContext display,
});
final _readerStoryProvider = FutureProvider.family<_ReaderBook, String>((
  ref,
  branchId,
) async {
  final story = await ref.watch(storyProvider(branchId).future);
  final pages = await Future.wait(
    story.scenes.map(
      (s) => ref.watch(_revisionPresentationProvider(s.revisionId).future),
    ),
  );
  final display = await ref.watch(repositoryProvider).displayContext(branchId);
  return (story: story, pages: pages, display: display);
});

/// Characters a reader gets through per minute, for time-left estimates.
const _charactersPerMinute = 500;

String _sceneTitle(Scene scene) => scene.title.isEmpty ? '未命名场景' : scene.title;

/// The book reader: an immersive page with the controls tucked away. Tap the
/// middle to show them; tap the sides (or use the keyboard) to turn pages.
///
/// [embedded] makes it a pane inside the workspace: the bars stay, it does
/// not grab keyboard focus, [sceneId] follows the outline selection and
/// [onSceneChanged] reports page turns back, so the outline and the reader
/// are one view of the manuscript.
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({
    super.key,
    required this.branchId,
    this.embedded = false,
    this.sceneId,
    this.onSceneChanged,
    this.onEdit,
  });
  final String branchId;
  final bool embedded;

  /// The scene to show; null opens where reading last stopped.
  final String? sceneId;
  final ValueChanged<Scene>? onSceneChanged;

  /// Shows an edit action for the scene being read.
  final ValueChanged<Scene>? onEdit;
  @override
  ConsumerState<ReaderScreen> createState() => _ReaderState();
}

class _ReaderState extends ConsumerState<ReaderScreen>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();

  /// Bumped when the page's height changes, e.g. a new scene is laid out,
  /// so progress is recomputed even though the offset did not move.
  final _metrics = ValueNotifier(0);
  final _textKey = GlobalKey(), _viewportKey = GlobalKey();
  final _pageKey = GlobalKey(), _textAreaKey = GlobalKey();
  final _topBarKey = GlobalKey(), _bottomBarKey = GlobalKey();

  /// How far the bars reach over the text, measured after layout: the text
  /// keeps that much room at both ends, so its start and end can always be
  /// scrolled clear of the bars.
  EdgeInsets _barOverlap = EdgeInsets.zero;
  late final AppServices _services;
  late final Ticker _ticker = createTicker(_autoScrollTick);
  Timer? _timer, _saveStyle;
  int _index = 0;
  ReaderStyle _style = const ReaderStyle();
  bool _initialized = false;
  bool _displayRules = true;

  /// Whether the top and bottom bars are showing.
  bool _chrome = true;
  bool _hasSelection = false;
  Duration? _lastTick;

  /// Scene picked on the progress slider but not yet opened.
  double? _seeking;

  // Tap detection that does not compete with text selection gestures.
  Offset? _down;
  DateTime? _downAt;
  bool _consumed = false;

  StorySnapshot? _story;
  ReaderDocument? _document;

  /// Whether [_style] holds the stored setting yet, not the defaults.
  bool _styleLoaded = false;

  /// A scene to turn to once the story includes it: a chapter just started.
  String? _openWhenLoaded;

  /// Relays events between the HTML blocks of the scene being read.
  final _bus = HtmlEventBus();

  bool get _mobile =>
      !kIsWeb &&
      !widget.embedded &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// The page colours in use: night when the app is dark and the author
  /// lets the reader follow it.
  ReaderTheme get _pageTheme =>
      _style.effectiveTheme(context.theme.colors.brightness);

  @override
  void didUpdateWidget(ReaderScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.sceneId;
    if (target == null || target == oldWidget.sceneId) return;
    final index = _story?.scenes.indexWhere((s) => s.id == target) ?? -1;
    if (index >= 0 && index != _index) _go(index);
  }

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
    _saveStyle?.cancel();
    _ticker.dispose();
    _services.unregisterDraft(this);
    _scroll.dispose();
    _metrics.dispose();
    _awake(false);
    if (_mobile) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  void _awake(bool on) =>
      unawaited(WakelockPlus.toggle(enable: on).catchError((Object _) {}));

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
    final index = story.scenes.indexWhere(
      (s) => s.id == (widget.sceneId ?? progress?['sceneId']),
    );
    setState(() {
      _style = ReaderStyle.fromJson(prefs);
      _styleLoaded = true;
      if (index >= 0) _index = index;
    });
    // Only a remembered place counts as a choice; starting at the first
    // scene for lack of one must not make the outline treat it as picked.
    if (widget.onSceneChanged != null && index >= 0) {
      final shown = story.scenes[index];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onSceneChanged!(shown);
      });
    }
    _awake(_style.keepAwake);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(
          _scroll.position.maxScrollExtent *
              (progress?['fraction'] as num? ?? 0).toDouble().clamp(0, 1),
        );
      }
    });
  }

  void _setStyle(ReaderStyle style) {
    if (style.keepAwake != _style.keepAwake) _awake(style.keepAwake);
    setState(() => _style = style);
    _saveStyle?.cancel();
    _saveStyle = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(
        ref
            .read(repositoryProvider)
            .setSetting('reader', style.toJson())
            .catchError((Object e) {
              if (mounted) showError(context, e);
            }),
      ),
    );
  }

  void _showChrome(bool show) {
    // A pane keeps its bars; only the full-screen reader tucks them away.
    if (widget.embedded && !show) return;
    if (show == _chrome) return;
    setState(() => _chrome = show);
    if (_mobile) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          show ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
        ),
      );
    }
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
    final offset = paragraph
        .getPositionForOffset(Offset(0, top.dy.clamp(0, paragraph.size.height)))
        .offset;
    return _document?.sourceOffset(offset) ?? offset;
  }

  /// Opens scene [index], at its start, at [offset] in its text, or at its
  /// end when paging backwards into it.
  void _go(int index, {int offset = 0, bool atEnd = false}) {
    if (_story == null || index < 0 || index >= _story!.scenes.length) return;
    setState(() {
      _index = index;
      _seeking = null;
    });
    widget.onSceneChanged?.call(_story!.scenes[index]);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (offset > 0 || atEnd) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (atEnd) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
          return;
        }
        final paragraph = _paragraph;
        final viewport = _viewportKey.currentContext?.findRenderObject();
        if (paragraph == null || viewport is! RenderBox) return;
        final caret = paragraph.getOffsetForCaret(
          TextPosition(
            offset:
                _document?.displayOffset(offset) ??
                offset.clamp(0, _story!.scenes[index].content.text.length),
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

  /// One screen forwards or backwards, keeping a line and a half of overlap;
  /// past either end of a scene, on into the next or previous one.
  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final step = math.max(
      position.viewportDimension * .5,
      position.viewportDimension - _style.fontSize * _style.lineHeight * 1.5,
    );
    final last = (_story?.scenes.length ?? 1) - 1;
    if (direction > 0) {
      if (position.pixels >= position.maxScrollExtent - 1) {
        if (_index < last) _go(_index + 1);
      } else {
        unawaited(
          _scroll.animateTo(
            math.min(position.pixels + step, position.maxScrollExtent),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    } else {
      if (position.pixels <= 1) {
        if (_index > 0) _go(_index - 1, atEnd: true);
      } else {
        unawaited(
          _scroll.animateTo(
            math.max(0, position.pixels - step),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    }
    _showChrome(false);
  }

  void _toggleAutoScroll() {
    if (_ticker.isActive) {
      _ticker.stop();
      _lastTick = null;
      setState(() {});
    } else {
      _ticker.start();
      _showChrome(false);
      setState(() {});
    }
  }

  void _autoScrollTick(Duration elapsed) {
    final previous = _lastTick;
    _lastTick = elapsed;
    if (previous == null || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - .5) {
      final last = (_story?.scenes.length ?? 1) - 1;
      if (_index < last) {
        _go(_index + 1);
      } else {
        _toggleAutoScroll();
      }
      return;
    }
    final seconds = (elapsed - previous).inMicroseconds / 1e6;
    _scroll.jumpTo(
      math.min(
        position.pixels + _style.autoScrollSpeed * seconds,
        position.maxScrollExtent,
      ),
    );
  }

  void _pointerDown(PointerDownEvent event) {
    _down = event.position;
    _downAt = DateTime.now();
  }

  /// A quick tap that is not part of selecting text, scrolling or pressing a
  /// button shows or hides the bars.
  void _pointerUp(PointerUpEvent event, double width) {
    final consumed = _consumed;
    _consumed = false;
    final down = _down, at = _downAt;
    if (consumed || down == null || at == null) return;
    if ((event.position - down).distance > 12 ||
        DateTime.now().difference(at) > const Duration(milliseconds: 400) ||
        _hasSelection) {
      return;
    }
    if (_ticker.isActive) {
      _toggleAutoScroll();
      _showChrome(true);
      return;
    }
    _showChrome(!_chrome);
  }

  /// Wraps controls inside the page so tapping them does not also toggle the bars.
  Widget _noTurn(Widget child) =>
      Listener(onPointerDown: (_) => _consumed = true, child: child);

  Future<void> _preferences() async {
    _showChrome(false);
    await showReaderSettings(context, style: _style, onChanged: _setStyle);
  }

  Future<void> _contents(StorySnapshot story) async {
    // Imported books have one scene per chapter with the same name; show
    // those as one row.
    final rows = <({String title, int? scene, bool header})>[];
    for (final chapter in story.chapters) {
      final scenes = story.scenesInChapter(chapter.id);
      if (scenes.length == 1 &&
          (scenes.single.title == chapter.title ||
              scenes.single.title.isEmpty)) {
        rows.add((
          title: chapter.title,
          scene: story.scenes.indexOf(scenes.single),
          header: false,
        ));
        continue;
      }
      rows.add((title: chapter.title, scene: null, header: true));
      for (final s in scenes) {
        rows.add((
          title: _sceneTitle(s),
          scene: story.scenes.indexOf(s),
          header: false,
        ));
      }
    }
    const extent = 52.0;
    final current = rows.indexWhere((r) => r.scene == _index);
    final nested = rows.any((r) => r.header);
    await showAppSheet<void>(
      context: context,
      builder: (context) {
        final theme = context.theme;
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * .75,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '目录',
                        style: theme.typography.body.lg.copyWith(
                          color: theme.colors.foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '共 ${story.chapters.length} 章',
                      style: theme.typography.body.xs.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              const FDivider(),
              Expanded(
                child: ListView.builder(
                  // Thousands of chapters: build only what is visible and
                  // open on the one being read.
                  controller: ScrollController(
                    initialScrollOffset: math.max(0, (current - 3) * extent),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemExtent: extent,
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    if (row.header) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.typography.body.sm.copyWith(
                              color: theme.colors.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    }
                    final here = row.scene == _index;
                    return Padding(
                      padding: EdgeInsetsDirectional.only(
                        start: nested ? 16 : 0,
                      ),
                      child: Align(
                        child: FItem(
                          selected: here,
                          title: Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          suffix: here
                              ? const Icon(FLucideIcons.bookOpen, size: 18)
                              : null,
                          onPress: () {
                            _go(row.scene!);
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _snippet(Scene? scene, int offset) {
    if (scene == null) return '';
    final text = scene.content.text;
    final start = offset.clamp(0, text.length);
    return text
        .substring(start, math.min(text.length, start + 60))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _bookmarks(StorySnapshot story) async {
    _showChrome(false);
    final bookmarks = await ref
        .read(repositoryProvider)
        .listBookmarks(story.branch.id);
    if (!mounted) return;
    final scenes = {for (final s in story.scenes) s.id: s};
    await showAppSheet<void>(
      context: context,
      mainAxisMaxRatio: .7,
      builder: (context) {
        final theme = context.theme;
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '书签',
                      style: theme.typography.body.lg.copyWith(
                        color: theme.colors.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FButton(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () async {
                      final scene = story.scenes[_index];
                      await ref
                          .read(repositoryProvider)
                          .addBookmark(
                            branchId: story.branch.id,
                            sceneId: scene.id,
                            label: _sceneTitle(scene),
                            offset: _currentTextOffset(),
                          );
                      if (context.mounted) Navigator.pop(context);
                    },
                    prefix: const Icon(FLucideIcons.bookmarkPlus),
                    child: const Text('添加当前位置'),
                  ),
                ],
              ),
            ),
            if (bookmarks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '还没有书签。读到想回来的地方，添加一个。',
                  style: TextStyle(color: theme.colors.mutedForeground),
                ),
              ),
            for (final mark in bookmarks)
              FItem(
                prefix: const Icon(FLucideIcons.bookmark),
                title: Text(mark.label),
                subtitle: Text(
                  '${_snippet(scenes[mark.sceneId], mark.offset)}\n${dateLabel(mark.createdAt)}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onPress: () {
                  _go(
                    story.scenes.indexWhere((s) => s.id == mark.sceneId),
                    offset: mark.offset,
                  );
                  Navigator.pop(context);
                },
                suffix: IconAction(
                  tooltip: '删除书签',
                  icon: FLucideIcons.x,
                  onPress: () async {
                    await ref.read(repositoryProvider).removeBookmark(mark.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _search(StorySnapshot story) async {
    final query = await askText(context, title: '搜索正文', label: '关键词');
    if (query == null || query.isEmpty || !mounted) return;
    final matches = story.scenes
        .where((s) => s.content.text.contains(query))
        .toList();
    await showAppSheet<void>(
      context: context,
      title: '找到 ${matches.length} 个场景',
      mainAxisMaxRatio: .7,
      builder: (context) => ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        itemCount: matches.length,
        itemBuilder: (context, i) {
          final scene = matches[i];
          final text = scene.content.text, at = text.indexOf(query);
          final count = query.allMatches(text).length;
          return FItem(
            title: Text(
              count > 1
                  ? '${_sceneTitle(scene)} · $count 处'
                  : _sceneTitle(scene),
            ),
            subtitle: Text(
              text.substring(math.max(0, at - 20)).replaceAll('\n', ' '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onPress: () {
              _go(story.scenes.indexOf(scene), offset: at);
              Navigator.pop(context);
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AsyncView(
    value: ref.watch(_readerStoryProvider(widget.branchId)),
    builder: (book) {
      final story = book.story;
      _story = story;
      if (!_initialized) unawaited(_initialize(story));
      if (_openWhenLoaded case final id?) {
        final at = story.scenes.indexWhere((s) => s.id == id);
        if (at >= 0) {
          _openWhenLoaded = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _go(at);
          });
        }
      }
      final theme = _pageTheme;
      final background = theme.background, foreground = theme.foreground;
      if (story.scenes.isEmpty) {
        return PageScaffold(
          title: story.novel.title,
          body: const Center(child: Text('这部作品还没有正文。')),
        );
      }
      _index = _index.clamp(0, story.scenes.length - 1);
      final scene = story.scenes[_index];
      final htmlEnabled =
          ref.watch(settingProvider('html')).value?['render'] != false;
      _document = ReaderDocument.build(
        _displayRules
            ? book.pages[_index]
            : ManuscriptPresentation.identity(scene.content),
        fontSize: _style.fontSize,
        paragraphSpacing: _style.paragraphSpacing,
        indent: _style.indent,
        quoteColor: _style.highlightQuotes ? theme.quote : null,
        italicColor: _style.dimItalics ? theme.italic : null,
        html: htmlEnabled
            ? (block, index) => _htmlBlock(book, scene, block, index)
            : null,
        image: (uri) {
          if (uri == null || !uri.startsWith('asset:')) {
            return const Text('图片暂不可用');
          }
          return SizedBox(
            width: (MediaQuery.sizeOf(context).width - _style.margin * 2).clamp(
              0,
              704,
            ),
            child: AssetImageView(assetId: uri.substring(6), height: 300),
          );
        },
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _measureBars();
      });
      // Where each scene starts in the whole book, for overall progress.
      final lengths = [for (final s in story.scenes) s.content.text.length];
      final before = lengths.take(_index).fold(0, (a, b) => a + b);
      final total = math.max(1, lengths.fold(0, (a, b) => a + b));
      final chapter = story.chapters
          .where((c) => c.id == scene.chapterId)
          .firstOrNull;
      final sameTitle = chapter == null || chapter.title == scene.title;
      // The controls follow the page: light chrome on a light page, dark on
      // a dark one, whatever the rest of the app uses.
      final ui = appTheme(theme.dark ? Brightness.dark : Brightness.light);
      return FTheme(
        data: ui,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
                _search(story),
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                _search(story),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _page(1),
            const SingleActivator(LogicalKeyboardKey.pageDown): () => _page(1),
            const SingleActivator(LogicalKeyboardKey.space): () => _page(1),
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _page(-1),
            const SingleActivator(LogicalKeyboardKey.pageUp): () => _page(-1),
            const SingleActivator(LogicalKeyboardKey.space, shift: true): () =>
                _page(-1),
          },
          child: Focus(
            autofocus: !widget.embedded,
            child: PopScope(
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
              child: AppScaffold(
                child: ColoredBox(
                  key: const Key('reader-page'),
                  color: background,
                  child: Stack(
                    key: _pageKey,
                    children: [
                      Positioned.fill(
                        child: DefaultTextStyle.merge(
                          style: TextStyle(color: foreground),
                          child: IconTheme.merge(
                            data: IconThemeData(color: foreground),
                            child: _reading(
                              story,
                              scene,
                              chapter,
                              sameTitle,
                              foreground,
                              before,
                              total,
                            ),
                          ),
                        ),
                      ),
                      if (_style.dim > 0)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ColoredBox(
                              color: const Color(0xFF000000)
                                  .withValues(alpha: _style.dim),
                            ),
                          ),
                        ),
                      _topBar(story, book, scene, background, ui),
                      _bottomBar(story, background, ui),
                      if (_ticker.isActive)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 24,
                          child: SafeArea(
                            child: Center(child: _autoScrollPill(ui)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  /// An HTML block of the scene: a web view the page's scripts drive
  /// through the 酒馆助手-style bridge. Taps inside it never turn pages.
  Widget _htmlBlock(_ReaderBook book, Scene scene, HtmlBlock block, int index) {
    final width = (MediaQuery.sizeOf(context).width - _style.margin * 2).clamp(
      0.0,
      704.0,
    );
    final bridge = block.kind == HtmlBlockKind.frontend
        ? TavernBridge(
            backend: BranchChatBackend(
              repository: _services.repository,
              branchId: widget.branchId,
              context: book.display,
            ),
            actions: FlutterTavernHost(
              context: () => context,
              bus: _bus,
              onWritingRequest: _onWritingRequest,
            ),
            messageId: _index,
            blockIndex: index,
          )
        : null;
    return _noTurn(
      HtmlBlockView(
        key: ValueKey('html:${scene.id}:$index:${block.source.hashCode}'),
        block: block,
        width: width,
        bridge: bridge,
        bus: _bus,
      ),
    );
  }

  /// A page asked for text to be sent or generation to start (`/send`,
  /// `/trigger`, `/cut`). The author sees the request first; `/cut` of a
  /// scene becomes a rewrite of that scene so the interface can replace
  /// itself with prose.
  Future<void> _onWritingRequest(TavernWritingRequest request) async {
    final story = _story;
    if (story == null || story.scenes.isEmpty || !mounted) return;
    final target = request.rewriteMessageId;
    final scene = target == null
        ? story.scenes.last
        : story.scenes[(target < 0 ? story.scenes.length + target : target)
              .clamp(0, story.scenes.length - 1)];
    _showChrome(true);
    final task = await Navigator.push<GenerationTask>(
      context,
      MaterialPageRoute(
        builder: (_) => WritingRequestScreen(
          scene: scene,
          initialBrief: request.brief,
          rewrite: target != null,
        ),
      ),
    );
    if (task != null && mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
      );
    }
  }

  /// The page itself: running header, the text, and a running footer with
  /// progress and the time, like a printed book.
  Widget _reading(
    StorySnapshot story,
    Scene scene,
    Chapter? chapter,
    bool sameTitle,
    Color foreground,
    int before,
    int total,
  ) {
    final faint = foreground.withValues(alpha: .5);
    final small = TextStyle(color: faint, fontSize: 12);
    final last = _index == story.scenes.length - 1;
    // An empty scene being written shows the text as it arrives; while it
    // is written, or waits to be taken in, the story has no end to offer.
    final draft = scene.content.text.trim().isNotEmpty
        ? null
        : (ref.watch(tasksProvider(widget.branchId)).value ?? const [])
              .where(
                (t) =>
                    [TaskKind.writing, TaskKind.rewrite].contains(t.kind) &&
                    t.sceneId == scene.id,
              )
              .firstOrNull;
    final writing =
        draft != null &&
        (draft.isActive ||
            (ref.watch(proposalsProvider(widget.branchId)).value ?? const [])
                .any(
                  (p) =>
                      p.id == draft.result['proposalId'] &&
                      p.status == ProposalStatus.pending,
                ));
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(_style.margin, 6, _style.margin, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    sameTitle ? _sceneTitle(scene) : chapter!.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: small,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is UserScrollNotification &&
                    n.direction != ScrollDirection.idle) {
                  _showChrome(false);
                }
                return false;
              },
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  _metrics.value++;
                  return false;
                },
                child: LayoutBuilder(
                  builder: (context, constraints) => Listener(
                    key: _textAreaKey,
                    // Blank page below a short scene turns pages too.
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _pointerDown,
                    onPointerUp: (e) => _pointerUp(e, constraints.maxWidth),
                    child: SelectionArea(
                      onSelectionChanged: (content) =>
                          _hasSelection = content?.plainText.isNotEmpty == true,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: 704 + _style.margin * 2,
                          ),
                          child: SingleChildScrollView(
                            key: _viewportKey,
                            controller: _scroll,
                            padding: EdgeInsets.fromLTRB(
                              _style.margin,
                              24 + _barOverlap.top,
                              _style.margin,
                              48 + _barOverlap.bottom,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (!sameTitle) ...[
                                  Text(
                                    chapter!.title,
                                    style: TextStyle(
                                      color: foreground.withValues(alpha: .6),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ],
                                Text(
                                  _sceneTitle(scene),
                                  style: TextStyle(
                                    fontSize: _style.fontSize + 6,
                                    fontWeight: FontWeight.w600,
                                    color: foreground,
                                    fontFamily: _style.font.family,
                                    fontFamilyFallback: _style.font.fallback,
                                  ),
                                ),
                                SizedBox(height: _style.fontSize * 1.5),
                                if (draft != null)
                                  ChapterDraft(
                                    key: ValueKey('draft:${draft.id}'),
                                    task: draft,
                                    prose: (text) => _prose(text, foreground),
                                    controls: _noTurn,
                                  )
                                else
                                  Text.rich(
                                    _document!.span,
                                    key: _textKey,
                                    textAlign: _style.justify
                                        ? TextAlign.justify
                                        : TextAlign.start,
                                    style: _style.body(foreground),
                                  ),
                                const SizedBox(height: 36),
                                if (!writing)
                                  Text(
                                    last ? '— 当前正文结束 —' : '— 本幕完 —',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: faint,
                                      fontSize: 13,
                                    ),
                                  ),
                                const SizedBox(height: 16),
                                if (!last)
                                  Center(
                                    child: _noTurn(
                                      FButton(
                                        key: const Key('reader-next-scene'),
                                        variant: FButtonVariant.secondary,
                                        mainAxisSize: MainAxisSize.min,
                                        onPress: () => _go(_index + 1),
                                        prefix: const Icon(
                                          FLucideIcons.arrowDown,
                                        ),
                                        child: Flexible(
                                          child: Text(
                                            '下一幕：${_sceneTitle(story.scenes[_index + 1])}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                else if (!writing) ...[
                                  const SizedBox(height: 16),
                                  _noTurn(
                                    StoryDirections(
                                      story: story,
                                      onOpenScene: (id) =>
                                          setState(() => _openWhenLoaded = id),
                                      // Not before the author's own setting
                                      // is known.
                                      auto:
                                          _styleLoaded && _style.autoDirections,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(_style.margin, 0, _style.margin, 6),
            child: ListenableBuilder(
              listenable: Listenable.merge([_scroll, _metrics]),
              builder: (context, _) {
                final fraction = _fraction();
                final scene = story.scenes[_index];
                final overall =
                    (before + fraction * scene.content.text.length) / total;
                return Row(
                  children: [
                    Text(
                      '全书 ${(overall * 100).toStringAsFixed(1)}%',
                      key: const Key('reader-progress'),
                      style: small,
                    ),
                    const Spacer(),
                    _Clock(style: small),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  double _fraction() {
    if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return 0;
    final max = _scroll.position.maxScrollExtent;
    return max <= 0 ? 1 : (_scroll.offset / max).clamp(0, 1);
  }

  /// Sets [text] the way the page sets the book.
  Widget _prose(String text, Color foreground) {
    final theme = _pageTheme;
    return Text.rich(
      ReaderDocument.build(
        ManuscriptPresentation.identity(ManuscriptContent.plainText(text)),
        fontSize: _style.fontSize,
        paragraphSpacing: _style.paragraphSpacing,
        indent: _style.indent,
        quoteColor: _style.highlightQuotes ? theme.quote : null,
        italicColor: _style.dimItalics ? theme.italic : null,
        image: (_) => const SizedBox.shrink(),
      ).span,
      textAlign: _style.justify ? TextAlign.justify : TextAlign.start,
      style: _style.body(foreground),
    );
  }

  /// Measures [_barOverlap] against the area the text scrolls in, which a
  /// short scene does not shrink, so the room is the same in every scene.
  /// Sizes are taken from layout, which the bars' slide does not change, so
  /// the room stays put as they come and go.
  void _measureBars() {
    RenderBox? box(GlobalKey key) {
      final object = key.currentContext?.findRenderObject();
      return object is RenderBox && object.hasSize ? object : null;
    }

    final page = box(_pageKey), viewport = box(_textAreaKey);
    if (page == null || viewport == null) return;
    final top = viewport.localToGlobal(Offset.zero, ancestor: page).dy;
    final bottom = page.size.height - top - viewport.size.height;
    final next = EdgeInsets.only(
      top: math.max(0, (box(_topBarKey)?.size.height ?? 0) - top),
      bottom: math.max(0, (box(_bottomBarKey)?.size.height ?? 0) - bottom),
    );
    if ((next.top - _barOverlap.top).abs() > .5 ||
        (next.bottom - _barOverlap.bottom).abs() > .5) {
      setState(() => _barOverlap = next);
    }
  }

  Widget _slideIn({required bool top, required Widget child}) => Positioned(
    left: 0,
    right: 0,
    top: top ? 0 : null,
    bottom: top ? null : 0,
    child: IgnorePointer(
      ignoring: !_chrome,
      child: ExcludeSemantics(
        excluding: !_chrome,
        child: AnimatedSlide(
          offset: _chrome ? Offset.zero : Offset(0, top ? -1 : 1),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: _chrome ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: child,
          ),
        ),
      ),
    ),
  );

  Widget _topBar(
    StorySnapshot story,
    _ReaderBook book,
    Scene scene,
    Color background,
    FThemeData ui,
  ) {
    final canPop =
        !widget.embedded &&
        (ModalRoute.of(context)?.impliesAppBarDismissal ?? false);
    return _slideIn(
      top: true,
      child: DecoratedBox(
        key: _topBarKey,
        decoration: BoxDecoration(
          color: background,
          border: Border(bottom: BorderSide(color: ui.colors.border)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: FHeader.nested(
          title: Text(
            widget.embedded ? _sceneTitle(scene) : story.novel.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          prefixes: [if (canPop) const AppBackButton()],
          suffixes: [
            if (widget.onEdit case final edit?)
              HeaderIconAction(
                key: const Key('reader-edit-scene'),
                tooltip: '编辑本幕',
                icon: FLucideIcons.pencil,
                onPress: () => edit(scene),
              ),
            HeaderIconAction(
              tooltip: '搜索正文',
              icon: FLucideIcons.search,
              onPress: () => _search(story),
            ),
            MenuAction(
              header: true,
              tooltip: '阅读设置',
              entries: [
                menuEntry('排版与主题', _preferences, icon: FLucideIcons.type),
                menuEntry(
                  '书签',
                  () => _bookmarks(story),
                  icon: FLucideIcons.bookmark,
                ),
                if (book.pages[_index].content != scene.content)
                  menuEntry(
                    _displayRules ? '显示原正文' : '应用显示正则',
                    () => setState(() => _displayRules = !_displayRules),
                    icon: _displayRules
                        ? FLucideIcons.eyeOff
                        : FLucideIcons.eye,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(StorySnapshot story, Color background, FThemeData ui) {
    final count = story.scenes.length;
    final seeking = _seeking;
    final shown = seeking?.round() ?? _index;
    final scene = story.scenes[_index];
    final left =
        ((1 - _fraction()) * scene.content.text.length / _charactersPerMinute)
            .ceil();
    final night = _pageTheme.dark;
    return _slideIn(
      top: false,
      child: DecoratedBox(
        key: _bottomBarKey,
        decoration: BoxDecoration(
          color: background,
          border: Border(top: BorderSide(color: ui.colors.border)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x14000000),
              blurRadius: 8,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  seeking != null
                      ? '${shown + 1} / $count · ${_sceneTitle(story.scenes[shown])}'
                      : '${_index + 1} / $count · 本幕约剩 ${math.max(left, 0)} 分钟',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ui.typography.body.xs.copyWith(
                    color: ui.colors.mutedForeground,
                  ),
                ),
                Row(
                  children: [
                    IconAction(
                      tooltip: '上一幕',
                      icon: FLucideIcons.chevronLeft,
                      onPress: _index > 0 ? () => _go(_index - 1) : null,
                    ),
                    Expanded(
                      child: count < 2
                          ? const SizedBox(height: 48)
                          : Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: ReaderSlider(
                                key: const Key('reader-seek'),
                                value: seeking ?? _index.toDouble(),
                                min: 0,
                                max: (count - 1).toDouble(),
                                divisions: count - 1,
                                semanticLabel: (v) =>
                                    '第 ${v.round() + 1} 幕，共 $count 幕',
                                onChanged: (v) => setState(() => _seeking = v),
                                onChangeEnd: (v) => _go(v.round()),
                              ),
                            ),
                    ),
                    IconAction(
                      tooltip: '下一幕',
                      icon: FLucideIcons.chevronRight,
                      onPress: _index < count - 1
                          ? () => _go(_index + 1)
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _BarAction(
                      icon: FLucideIcons.tableOfContents,
                      tooltip: '目录',
                      onPress: () => _contents(story),
                    ),
                    _BarAction(
                      icon: FLucideIcons.bookmark,
                      tooltip: '书签',
                      onPress: () => _bookmarks(story),
                    ),
                    _BarAction(
                      icon: night ? FLucideIcons.sun : FLucideIcons.moon,
                      tooltip: night ? '日间' : '夜间',
                      onPress: () => _setStyle(
                        _style.copyWith(
                          theme: night ? ReaderTheme.paper : ReaderTheme.night,
                          // Choosing explicitly overrides following the system.
                          autoNight: false,
                        ),
                      ),
                    ),
                    _BarAction(
                      icon: FLucideIcons.chevronsDown,
                      tooltip: '自动滚动',
                      onPress: _toggleAutoScroll,
                    ),
                    _BarAction(
                      icon: FLucideIcons.type,
                      tooltip: '排版与主题',
                      onPress: _preferences,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _autoScrollPill(FThemeData ui) {
    void speed(double delta) => _setStyle(
      _style.copyWith(
        autoScrollSpeed: (_style.autoScrollSpeed + delta).clamp(
          ReaderStyle.speedRange.min,
          ReaderStyle.speedRange.max,
        ),
      ),
    );
    return _noTurn(
      DecoratedBox(
        key: const Key('reader-autoscroll'),
        decoration: BoxDecoration(
          color: ui.colors.background,
          borderRadius: ui.style.borderRadius.pill,
          border: Border.all(color: ui.colors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconAction(
                tooltip: '减速',
                icon: FLucideIcons.minus,
                onPress: () => speed(-10),
              ),
              Text(
                '速度 ${_style.autoScrollSpeed.round()}',
                style: ui.typography.body.sm.copyWith(
                  color: ui.colors.foreground,
                ),
              ),
              IconAction(
                tooltip: '加速',
                icon: FLucideIcons.plus,
                onPress: () => speed(10),
              ),
              IconAction(
                tooltip: '停止自动滚动',
                icon: FLucideIcons.circleStop,
                onPress: _toggleAutoScroll,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the labelled buttons along the bottom of the reader: an icon over
/// its name, found in tests by that name like an [IconAction].
class _BarAction extends StatelessWidget implements ActionLabel {
  const _BarAction({
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });
  final IconData icon;
  @override
  final String tooltip;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Expanded(
      child: FTooltip(
        tipBuilder: (_, _) => Text(tooltip),
        child: FButton.raw(
          variant: FButtonVariant.ghost,
          onPress: onPress,
          semanticsLabel: tooltip,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: theme.colors.foreground),
                const SizedBox(height: 2),
                Text(
                  tooltip,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.typography.body.xs.copyWith(
                    color: theme.colors.foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The time of day in the running footer, updated each minute.
class _Clock extends StatefulWidget {
  const _Clock({required this.style});
  final TextStyle style;
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => setState(() {}),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Text(
      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      style: widget.style,
    );
  }
}
