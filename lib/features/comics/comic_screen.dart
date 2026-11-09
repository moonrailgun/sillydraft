import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../agent/task_screen.dart';
import '../editor/editor_screen.dart';
import 'comic_canvas.dart';
import 'comic_dialogs.dart';
import 'comic_editor.dart';
import 'comic_reader.dart';
import 'comic_requests.dart';

const _steps = ['编排分镜', '检查改编', '绘制'];
const _actionSteps = {'adapt': 0, 'check': 1};

/// The novel-adaptation panel: storyboard, faithfulness check, drawing.
/// Original comics are created on the comic canvas instead.
class ComicScreen extends ConsumerStatefulWidget {
  const ComicScreen({
    super.key,
    required this.branchId,
    required this.chapterId,
    this.embedded = false,
  });
  final String branchId, chapterId;
  final bool embedded;
  @override
  ConsumerState<ComicScreen> createState() => _ComicScreenState();
}

class _ComicScreenState extends ConsumerState<ComicScreen> {
  bool _busy = false;

  StoryRepository get _repo => ref.read(repositoryProvider);

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

  Future<void> _save(ComicRevision head, ComicDocument doc) async {
    await _repo.saveComic(
      branchId: widget.branchId,
      chapterId: widget.chapterId,
      document: doc,
      expectedRevisionId: head.id,
    );
  }

  Future<void> _request(
    ComicRequestKind kind,
    ComicRevision? head, {
    String? panelId,
  }) async {
    final story = await _repo.getStory(widget.branchId);
    if (!mounted) return;
    final task = await requestComicTask(
      context,
      services: ref.read(servicesProvider),
      story: story,
      chapterId: widget.chapterId,
      kind: kind,
      head: head,
      panelId: panelId,
    );
    if (task != null && mounted) _open(TaskScreen(taskId: task.id));
  }

