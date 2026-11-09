import 'dart:math';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../agent/task_screen.dart';
import '../bookshelf/novel_dialog.dart';
import '../illustrations/asset_image.dart';
import '../reader/reader_screen.dart';
import '../settings/settings_screen.dart';
import 'comic_dialogs.dart';
import 'comic_editor.dart';
import 'comic_reader.dart';
import 'comic_screen.dart';
import 'comic_storyboard.dart';

part 'comic_canvas_parts.dart';

/// Character lore visible at a chapter, refreshed with content changes.
final _castProvider = FutureProvider.family<List<LoreEntry>, (String, String)>((
  ref,
  key,
) {
  ref.watch(repositoryContentChangesProvider);
  return ref
      .watch(repositoryProvider)
      .listLore(key.$1, throughChapterId: key.$2, kind: LoreKind.character);
});

/// For an opening: the previous episode's original comic revision, and
/// whether any earlier episode is an original (then no character sheets).
// ponytail: reads every earlier episode's head; only the opening watches it.
final _priorProvider =
    FutureProvider.family<
      ({String? previousHead, bool earlierOriginal}),
      (String, String)
    >((ref, key) async {
      ref.watch(repositoryContentChangesProvider);
      final repo = ref.watch(repositoryProvider);
      final chapters = (await repo.getStory(key.$1)).chapters;
      final index = chapters.indexWhere((c) => c.id == key.$2);
      String? previousHead;
      var earlierOriginal = false;
      for (final (i, c) in chapters.take(max(index, 0)).indexed) {
        final comic = await repo.getComic(key.$1, c.id);
        final original = comic?.document.isOriginal ?? false;
        earlierOriginal |= original;
        if (i == index - 1 && original) previousHead = comic!.id;
      }
      return (previousHead: previousHead, earlierOriginal: earlierOriginal);
    });

/// The page a task draws: a compose task's new page, or the existing page a
/// redraw names. Null for other comic work (adapting, checking, drawing a
/// whole adaptation), which has no page to show progress at.
String? comicTaskPage(GenerationTask task, List<Map<String, dynamic>> pages) =>
    switch (task.input['comicAction']) {
      'compose' =>
        'page-${task.input['comicCreationId'] ?? task.retryOf ?? task.id}',
      'images' when pages.any((p) => p['id'] == task.input['panelId']) =>
        task.input['panelId'] as String,
      _ => null,
    };

/// The analysis and image connections a paid comic drawing needs. When one
/// is missing, [missing] gets its name (`还没有分析模型` / `还没有生图模型`)
/// and the result is null; otherwise [missing] gets null.
Future<(ModelConnection, ModelConnection)?> comicModels(
  AppServices services, {
  required ValueChanged<String?> missing,
}) async {
  final analysis = await services.connectionFor('analysis');
  final image = await services.connectionFor('image');
  final name = analysis == null
      ? '还没有分析模型'
      : image == null
      ? '还没有生图模型'
      : null;
  missing(name);
  return name == null ? (analysis!, image!) : null;
}

/// A comic episode on a page of its own, like the middle of a comic work's
/// workspace: moving on stays on the canvas, which shows every kind of
/// episode, and each episode's actions go where its kind is made.
class ComicCanvasPage extends ConsumerWidget {
  const ComicCanvasPage({
    super.key,
    required this.branchId,
    required this.chapterId,
    this.carry,
  });
  final String branchId, chapterId;
  final String? carry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void push(Widget page) =>
        Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
    final adaptation = ComicScreen(branchId: branchId, chapterId: chapterId);
    final head = ref.watch(comicHeadProvider((branchId, chapterId))).value;
    // An adaptation's storyboard is edited in its panel, with its checks.
    final adapted = head != null && !head.document.isOriginal;
    return PageScaffold(
      title: '漫画',
      body: ComicCanvas(
        branchId: branchId,
        chapterId: chapterId,
        initialInstruction: carry,
        onEditStoryboard: (page) => push(
          adapted
              ? adaptation
              : ComicStoryboard(
                  branchId: branchId,
                  chapterId: chapterId,
                  pageId: page,
                ),
        ),
        onOpenChapter: (id, text) => Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) =>
                ComicCanvasPage(branchId: branchId, chapterId: id, carry: text),
          ),
        ),
        onReadProse: () =>
            push(ReaderScreen(branchId: branchId, chapterId: chapterId)),
        onAdapt: () => push(adaptation),
      ),
    );
  }
}

