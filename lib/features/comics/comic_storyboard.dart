import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../illustrations/asset_image.dart';
import 'comic_canvas.dart' show comicModels, comicTaskPage;
import 'comic_dialogs.dart';
import 'comic_editor.dart';
import 'comic_reader.dart';

/// One page's storyboard as the author edits it: its panels in order and its
/// manual references (empty means automatic). [base] is the page as it was
/// when the draft began, so a save can tell whether it changed elsewhere.
class _Draft {
  _Draft(this.panels, this.references) : base = _form(panels, references);

  /// The page as [page] holds it, reading [panels] decoded once per build.
  factory _Draft.of(
    Map<String, dynamic> page,
    List<Map<String, dynamic>> panels,
  ) {
    final ids = page['panelIds'] as List;
    // Pages cover panels in order, so this keeps the page's order.
    return _Draft([
      for (final p in panels)
        if (ids.contains(p['id'])) p,
    ], List<String>.from(page['referenceAssetIds'] as List));
  }

  final List<Map<String, dynamic>> panels;
  final List<String> references;
  final String base;
  bool get dirty => _form(panels, references) != base;

  static String _form(List panels, List references) =>
      canonicalJson([panels, references]);

  ComicDocument applyTo(ComicDocument doc, String pageId) {
    final next = doc.editPage(pageId, panels);
    return ComicDocument.fromJson({
      ...next.toJson(),
      'pages': [
        for (final p in next.pages)
          p['id'] == pageId ? {...p, 'referenceAssetIds': references} : p,
      ],
    });
  }
}

/// A work's unsaved comic edits, kept outside the widgets that show them:
/// crossing the 900 px breakpoint remounts the canvas and the storyboard.
class ComicDrafts {
  /// Storyboard drafts by branch, episode and page.
  final _pages = <String, _Draft>{};

  /// The canvas field's text by branch and episode.
  final instructions = <String, String>{};
}

/// By novel id, for the whole session.
final comicDraftsProvider = Provider.family<ComicDrafts, String>(
  (ref, novelId) => ComicDrafts(),
);

/// The drafts of the work [branchId] belongs to; null until its story loads.
ComicDrafts? comicDraftsOf(WidgetRef ref, String branchId) =>
    switch (ref.read(storyProvider(branchId)).value?.novel.id) {
      final id? => ref.read(comicDraftsProvider(id)),
      null => null,
    };

/// The storyboard of one page of an original comic. Edits stay in a local
/// draft until saved; nothing is editable while the episode is drawing.
class ComicStoryboard extends ConsumerStatefulWidget {
  const ComicStoryboard({
    super.key,
    required this.branchId,
    required this.chapterId,
    this.pageId,
    this.embedded = false,
  });
  final String branchId, chapterId;

  /// The page to show; null (or a page that is gone) means the last page.
  final String? pageId;
  final bool embedded;
  @override
  ConsumerState<ComicStoryboard> createState() => _ComicStoryboardState();
}

class _ComicStoryboardState extends ConsumerState<ComicStoryboard> {
  // Keyed by episode and page in the work's drafts: switching pages or
  // layouts never drops an edit. The body waits for the story, so edits
  // never land in the empty stand-in.
  Map<String, _Draft> get _drafts =>
      comicDraftsOf(ref, widget.branchId)?._pages ?? {};
  bool _busy = false;

  String _key(String pageId) =>
      '${widget.branchId}/${widget.chapterId}/$pageId';

  void _change(String pageId, _Draft draft, void Function(_Draft) apply) =>
      setState(() => apply(_drafts[_key(pageId)] = draft));

  Future<void> _edit(
    ComicDocument doc,
    String pageId,
    _Draft draft,
    Map<String, dynamic>? panel,
  ) {
    // The editor sees the draft as this page's storyboard.
    final current = draft.applyTo(doc, pageId);
    return editComicPanel(
      context,
      document: current,
      panel: panel == null
          ? null
          : current.panels.firstWhere((p) => p['id'] == panel['id']),
      pageId: pageId,
      save: (next) async {
        if (!mounted) return;
        final edited = _Draft.of(
          next.pages.firstWhere((p) => p['id'] == pageId),
          next.panels,
        ).panels;
        _change(
          pageId,
          draft,
          (d) => d.panels
            ..clear()
            ..addAll(edited),
        );
      },
    );
  }