  Widget _line(String text, Widget action) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Row(
      children: [
        Expanded(child: Text(text)),
        const SizedBox(width: 8),
        action,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '漫画',
    embedded: widget.embedded,
    body: AsyncView(
      value: ref.watch(comicProvider((widget.branchId, widget.chapterId))),
      builder: (data) {
        final head = data.comic, doc = head?.document;
        final empty = data.chapter.content.text.trim().isEmpty;
        // An empty chapter of a comic work starts as an original comic. A
        // novel work has no canvas beside this, so it opens one on top.
        if (comicOnCanvas(data)) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 16,
                children: [
                  const Text('这一话是原创漫画，请在漫画画布中创作。'),
                  comicButton(
                    '打开漫画画布',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ComicCanvasPage(
                          branchId: widget.branchId,
                          chapterId: widget.chapterId,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        final theme = context.theme;
        final tasks = ref.watch(tasksProvider(widget.branchId));
        final related = (tasks.value ?? <GenerationTask>[])
            .where(
              (t) =>
                  t.kind == TaskKind.comic &&
                  ((t.input['comicHeads'] as Map? ?? {}).containsKey(
                        widget.chapterId,
                      ) ||
                      (t.result['comicCandidates'] as List? ?? []).contains(
                        widget.chapterId,
                      )),
            )
            .toList();
        final active = related.any((t) => t.isActive);
        final latest = related.firstOrNull;
        final step = doc == null || !data.sourceCurrent
            ? 0
            : doc.checked
            ? 2
            : 1;
        final issues = [...?doc?.structuralIssues, ...?doc?.auditIssues];
        // Same pages generateImages(panelId: null) draws.
        final layout = doc?.asPages();
        final pending =
            layout?.pages
                .where(
                  (p) =>
                      p['assetId'] == null ||
                      p['visualReview'] == true ||
                      p['fingerprint'] != layout.pageFingerprint(p),
                )
                .length ??
            0;
        final (label, onPress) = switch (step) {
          0 when empty => (
            '本章还没有正文 · 编辑正文',
            () => _open(EditorScreen(chapter: data.chapter)),
          ),
          0 => (
            doc == null ? '生成分镜' : '重新改编',
            () => _run(() => _request(ComicRequestKind.adapt, head)),
          ),
          1 => (
            '检查改编',
            () => _run(() => _request(ComicRequestKind.check, head)),
          ),
          _ when doc!.complete => (
            '已完成 · 阅读',
            () => _open(
              ComicReader(
                branchId: widget.branchId,
                chapterId: widget.chapterId,
              ),
            ),
          ),
          _ => (
            '绘制（$pending 张图）',
            () => _run(() => _request(ComicRequestKind.images, head)),
          ),
        };
        // Reading and editing prose never start a paid task.
        final free = step == 2 && doc!.complete || step == 0 && empty;
        final menu = [
          if (doc != null && !empty)
            menuEntry(
              '重新改编',
              () => _run(() => _request(ComicRequestKind.adapt, head)),
            ),
          if (head != null) ...[
            menuEntry(
              '来源与事实',
              () => editComicSources(
                context,
                document: head.document,
                save: (d) => _save(head, d),
              ),
            ),
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
        return ContentLayout(
          maxWidth: 900,
          builder: (_, inset) => SingleChildScrollView(
            padding: inset + const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        data.chapter.title,
                        style: theme.typography.body.lg,
                      ),
                    ),
                    if (menu.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      MenuAction(
                        tooltip: '改编操作',
                        enabled: !_busy,
                        entries: menu,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                Text.rich(
                  TextSpan(
                    children: [
                      for (final (i, name) in _steps.indexed) ...[
                        if (i > 0) const TextSpan(text: ' → '),
                        TextSpan(
                          text: name,
                          style: i == step
                              ? TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: theme.colors.foreground,
                                )
                              : null,
                        ),
                      ],
                    ],
                  ),
                  style: theme.typography.body.sm.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  !data.sourceCurrent
                      ? '依据已过期：原文或前情已修改，请重新改编。'
                      : doc == null
                      ? '先准备故事底稿，再提取事实和编排分镜。'
                      : doc.checked
                      ? '检查通过'
                      : '待检查：修改后需重新对照原文检查。',
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: (_busy || active) && !free ? null : onPress,
                    child: Text(label),
                  ),
                ),
                if (step == 1 && issues.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    '需要修正的问题',
                    style: theme.typography.body.sm.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  for (final issue in issues)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(issue),
                    ),
                ],
                if (tasks.hasError) ...[
                  const SizedBox(height: 16),
                  Text('任务记录暂不可用：${tasks.error}'),
                ],
                for (final task in related.where((t) => t.isActive))
                  _line(
                    '正在${_steps[_actionSteps[task.input['comicAction']] ?? 2]}',
                    comicButton(
                      '查看详情',
                      () => _open(TaskScreen(taskId: task.id)),
                    ),
                  ),
                if (latest != null &&
                    [
                      TaskStatus.failed,
                      TaskStatus.interrupted,
                    ].contains(latest.status))
                  _line(
                    latest.error.isEmpty
                        ? '上次任务${taskStatusLabels[latest.status]}'
                        : latest.error,
                    comicButton(
                      '查看详情',
                      () => _open(TaskScreen(taskId: latest.id)),
                    ),
                  ),
                for (final task in related.where(
                  (t) =>
                      !t.isActive &&
                      (t.result['comicCandidates'] as List? ?? []).contains(
                        widget.chapterId,
                      ),
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: comicButton(
                        '有未写入的分镜 · 比较',
                        _busy
                            ? null
                            : () => _run(
                                () => showComicCandidate(
                                  context,
                                  ref,
                                  taskId: task.id,
                                  chapterId: widget.chapterId,
                                  head: head,
                                ),
                              ),
                      ),
                    ),
                  ),
                if (doc != null) ...[
                  if (doc.hasPages)
                    for (final (i, page) in doc.pages.indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: FCard(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ComicPageView(
                                  document: doc,
                                  page: page,
                                  number: i + 1,
                                ),
                                const SizedBox(height: 16),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 12,
                                  children: [
                                    comicButton(
                                      '重画此页',
                                      _busy ||
                                              active ||
                                              !doc.checked ||
                                              !data.sourceCurrent
                                          ? null
                                          : () => _run(
                                              () => _request(
                                                ComicRequestKind.images,
                                                head,
                                                panelId: page['id'] as String,
                                              ),
                                            ),
                                    ),
                                    if (page['imageTaskId']
                                        case final String id)
                                      comicButton(
                                        '生图记录',
                                        () => _open(TaskScreen(taskId: id)),
                                      ),
                                    if (page['visualReview'] == true &&
                                        page['fingerprint'] ==
                                            doc.pageFingerprint(page))
                                      comicButton(
                                        '确认画面衔接',
                                        _busy
                                            ? null
                                            : () => _run(() async {
                                                final pages = doc.pages;
                                                pages[i]['visualReview'] =
                                                    false;
                                                await _save(
                                                  head!,
                                                  ComicDocument.fromJson({
                                                    ...doc.toJson(),
                                                    'pages': pages,
                                                  }),
                                                );
                                              }),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  FAccordion(
                    children: [
                      FAccordionItem(
                        title: const Text('编辑分镜'),
                        initiallyExpanded: !doc.hasPages,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final (i, panel) in doc.panels.indexed)
                              Padding(
                                padding: const EdgeInsets.only(top: 24),
                                child: FCard(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        ComicPanelView(
                                          panel: panel,
                                          number: i + 1,
                                          details: true,
                                          storyboardOnly: doc.hasPages,
                                        ),
                                        const SizedBox(height: 16),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 12,
                                          children: [
                                            comicButton(
                                              '编辑',
                                              _busy
                                                  ? null
                                                  : () => editComicPanel(
                                                      context,
                                                      document: doc,
                                                      panel: panel,
                                                      save: (d) =>
                                                          _save(head!, d),
                                                    ),
                                              key: Key(
                                                'panel-edit-${panel['id']}',
                                              ),
                                            ),
                                            comicButton(
                                              '上移',
                                              _busy || i == 0
                                                  ? null
                                                  : () => _run(
                                                      () => _move(head!, i, -1),
                                                    ),
                                              key: Key(
                                                'panel-up-${panel['id']}',
                                              ),
                                            ),
                                            comicButton(
                                              '下移',
                                              _busy ||
                                                      i == doc.panels.length - 1
                                                  ? null
                                                  : () => _run(
                                                      () => _move(head!, i, 1),
                                                    ),
                                            ),
                                            comicButton(
                                              '删除',
                                              _busy
                                                  ? null
                                                  : () => _run(() async {
                                                      if (!await confirmAction(
                                                        context,
                                                        title: '删除此分镜？',
                                                        message: '原文事实会保留，未承载的事实会显示为问题。旧版本仍可恢复。',
                                                        destructive: true,
                                                      )) {
                                                        return;
                                                      }
                                                      await _save(
                                                        head!,
                                                        doc.editPanels(
                                                          doc.panels
                                                            ..removeAt(i),
                                                        ),
                                                      );
                                                    }),
                                            ),
                                            if (!doc.hasPages)
                                              comicButton(
                                                '选择已有图片',
                                                _busy
                                                    ? null
                                                    : () => _run(
                                                        () => _pickImage(
                                                          head!,
                                                          i,
                                                        ),
                                                      ),
                                              ),
                                            comicButton(
                                              '参考图（${(panel['referenceAssetIds'] as List).length}）',
                                              _busy
                                                  ? null
                                                  : () => _run(
                                                      () =>
                                                          _references(head!, i),
                                                    ),
                                            ),
                                            if (!doc.hasPages)
                                              comicButton(
                                                '重画此格',
                                                _busy ||
                                                        !doc.checked ||
                                                        !data.sourceCurrent
                                                    ? null
                                                    : () => _run(
                                                        () => _request(
                                                          ComicRequestKind
                                                              .images,
                                                          head,
                                                          panelId:
                                                              panel['id']
                                                                  as String,
                                                        ),
                                                      ),
                                              ),
                                            if (panel['imageTaskId']
                                                case final String id)
                                              comicButton(
                                                '生图记录',
                                                () => _open(
                                                  TaskScreen(taskId: id),
                                                ),
                                              ),
                                            if (panel['visualReview'] == true)
                                              comicButton(
                                                '确认画面衔接',
                                                _busy
                                                    ? null
                                                    : () => _run(() async {
                                                        final panels =
                                                            doc.panels;
                                                        panels[i]['visualReview'] =
                                                            false;
                                                        await _save(
                                                          head!,
                                                          doc.editPanels(
                                                            panels,
                                                          ),
                                                        );
                                                      }),
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 24),
                            if (!doc.hasPages)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: comicButton(
                                  '添加分镜',
                                  _busy
                                      ? null
                                      : () => editComicPanel(
                                          context,
                                          document: doc,
                                          panel: null,
                                          save: (d) => _save(head!, d),
                                        ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );

  Future<void> _move(ComicRevision head, int index, int delta) async {
    final panels = head.document.panels, panel = head.document.panels[index];
    panels.removeAt(index);
    panels.insert(index + delta, panel);
    await _save(head, head.document.editPanels(panels));
  }

  Future<void> _pickImage(ComicRevision head, int index) async {
    final asset = await pickComicAsset(context, branchId: widget.branchId);
    if (asset == null) return;
    final panels = head.document.panels;
    panels[index]['assetId'] = asset.id;
    panels[index].remove('imageTaskId');
    panels[index]['visualReview'] = true;
    await _save(head, head.document.editPanels(panels));
  }

  Future<void> _references(ComicRevision head, int index) async {
    final ids = await pickComicReferences(
      context,
      branchId: widget.branchId,
      initial: List<String>.from(
        head.document.panels[index]['referenceAssetIds'] as List,
      ),
    );
    if (ids == null) return;
    final panels = head.document.panels;
    panels[index]['referenceAssetIds'] = ids;
    await _save(head, head.document.editPanels(panels));
  }
}