/// One episode of a comic work in the middle of the workspace: its pages,
/// where they are being drawn, and what to draw next.
class ComicCanvas extends ConsumerStatefulWidget {
  const ComicCanvas({
    super.key,
    required this.branchId,
    required this.chapterId,
    this.selectedPageId,
    this.initialInstruction,
    this.onSelectPage,
    this.onEditStoryboard,
    this.onOpenChapter,
    this.onReadProse,
    this.onAdapt,
  });
  final String branchId, chapterId;
  final String? selectedPageId, initialInstruction;
  final ValueChanged<String>? onSelectPage, onEditStoryboard;
  final void Function(String chapterId, String? instruction)? onOpenChapter;
  final VoidCallback? onReadProse, onAdapt;
  @override
  ConsumerState<ComicCanvas> createState() => _ComicCanvasState();
}

class _ComicCanvasState extends ConsumerState<ComicCanvas> {
  // Made in initState, not on first use: [ComicCanvas.initialInstruction]
  // is handed over once and may be gone by the time the episode has loaded.
  late final TextEditingController _instruction;

  @override
  void initState() {
    super.initState();
    _instruction = TextEditingController(
      text: widget.initialInstruction ?? _texts?[_textKey],
    )..addListener(_keepText);
    _keepText();
  }

  /// The field's text lives in the work's drafts too: crossing the 900 px
  /// breakpoint remounts the canvas.
  Map<String, String>? get _texts =>
      comicDraftsOf(ref, widget.branchId)?.instructions;
  String get _textKey => '${widget.branchId}/${widget.chapterId}';

  void _keepText() {
    final texts = _texts;
    if (texts == null) return;
    if (_instruction.text.isEmpty) {
      texts.remove(_textKey);
    } else {
      texts[_textKey] = _instruction.text;
    }
  }

  final _directionAttempts = <String>{};
  // Stopped composes whose text was offered back to the field, once each.
  final _restored = <String>{};
  final _drawingSheets = <String>{};
  bool _busy = false, _sheets = true;
  String? _selected, _picked, _missing;

  String? get _selectedPage => widget.selectedPageId ?? _selected;