  Future<void> _references(String pageId, _Draft draft) async {
    final ids = await pickComicReferences(
      context,
      branchId: widget.branchId,
      initial: draft.references,
    );
    // Picks live in the draft, so a failed save keeps them.
    if (ids == null || !mounted) return;
    _change(
      pageId,
      draft,
      (d) => d.references
        ..clear()
        ..addAll(ids),
    );
  }

  Future<bool> _confirmDiscard() => confirmAction(
    context,
    title: '放弃未保存的分镜修改？',
    confirmLabel: '放弃修改',
    destructive: true,
  );

  Future<void> _discard(String pageId) async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() => _drafts.remove(_key(pageId)));
  }

  /// Leaving drops the drafts [mine] picks, so it asks first. Embedded, the
  /// route is the host's: discarding only clears the drafts and never pops it.
  Future<void> _leave(bool Function(String key) mine) async {
    if (!await _confirmDiscard() || !mounted) return;
    setState(() => _drafts.removeWhere((key, _) => mine(key)));
    if (widget.embedded) return;
    // Pop once the scope has rebuilt and lets it through.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.maybePop(context);
  }

  /// Asks before leaving drops a draft: any of the work's for the pane
  /// beside the canvas, which shows them all over time; only [key]'s for a
  /// full-screen page, which can neither show nor save the others.
  Widget _guard(String? key, Widget child) {
    bool mine(String k) => key == null || k == key;
    bool dirty() => _drafts.entries.any((e) => mine(e.key) && e.value.dirty);
    return PopScope(
      canPop: !dirty(),
      // Every scope of the route hears a blocked pop, including ones the
      // host blocked for its own reasons: ask only when there is something
      // to lose.
      onPopInvokedWithResult: (popped, _) {
        if (!popped && dirty()) _leave(mine);
      },
      child: child,
    );
  }

  Future<void> _save(String pageId, int number, {required bool redraw}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final services = ref.read(servicesProvider);
      // A missing connection saves nothing, so the draft stays as it is.
      final models = redraw
          ? await comicModels(
              services,
              missing: (name) {
                if (name != null && mounted) showError(context, name);
              },
            )
          : null;
      if (redraw && models == null) return;
      final repo = services.repository;
      var head = await repo.getComic(widget.branchId, widget.chapterId);
      if (head == null) throw const ComicConflict();
      final key = _key(pageId), draft = _drafts[key];
      if (draft != null && draft.dirty) {
        // Newer writes elsewhere in the episode are fine; a newer storyboard
        // of this page is not overwritten.
        final page = head.document.pages
            .where((p) => p['id'] == pageId)
            .firstOrNull;
        if (page == null ||
            _Draft.of(page, head.document.panels).base != draft.base) {
          throw const ComicConflict();
        }
        head = await repo.saveComic(
          branchId: widget.branchId,
          chapterId: widget.chapterId,
          document: draft.applyTo(head.document, pageId),
          expectedRevisionId: head.id,
          reason: '编辑第 $number 页分镜',
        );
        _drafts.remove(key);
      }
      if (models != null) {
        await services.comics.generateImages(
          branchId: widget.branchId,
          chapterId: widget.chapterId,
          connection: models.$2,
          promptConnection: models.$1,
          nsfwConnection: await services.connectionFor('imageNsfw'),
          panelId: pageId,
          expectedRevisionId: head.id,
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = _scaffold(context);
    // Full screen guards its page where the page is known, in the body.
    return widget.embedded ? _guard(null, scaffold) : scaffold;
  }

  Widget _scaffold(BuildContext context) => PageScaffold(
    title: '分镜',
    embedded: widget.embedded,
    body: AsyncView(
      value: ref.watch(comicProvider((widget.branchId, widget.chapterId))),
      builder: (data) {
        if (!ref.watch(storyProvider(widget.branchId)).hasValue) {
          return const SizedBox.shrink();
        }
        final theme = context.theme;
        final muted = theme.typography.body.sm.copyWith(
          color: theme.colors.mutedForeground,
        );
        final tasks = ref.watch(tasksProvider(widget.branchId));
        final active = [
          for (final t in tasks.value ?? <GenerationTask>[])
            if (t.kind == TaskKind.comic &&
                t.isActive &&
                (t.input['comicHeads'] as Map? ?? {}).containsKey(
                  widget.chapterId,
                ))
              t,
        ];
        // Suggesting directions is not drawing: it only blocks a redraw.
        final drawing = active
            .where((t) => t.input['comicAction'] != 'directions')
            .firstOrNull;
        // Every document getter decodes the whole JSON again: read each once.
        final doc = data.comic?.document;
        final pages = doc?.pages ?? <Map<String, dynamic>>[];
        final all = doc?.panels ?? <Map<String, dynamic>>[];
        String? locked;
        if (drawing != null) {
          final target = comicTaskPage(drawing, pages);
          final i = pages.indexWhere((p) => p['id'] == target);
          locked = target == null
              ? '正在处理本话，完成后可以编辑'
              : '正在画第 ${i < 0 ? pages.length + 1 : i + 1} 页，画完后可以编辑';
        }
        if (doc == null || pages.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(locked ?? '画好第一页后在这里改分镜'),
            ),
          );
        }
        final index = pages.indexWhere((p) => p['id'] == widget.pageId);
        final page = pages[index < 0 ? pages.length - 1 : index];
        final id = page['id'] as String, number = pages.indexOf(page) + 1;
        final saved = _drafts[_key(id)];
        final draft = saved != null && saved.dirty
            ? saved
            : _Draft.of(page, all);
        final dirty = draft.dirty;
        // AI hints belong to the newest page; the next check replaces them.
        final hints = id == pages.last['id'] ? doc.auditIssues : <String>[];
        final editable = locked == null && !_busy;
        final count = draft.panels.length;
        void change(void Function(_Draft) apply) => _change(id, draft, apply);
        final body = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 16,
                  children: [
                    Text(
                      '第 $number 页分镜',
                      style: theme.typography.body.lg.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (locked != null) Text(locked, style: muted),
                    if (hints.isNotEmpty)
                      FAccordion(
                        children: [
                          FAccordionItem(
                            title: Text('AI 提示 ${hints.length}'),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              spacing: 8,
                              children: [for (final h in hints) Text(h)],
                            ),
                          ),
                        ],
                      ),
                    for (final (i, panel) in draft.panels.indexed)
                      FCard(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 16,
                            children: [
                              ComicPanelView(
                                panel: panel,
                                number: i + 1,
                                details: true,
                                storyboardOnly: true,
                              ),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  comicButton(
                                    '编辑',
                                    editable
                                        ? () => _edit(doc, id, draft, panel)
                                        : null,
                                  ),
                                  comicButton(
                                    '上移',
                                    editable && i > 0
                                        ? () => change(
                                            (d) => d.panels.insert(
                                              i - 1,
                                              d.panels.removeAt(i),
                                            ),
                                          )
                                        : null,
                                  ),
                                  comicButton(
                                    '下移',
                                    editable && i < count - 1
                                        ? () => change(
                                            (d) => d.panels.insert(
                                              i + 1,
                                              d.panels.removeAt(i),
                                            ),
                                          )
                                        : null,
                                  ),
                                  // A page keeps at least one panel; deleting
                                  // the page is on the canvas.
                                  comicButton(
                                    '删除',
                                    editable && count > 1
                                        ? () => change(
                                            (d) => d.panels.removeAt(i),
                                          )
                                        : null,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: comicButton(
                        '添加一格',
                        editable ? () => _edit(doc, id, draft, null) : null,
                      ),
                    ),
                    FAccordion(
                      children: [
                        FAccordionItem(
                          title: const Text('本页参考图'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            spacing: 12,
                            children: [
                              if (draft.references.isEmpty)
                                const Text('自动：角色定妆图 + 上一页')
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final (i, asset)
                                        in draft.references.indexed)
                                      AssetImageView(
                                        assetId: asset,
                                        width: 64,
                                        height: 64,
                                        label: '参考图 ${i + 1}',
                                      ),
                                  ],
                                ),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: comicButton(
                                  '修改参考图',
                                  editable
                                      ? () => _references(id, draft)
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    // Any comic task of this episode would refuse the redraw.
                    onPress: editable && tasks.hasValue && active.isEmpty
                        ? () => _save(id, number, redraw: true)
                        : null,
                    child: const Text('保存并重画本页（1 张图）'),
                  ),
                  comicButton(
                    '只保存',
                    editable && dirty
                        ? () => _save(id, number, redraw: false)
                        : null,
                  ),
                  // A storyboard changed elsewhere refuses the save; this is
                  // the way back to it.
                  if (dirty)
                    comicButton('放弃修改', editable ? () => _discard(id) : null),
                ],
              ),
            ),
          ],
        );
        return widget.embedded ? body : _guard(_key(id), body);
      },
    ),
  );
}