  @override
  void didUpdateWidget(ComicCanvas old) {
    super.didUpdateWidget(old);
    // Another episode: only what was typed for that one comes back.
    if (old.chapterId != widget.chapterId || old.branchId != widget.branchId) {
      _instruction.text = widget.initialInstruction ?? _texts?[_textKey] ?? '';
      _selected = _picked = _missing = null;
      _sheets = true;
    }
  }

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Widget page) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

  /// Connections for a paid request, or null after naming the missing one.
  Future<(ModelConnection, ModelConnection)?> _models() => comicModels(
    ref.read(servicesProvider),
    missing: (name) {
      if (mounted) setState(() => _missing = name);
    },
  );

  /// [instruction] defaults to the field. Once the order is placed the field
  /// is cleared if it still holds what was ordered, so 画下一页 cannot order
  /// the same event twice.
  Future<void> _compose(
    ComicRevision? head, {
    required bool sheets,
    String? instruction,
  }) async {
    final models = await _models();
    if (models == null) return;
    final services = ref.read(servicesProvider);
    final text = instruction ?? _instruction.text;
    await services.comics.compose(
      branchId: widget.branchId,
      chapterId: widget.chapterId,
      instruction: text,
      connection: models.$1,
      imageConnection: models.$2,
      nsfwConnection: await services.connectionFor('imageNsfw'),
      expectedRevisionId: head?.id,
      characterSheets: sheets,
    );
    if (mounted) {
      if (_instruction.text == text) _instruction.clear();
      _picked = null;
    }
  }

  Future<void> _redraw(ComicRevision head, String pageId) async {
    final models = await _models();
    if (models == null) return;
    final services = ref.read(servicesProvider);
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

  /// Continues a stopped task from its saved steps: finished images are
  /// reused and remote requests reconnected, so nothing is paid twice.
  Future<void> _resume(GenerationTask task) =>
      ref.read(servicesProvider).runner.resume(task.id);

  /// Whether 重试 continues [task] rather than ordering afresh. A resume
  /// replays what the task froze, so it is worth it only while everything
  /// the runner checks on the way still holds; otherwise it would fail the
  /// same way on every tap. Read at tap time, so a stale build cannot decide.
  /// [pageId] is the failed page for a page's 重试: resuming must reuse its
  /// image request (a finished child, or a remote one to reconnect). Null is
  /// the notice's compose, which saved no page and reuses its plan calls.
  Future<bool> _resumable(GenerationTask task, String? pageId) async {
    final services = ref.read(servicesProvider), repo = services.repository;
    // The assistant's turn refuses a second call.
    if (task.input['agentComicCall'] != null) return false;
    if (pageId != null &&
        (task.result['comicChildren']
                as Map?)?['${widget.chapterId}/$pageId'] ==
            null) {
      return false;
    }
    // The head it last saved, or the one it froze while nothing is saved,
    // as the runner reads it; none only for an episode's first compose.
    final head = await repo.getComic(widget.branchId, widget.chapterId);
    final frozen =
        (task.result['comicHeads'] ?? task.input['comicHeads']) as Map?;
    if (frozen?[widget.chapterId] != head?.id ||
        head == null && pageId != null) {
      return false;
    }
    // A redraw continues from the previous episode's last page as it was.
    if (task.input['comicPreviousChapterId'] case final String previous
        when (await repo.getComic(widget.branchId, previous))?.id !=
            task.input['comicPreviousRevisionId']) {
      return false;
    }
    // The connections it froze must be the ones the canvas would use now: a
    // fix in settings, or an engine set up since, needs a fresh order.
    final models = await comicModels(services, missing: (_) {});
    if (models == null) return false;
    final (analysis, image) = models;
    final compose = task.input['comicAction'] == 'compose';
    final current = {
      'connection': compose ? analysis : image,
      'promptConnection': analysis,
      'imageConnection': compose ? image : null,
      'nsfwConnection': await services.connectionFor('imageNsfw'),
    };
    // Task inputs are stored with credentials redacted.
    return current.entries.every(
      (e) =>
          (task.input[e.key] == null
              ? null
              : canonicalJson(task.input[e.key])) ==
          (e.value == null
              ? null
              : canonicalJson(redactCredentials(e.value!.raw))),
    );
  }

  /// 重试 on a failed page: the task that drew it continues when it can,
  /// otherwise the page is drawn afresh with the current comic and settings.
  Future<void> _retryPage(
    GenerationTask? owner,
    ComicRevision head,
    String pageId,
  ) async {
    if (owner != null && await _resumable(owner, pageId)) {
      return _resume(owner);
    }
    return _redraw(head, pageId);
  }

  /// 重试 on a compose that saved no page: it continues when it can,
  /// otherwise the same text is composed with the current comic and
  /// settings, and a missing model is named as for any drawing.
  Future<void> _retryCompose(GenerationTask task, ComicRevision? head) async {
    final text = task.input['comicInstruction'] as String? ?? '';
    if (!await _resumable(task, null)) {
      return _compose(
        head,
        sheets: task.input['comicCharacterSheets'] == true,
        instruction: text,
      );
    }
    await _resume(task);
    if (mounted && _instruction.text == text) _instruction.clear();
  }

  Future<void> _directions(ComicRevision head, {bool automatic = false}) async {
    try {
      final services = ref.read(servicesProvider);
      final connection = await services.connectionFor('analysis');
      if (connection == null) {
        // Named in place with a settings link, like a drawing request.
        if (!automatic && mounted) setState(() => _missing = '还没有分析模型');
        return;
      }
      await services.comics.suggestDirections(
        branchId: widget.branchId,
        chapterId: widget.chapterId,
        connection: connection,
        expectedRevisionId: head.id,
      );
    } catch (_) {
      // An automatic run would toast on every visit; 换一批 retries and
      // reports the error.
      if (!automatic) rethrow;
    }
  }

  /// Deletes without asking; the toast's undo restores the revision before,
  /// and the store refuses it once anything newer has been written.
  Future<void> _delete(ComicRevision head, int index) async {
    final repo = ref.read(repositoryProvider);
    final after = await repo.saveComic(
      branchId: widget.branchId,
      chapterId: widget.chapterId,
      document: head.document.withoutPage(head.document.pages[index]['id']),
      expectedRevisionId: head.id,
      reason: '删除第 ${index + 1} 页',
    );
    if (!mounted) return;
    showFToast(
      context: context,
      title: Text('已删除第 ${index + 1} 页'),
      suffixBuilder: (_, entry) => comicButton('撤销', () async {
        entry.dismiss();
        try {
          await repo.restoreComic(
            branchId: widget.branchId,
            chapterId: widget.chapterId,
            revisionId: head.id,
            expectedRevisionId: after.id,
          );
        } catch (e) {
          if (mounted) showError(context, e);
        }
      }),
    );
  }

  Future<void> _drawSheet(String name) async {
    if (!_drawingSheets.add(name)) return;
    setState(() {});
    try {
      final services = ref.read(servicesProvider);
      final image = await services.connectionFor('image');
      if (image == null) {
        if (mounted) setState(() => _missing = '还没有生图模型');
        return;
      }
      await services.comics.drawCharacterSheet(
        branchId: widget.branchId,
        chapterId: widget.chapterId,
        name: name,
        connection: image,
      );
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _drawingSheets.remove(name);
      if (mounted) setState(() {});
    }
  }

  Future<void> _finishChapter() async {
    final chapter = await ref
        .read(repositoryProvider)
        .createChapter(branchId: widget.branchId);
    widget.onOpenChapter?.call(chapter.id, _instruction.text);
  }

  void _pick(String event) => setState(() {
    _picked = event;
    _instruction.text = event;
  });

  /// The same actions as the wide toolbar, for touch-sized screens.
  Future<void> _pageMenu(List<MenuEntry> entries) => showAppSheet<void>(
    context: context,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: FItemGroup(
        children: [
          for (final entry in entries)
            FItem(
              title: Text(entry.label),
              variant: entry.destructive
                  ? FItemVariant.destructive
                  : FItemVariant.primary,
              onPress: () {
                Navigator.pop(sheet);
                entry.onPress();
              },
            ),
        ],
      ),
    ),
  );

  Widget _progress(GenerationTask task, int number) => _Progress(
    task: task,
    number: number,
    onCancel: () =>
        _run(() => ref.read(servicesProvider).runner.cancel(task.id)),
  );

  @override
  Widget build(BuildContext context) {
    final key = (widget.branchId, widget.chapterId);
    return AsyncView(
      value: ref.watch(comicProvider(key)),
      builder: (data) {
        final story = ref.watch(storyProvider(widget.branchId)).value;
        final tasks = ref.watch(tasksProvider(widget.branchId));
        final head = data.comic, doc = head?.document;
        final hasProse = data.chapter.content.text.trim().isNotEmpty;
        final related = (tasks.value ?? <GenerationTask>[]).where(
          (t) =>
              t.kind == TaskKind.comic &&
              ((t.input['comicHeads'] as Map? ?? {}).containsKey(
                    widget.chapterId,
                  ) ||
                  (t.result['comicCandidates'] as List? ?? []).contains(
                    widget.chapterId,
                  )),
        );
        final active = related.where((t) => t.isActive);
        // Suggesting directions is not drawing; it only blocks new requests.
        final drawing = active
            .where((t) => t.input['comicAction'] != 'directions')
            .firstOrNull;
        final busy = _busy || active.isNotEmpty;
        // Every document getter decodes the whole JSON again: read each once.
        final original = doc?.isOriginal ?? (data.original && !hasProse);
        final pages = doc?.pages ?? <Map<String, dynamic>>[];
        final panels = doc?.panels ?? <Map<String, dynamic>>[];
        final stale = doc?.stalePageIds.toSet() ?? const <String>{};
        final hints = original && pages.isNotEmpty
            ? doc!.auditIssues.length
            : 0;
        final target = drawing == null ? null : comicTaskPage(drawing, pages);
        // The newest compose, ordered by the author, stopped before saving
        // its page: nothing on the canvas would say so, and its text left
        // the field when it started. A page it did save (or kept as a
        // candidate) shows its own failure instead, and deleting that page
        // brings no notice back. Saving writes `comicHeads` into the result
        // together with `comicDocuments`, which task lists leave out.
        final lastCompose = related
            .where((t) => t.input['comicAction'] == 'compose')
            .firstOrNull;
        final unsaved =
            original &&
                lastCompose != null &&
                lastCompose.input['agentComicCall'] == null &&
                !lastCompose.isActive &&
                lastCompose.status != TaskStatus.completed &&
                !(lastCompose.result['comicHeads'] as Map? ?? const {})
                    .containsKey(widget.chapterId)
            ? lastCompose
            : null;
        if (unsaved != null && _restored.add(unsaved.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _instruction.text.isEmpty) {
              _instruction.text =
                  unsaved.input['comicInstruction'] as String? ?? '';
            }
          });
        }
        final notice = unsaved == null ? null : _unsaved(unsaved, head, busy);
        // Sheets drawing in the repository outlive this widget: leaving and
        // coming back must not offer a second paid sheet.
        final sheetTasks = {
          for (final t in tasks.value ?? <GenerationTask>[])
            if (t.isActive &&
                t.kind == TaskKind.illustration &&
                t.input['purpose'] == AssetPurpose.reference.name)
              t.input['name'],
        };
        bool drawingSheet(String name) =>
            _drawingSheets.contains(name) ||
            // The name IllustrationService.ensureReference gives the task.
            sheetTasks.contains('$name · 参考图');
        final chapters = story?.chapters ?? const <Chapter>[];
        final index = chapters.indexWhere((c) => c.id == widget.chapterId);
        final last = index >= 0 && index == chapters.length - 1;
        final directionTasks = related.where(
          (t) =>
              t.input['comicAction'] == 'directions' &&
              (t.input['comicHeads'] as Map)[widget.chapterId] == head?.id,
        );
        final nextReady =
            original &&
            last &&
            head != null &&
            pages.isNotEmpty &&
            pages.last['assetId'] != null &&
            drawing == null;
        // One automatic suggestion per comic revision, never retried.
        if (nextReady &&
            !busy &&
            tasks.hasValue &&
            directionTasks.isEmpty &&
            _directionAttempts.add(head.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _run(() => _directions(head, automatic: true));
          });
        }
        final theme = context.theme;
        final menu = [
          if (head != null) ...[
            menuEntry(
              '本话历史版本',
              () => _run(
                () => showComicHistory(
                  context,
                  ref,
                  branchId: widget.branchId,
                  chapterId: widget.chapterId,
                ),
              ),
            ),
            menuEntry(
              '导出漫画',
              () => _run(
                () => showComicExport(
                  context,
                  ref,
                  branchId: widget.branchId,
                  chapterId: widget.chapterId,
                ),
              ),
            ),
          ],
        ];
        final wide = MediaQuery.sizeOf(context).width >= 900;
        final cast = ref.watch(_castProvider(key)).value;
        final body = <Widget>[
          Row(
            children: [
              Expanded(
                child: Text(
                  data.chapter.title,
                  style: theme.typography.body.xl,
                ),
              ),
              if (menu.isNotEmpty) ...[
                const SizedBox(width: 8),
                MenuAction(tooltip: '本话操作', enabled: !_busy, entries: menu),
              ],
            ],
          ),
          if (doc == null && hasProse)
            _card([
              const Text('本话有小说正文，还没有漫画'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  comicButton('阅读正文', widget.onReadProse),
                  comicButton('改编为漫画', widget.onAdapt),
                ],
              ),
            ])
          else if (doc != null && !doc.hasPages)
            for (final (i, panel) in panels.indexed)
              ComicPanelView(panel: panel, number: i + 1),
          for (final (i, page) in pages.indexed)
            if (page['id'] == target)
              _progress(drawing!, i + 1)
            else
              _page(
                head!,
                page,
                i,
                wide: wide,
                busy: busy,
                original: original,
                stale: stale.contains(page['id']),
                hints: i == pages.length - 1 ? hints : 0,
                panels: panels,
                newcomers: [
                  for (final name in page['characters'] as List? ?? [])
                    if (cast?.where((e) => e.name == name).firstOrNull
                        case final entry?
                        when (entry.data['images'] as List? ?? []).isEmpty)
                      (name: name as String, drawing: drawingSheet(name)),
                ],
              ),
          if (drawing != null && target == null)
            _working(drawing)
          else if (drawing != null && !pages.any((p) => p['id'] == target))
            _progress(drawing, pages.length + 1)
          // A new episode, or an original whose pages were all deleted.
          else if (original && pages.isEmpty) ...[
            ?notice,
            _opening(head, busy),
          ],
          if (drawing == null) ..._failure(related, head, original, pages),
          ..._candidates(related, head, pages),
          if (nextReady) ...[
            ?notice,
            _next(head, directionTasks, chapters, busy),
          ],
          if (index >= 0 && !last)
            Align(
              alignment: Alignment.centerLeft,
              child: FButton(
                mainAxisSize: MainAxisSize.min,
                onPress: () =>
                    widget.onOpenChapter?.call(chapters[index + 1].id, null),
                child: const Text('下一话'),
              ),
            ),
        ];
        return ContentLayout(
          maxWidth: 760,
          builder: (_, inset) => SingleChildScrollView(
            padding: inset + const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _gapped(body, 24),
            ),
          ),
        );
      },
    );
  }

  /// One page and its actions. Adaptations keep their checks: redraw and
  /// delete go through the adaptation panel there.
  Widget _page(
    ComicRevision head,
    Map<String, dynamic> page,
    int index, {
    required bool wide,
    required bool busy,
    required bool original,
    required bool stale,
    required int hints,
    required List<Map<String, dynamic>> panels,
    required List<({String name, bool drawing})> newcomers,
  }) {
    final id = page['id'] as String;
    final canRedraw = original && !busy && page['assetId'] != null;
    void redraw() => _run(() => _redraw(head, id));
    void edit() => widget.onEditStoryboard?.call(id);
    final more = [
      if (page['imageTaskId'] case final String task)
        menuEntry('生图记录', () => _open(TaskScreen(taskId: task))),
      if (original && !busy)
        menuEntry(
          '删除此页',
          () => _run(() => _delete(head, index)),
          destructive: true,
        ),
    ];
    final entries = [
      if (canRedraw) menuEntry('重画', redraw),
      if (widget.onEditStoryboard != null) menuEntry('改分镜', edit),
      ...more,
    ];
    return _PageTile(
      id: id,
      number: index + 1,
      selected: _selectedPage == id,
      onPress: () {
        setState(() => _selected = id);
        widget.onSelectPage?.call(id);
        if (!wide && entries.isNotEmpty) _pageMenu(entries);
      },
      toolbar: wide && entries.isNotEmpty
          ? Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (original) comicButton('重画', canRedraw ? redraw : null),
                if (widget.onEditStoryboard != null) comicButton('改分镜', edit),
                if (more.isNotEmpty)
                  MenuAction(
                    tooltip: '更多页面操作',
                    icon: FLucideIcons.ellipsis,
                    entries: more,
                  ),
              ],
            )
          : null,
      footer: [
        if (hints > 0)
          comicButton(
            'AI 提示 $hints',
            widget.onEditStoryboard == null ? null : edit,
          ),
        if (stale) comicButton('分镜已改，图未更新 · 重画', canRedraw ? redraw : null),
        for (final (:name, :drawing) in newcomers)
          drawing
              ? comicButton('正在画$name的定妆图…', null)
              : comicButton('新角色：$name · 画定妆图', () => _drawSheet(name)),
      ],
      child: _pageImage(page, panels),
    );
  }

  /// [busy] includes any comic task of the episode, which the store would
  /// refuse a new drawing for.
  Widget _opening(ComicRevision? head, bool busy) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final novel = ref.watch(storyProvider(widget.branchId)).value?.novel;
    final prior = ref
        .watch(_priorProvider((widget.branchId, widget.chapterId)))
        .value;
    final tasks = ref.watch(tasksProvider(widget.branchId)).value ?? [];
    final carried = prior?.previousHead == null
        ? const <Map>[]
        : _directionsOf(
            tasks.where(
              (t) =>
                  t.kind == TaskKind.comic &&
                  t.input['comicAction'] == 'directions' &&
                  (t.input['comicHeads'] as Map? ?? {}).values.contains(
                    prior!.previousHead,
                  ),
            ),
          );
    final sheets = prior != null && !prior.earlierOriginal;
    final drawSheets = sheets && _sheets;
    final style = novel?.style.trim() ?? '';
    final missing = _missingModel();
    final analysis = ref.watch(roleConnectionProvider('analysis')).value;
    final image = ref.watch(roleConnectionProvider('image')).value;
    return _card([
      Text(
        '第一页发生了什么？',
        style: theme.typography.body.lg.copyWith(fontWeight: FontWeight.w600),
      ),
      if (carried.isNotEmpty)
        _DirectionCards(directions: carried, picked: _picked, onPick: _pick),
      _field('例如：雨夜，一个女孩在末班地铁上收到未来自己的短信'),
      Row(
        children: [
          Expanded(child: Text('画风：${style.isEmpty ? '未设置' : style}')),
          const SizedBox(width: 8),
          comicButton(
            '修改',
            novel == null ? null : () => showNovelDialog(context, novel: novel),
          ),
        ],
      ),
      if (sheets)
        FSwitch(
          key: const Key('comic-character-sheets'),
          label: const Text('先画主要角色的定妆图'),
          description: const Text('最多 3 张，之后每页都按它画'),
          value: _sheets,
          onChange: (v) => setState(() => _sheets = v),
        ),
      if (missing != null)
        _settingsLink(missing)
      else if (analysis != null && image != null)
        Text('模型：${analysis.name} · ${image.name}', style: muted),
      Align(
        alignment: Alignment.centerLeft,
        child: FButton(
          mainAxisSize: MainAxisSize.min,
          onPress: busy
              ? null
              : () => _run(() => _compose(head, sheets: drawSheets)),
          child: const Text('开始画'),
        ),
      ),
      Text(
        drawSheets
            ? '自动编排分镜、检查连贯，画成一整页。首次最多 4 张图。'
            : '自动编排分镜、检查连贯，画成一整页。共 1 张图。',
        style: muted,
      ),
    ]);
  }

  Widget _field(String hint) => FTextField(
    key: const Key('comic-instruction'),
    control: FTextFieldControl.managed(controller: _instruction),
    hint: hint,
    minLines: 3,
    maxLines: 6,
  );

  /// The connection a drawing lacks, as found by the last request or by the
  /// configured roles; null while they load or when both exist.
  String? _missingModel() {
    final analysis = ref.watch(roleConnectionProvider('analysis'));
    final image = ref.watch(roleConnectionProvider('image'));
    if (_missing != null) return _missing;
    if (!analysis.hasValue || !image.hasValue) return null;
    return analysis.value == null
        ? '还没有分析模型'
        : image.value == null
        ? '还没有生图模型'
        : null;
  }

  /// Settings open on top, so whatever was typed stays in the field.
  Widget _settingsLink(String missing) => Align(
    alignment: Alignment.centerLeft,
    child: comicButton('$missing · 去设置', () async {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );
      if (mounted) setState(() => _missing = null);
    }),
  );

  Widget _next(
    ComicRevision head,
    Iterable<GenerationTask> directionTasks,
    List<Chapter> chapters,
    bool busy,
  ) {
    final theme = context.theme;
    final directions = _directionsOf(directionTasks);
    final thinking = directionTasks.any((t) => t.isActive);
    final missing = _missingModel();
    return _card([
      Row(
        children: [
          Expanded(
            child: Text(
              '接下来',
              style: theme.typography.body.lg.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          comicButton(
            thinking ? '正在想…' : '换一批',
            busy ? null : () => _run(() => _directions(head)),
          ),
        ],
      ),
      if (directions.isNotEmpty)
        _DirectionCards(directions: directions, picked: _picked, onPick: _pick),
      _field('下一页发生什么？'),
      if (missing != null) _settingsLink(missing),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: busy
                ? null
                : () => _run(() => _compose(head, sheets: false)),
            child: const Text('画下一页'),
          ),
          comicButton(
            '本话完结，开始第 ${chapters.where((c) => c.numbered).length + 1} 话',
            _busy ? null : () => _run(_finishChapter),
          ),
        ],
      ),
      Text(
        '点方向只会填进输入框，可以先改再画。每页 1 张图。',
        style: theme.typography.body.sm.copyWith(
          color: theme.colors.mutedForeground,
        ),
      ),
    ]);
  }
}
