import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../agent/task_screen.dart';
import '../editor/editor_screen.dart';
import '../illustrations/illustration_gallery.dart';
import '../illustrations/asset_image.dart';
import '../transfer/file_gateway.dart';
import 'comic_editor.dart';
import 'comic_reader.dart';
import 'comic_requests.dart';

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
  final _instruction = TextEditingController();
  final _directionAttempts = <String>{};

  @override
  void dispose() {
    _instruction.dispose();
    super.dispose();
  }

  Future<void> _compose(ComicRevision? head, String instruction) async {
    final services = ref.read(servicesProvider);
    final analysis = await services.connectionFor('analysis');
    final image = await services.connectionFor('image');
    if (analysis == null || image == null) {
      throw const FormatException('请先在设置中配置分析模型和生图模型；开场内容已保留。');
    }
    await services.comics.compose(
      branchId: widget.branchId,
      chapterId: widget.chapterId,
      instruction: instruction,
      connection: analysis,
      imageConnection: image,
      nsfwConnection: await services.connectionFor('imageNsfw'),
      expectedRevisionId: head?.id,
    );
    if (mounted) _instruction.clear();
  }

  Future<void> _directions(ComicRevision head, {bool automatic = false}) async {
    final services = ref.read(servicesProvider);
    final connection = await services.connectionFor('analysis');
    if (connection == null) {
      if (automatic) return;
      throw const FormatException('请先在设置中配置分析模型');
    }
    await services.comics.suggestDirections(
      branchId: widget.branchId,
      chapterId: widget.chapterId,
      connection: connection,
      expectedRevisionId: head.id,
    );
  }

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

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '漫画',
    embedded: widget.embedded,
    body: AsyncView(
      value: ref.watch(comicProvider((widget.branchId, widget.chapterId))),
      builder: (data) {
        final head = data.comic, doc = head?.document;
        final tasks = ref.watch(tasksProvider(widget.branchId));
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
        final original = data.original;
        final active = related.any((t) => t.isActive);
        final ready =
            original &&
            head != null &&
            doc!.checked &&
            doc.complete &&
            data.sourceCurrent;
        final directionTask = related
            .where(
              (t) =>
                  t.input['comicAction'] == 'directions' &&
                  (t.input['comicHeads'] as Map? ?? {})[widget.chapterId] ==
                      head?.id,
            )
            .firstOrNull;
        if (ready &&
            !_busy &&
            !active &&
            tasks.hasValue &&
            directionTask == null &&
            _directionAttempts.add(head.id)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _run(() => _directions(head, automatic: true));
          });
        }
        return ContentLayout(
          maxWidth: 900,
          builder: (_, inset) => SingleChildScrollView(
            padding: inset + const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  data.chapter.title,
                  style: context.theme.typography.body.lg,
                ),
                const SizedBox(height: 12),
                Text(
                  !data.sourceCurrent
                      ? (original
                            ? '此前漫画或顺序已变化，请检查连续性并复核画面。'
                            : '依据已过期：原文或前情已修改，请重新改编。')
                      : doc == null
                      ? (original
                            ? '写一句开场剧情，AI 会编排分镜并画成一页漫画。'
                            : '先准备故事底稿，再提取事实和编排分镜。')
                      : doc.checked
                      ? '检查通过'
                      : (original ? '分镜待检查：请检查连续性后绘制。' : '待检查：修改后需重新对照原文检查。'),
                ),
                const SizedBox(height: 16),
                if (original) ...[
                  FTextFormField(
                    key: const Key('comic-instruction'),
                    control: FTextFieldControl.managed(
                      controller: _instruction,
                    ),
                    label: Text(head == null ? '开场剧情' : '下一页剧情'),
                    hint: '例如：雨夜，一个女孩收到未来自己的短信',
                    maxLines: 3,
                  ),
                  const SizedBox(height: 16),
                  FButton(
                    onPress: _busy || active || head != null && !ready
                        ? null
                        : () => _run(() => _compose(head, _instruction.text)),
                    child: Text(head == null ? '开始画' : '继续画'),
                  ),
                  const SizedBox(height: 16),
                  if (ready) ...[
                    for (final direction
                        in directionTask?.result['directions'] as List? ?? [])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: FButton(
                          variant: FButtonVariant.outline,
                          onPress: _busy || active
                              ? null
                              : () => _run(
                                  () => _compose(
                                    head,
                                    '${direction['title']}\n${direction['summary']}\n${direction['event']}',
                                  ),
                                ),
                          child: Text(
                            '${direction['title']}\n${direction['summary']}',
                          ),
                        ),
                      ),
                    comicButton(
                      '刷新三个方向',
                      _busy || active
                          ? null
                          : () => _run(() => _directions(head)),
                    ),
                    const SizedBox(height: 16),
                  ] else if (head != null && data.sourceCurrent)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text('先完成当前页，或在下方处理检查问题与未完成任务，再继续剧情。'),
                    ),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 12,
                  children: [
                    if (!original)
                      comicButton(
                        '编辑故事底稿',
                        () => _open(EditorScreen(chapter: data.chapter)),
                      ),
                    if (!original)
                      comicButton(
                        doc == null ? '生成分镜' : '重新改编',
                        _busy || data.chapter.content.text.trim().isEmpty
                            ? null
                            : () => _run(
                                () => _request(ComicRequestKind.adapt, head),
                              ),
                      ),
                    if (head != null) ...[
                      if (!original)
                        comicButton(
                          '来源与事实',
                          _busy
                              ? null
                              : () => editComicSources(
                                  context,
                                  document: head.document,
                                  save: (d) => _save(head, d),
                                ),
                        ),
                      comicButton(
                        original ? '检查连续性' : '检查改编',
                        _busy || active || !original && !data.sourceCurrent
                            ? null
                            : () => _run(
                                () => _request(ComicRequestKind.check, head),
                              ),
                      ),
                      comicButton(
                        '生成漫画',
                        _busy ||
                                active ||
                                !data.sourceCurrent ||
                                !head.document.checked
                            ? null
                            : () => _run(
                                () => _request(ComicRequestKind.images, head),
                              ),
                      ),
                      comicButton(
                        '阅读',
                        () => _open(
                          ComicReader(
                            branchId: widget.branchId,
                            chapterId: widget.chapterId,
                          ),
                        ),
                      ),
                      comicButton(
                        '漫画 HTML ZIP',
                        _busy ? null : () => _run(_export),
                      ),
                      comicButton(
                        '历史版本',
                        _busy ? null : () => _run(() => _history(head)),
                      ),
                    ],
                  ],
                ),
                if (!original && data.chapter.content.text.trim().isEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('故事底稿为空。可以手写或用写作模型生成，保存后再改编为漫画。'),
                ],
                if (tasks.hasError) ...[
                  const SizedBox(height: 16),
                  Text('任务记录暂不可用：${tasks.error}'),
                ],
                for (final task in related.where(
                  (t) =>
                      t.input['comicAction'] != 'directions' ||
                      t.status != TaskStatus.completed,
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: FCard(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('漫画任务 · ${taskStatusLabels[task.status]}'),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                comicButton(
                                  '查看任务',
                                  () => _open(TaskScreen(taskId: task.id)),
                                ),
                                if (!task.isActive &&
                                    (task.result['comicCandidates'] as List? ??
                                            [])
                                        .contains(widget.chapterId))
                                  comicButton(
                                    '查看候选分镜',
                                    _busy
                                        ? null
                                        : () => _run(
                                            () => _candidate(task, head),
                                          ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (doc != null) ...[
                  if ([
                    ...doc.structuralIssues,
                    ...doc.auditIssues,
                  ].isNotEmpty) ...[
                    const SizedBox(height: 16),
                    FAccordion(
                      children: [
                        FAccordionItem(
                          title: const Text('需要修正的问题'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (final issue in [
                                ...doc.structuralIssues,
                                ...doc.auditIssues,
                              ])
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(issue),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (doc.hasPages) ...[
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
                  ],
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
                                                        message: original
                                                            ? '删除后需要重新检查和绘制该页；旧版本仍可恢复。'
                                                            : '原文事实会保留，未承载的事实会显示为问题。旧版本仍可恢复。',
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

  Future<StoryAsset?> _pick() => Navigator.push<StoryAsset>(
    context,
    MaterialPageRoute(
      builder: (_) => IllustrationGallery(
        branchId: widget.branchId,
        picker: true,
        purpose: AssetPurpose.illustration,
      ),
    ),
  );

  Future<void> _pickImage(ComicRevision head, int index) async {
    final asset = await _pick();
    if (asset == null) return;
    final panels = head.document.panels;
    panels[index]['assetId'] = asset.id;
    panels[index].remove('imageTaskId');
    panels[index]['visualReview'] = true;
    await _save(head, head.document.editPanels(panels));
  }

  Future<void> _references(ComicRevision head, int index) async {
    final ids = List<String>.from(
      head.document.panels[index]['referenceAssetIds'] as List,
    );
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, update) => AppDialog(
          title: const Text('参考图'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('按所选顺序发送；同场景前格会随后加入。模型参考图上限以生成确认页为准。'),
              const SizedBox(height: 16),
              for (final id in ids)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(child: Text('参考图 ${ids.indexOf(id) + 1}')),
                      AssetImageView(
                        assetId: id,
                        width: 64,
                        height: 64,
                        label: '参考图 ${ids.indexOf(id) + 1}',
                      ),
                      const SizedBox(width: 8),
                      comicButton('移除', () => update(() => ids.remove(id))),
                    ],
                  ),
                ),
              comicButton(
                '选择参考图',
                ids.length >= 16
                    ? null
                    : () async {
                        final asset = await _pick();
                        if (asset != null &&
                            ctx.mounted &&
                            !ids.contains(asset.id)) {
                          update(() => ids.add(asset.id));
                        }
                      },
              ),
            ],
          ),
          actions: [
            comicButton('取消', () => Navigator.pop(ctx)),
            FButton(
              onPress: () async {
                try {
                  final panels = head.document.panels;
                  panels[index]['referenceAssetIds'] = ids;
                  await _save(head, head.document.editPanels(panels));
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) showError(ctx, e);
                }
              },
              child: const Text('保存参考图'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(ComicDocument? doc) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (doc == null) const Text('尚无当前分镜'),
      for (final (i, p)
          in (doc?.imageItems ?? <Map<String, dynamic>>[]).indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 24),
          child: doc!.hasPages
              ? ComicPageView(document: doc, page: p, number: i + 1)
              : ComicPanelView(panel: p, number: i + 1, details: true),
        ),
    ],
  );

  Future<void> _candidate(GenerationTask listed, ComicRevision? head) async {
    final task = await _repo.getTask(listed.id);
    final doc = ComicDocument.fromJson(
      Map<String, dynamic>.from(
        (task.result['comicDocuments'] as Map)[widget.chapterId] as Map,
      ),
    );
    if (!mounted) return;
    var saving = false;
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, update) {
          Future<void> resolve(bool adopt) async {
            update(() => saving = true);
            try {
              await _repo.resolveComicCandidate(
                taskId: task.id,
                chapterId: widget.chapterId,
                expectedRevisionId: head?.id,
                adopt: adopt,
              );
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              if (ctx.mounted) showError(ctx, e);
            } finally {
              if (ctx.mounted) update(() => saving = false);
            }
          }

          return AppDialog(
            title: const Text('比较候选分镜'),
            maxWidth: 900,
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('采用后保留旧版历史，并标记待检查。若原文或当前分镜已更新，请关闭后重新比较。'),
                const SizedBox(height: 16),
                const Text('当前分镜'),
                const SizedBox(height: 12),
                _preview(head?.document),
                const Text('候选分镜'),
                const SizedBox(height: 12),
                _preview(doc),
              ],
            ),
            actions: [
              comicButton('关闭', saving ? null : () => Navigator.pop(ctx)),
              comicButton('放弃候选', saving ? null : () => resolve(false)),
              FButton(
                onPress: saving ? null : () => resolve(true),
                child: const Text('采用并标记待检查'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _history(ComicRevision head) async {
    final revisions = await _repo.listComicRevisions(
      widget.branchId,
      widget.chapterId,
    );
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        title: const Text('漫画历史'),
        maxWidth: 720,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final revision in revisions)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: FAccordion(
                  children: [
                    FAccordionItem(
                      title: Text(
                        '${revision.createdAt.toLocal()} · ${revision.reason}${revision.id == head.id ? ' · 当前' : ''}',
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _preview(revision.document),
                          if (revision.id != head.id)
                            comicButton('恢复此版本', () async {
                              if (!await confirmAction(
                                ctx,
                                title: '恢复此漫画版本？',
                                message:
                                    '会创建新的历史记录，恢复的图片需重新确认画面衔接。原文已改变时标记依据过期。',
                              )) {
                                return;
                              }
                              try {
                                await _repo.restoreComic(
                                  branchId: widget.branchId,
                                  chapterId: widget.chapterId,
                                  revisionId: revision.id,
                                  expectedRevisionId: head.id,
                                );
                                if (ctx.mounted) Navigator.pop(ctx);
                              } catch (e) {
                                if (ctx.mounted) showError(ctx, e);
                              }
                            }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [comicButton('关闭', () => Navigator.pop(ctx))],
      ),
    );
  }

  Future<void> _export() async {
    final story = await _repo.getStory(widget.branchId);
    var first = story.chapters.indexWhere((c) => c.id == widget.chapterId),
        last = first;
    var saving = false;
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, update) => AppDialog(
          title: const Text('导出漫画 HTML ZIP'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ComicChapterRange(
                chapters: story.chapters,
                first: first,
                last: last,
                onChange: (a, b) => update(() {
                  first = a;
                  last = b;
                }),
              ),
              const SizedBox(height: 16),
              const Text('选定章节必须检查通过且图片齐全。导出保留完整文字与阅读顺序；依据过期的漫画会附带说明。'),
            ],
          ),
          actions: [
            comicButton('取消', saving ? null : () => Navigator.pop(ctx)),
            FButton(
              onPress: saving
                  ? null
                  : () async {
                      update(() => saving = true);
                      try {
                        final file = await ref
                            .read(servicesProvider)
                            .comicPublications
                            .export(
                              branchId: widget.branchId,
                              chapterIds: story.chapters
                                  .sublist(first, last + 1)
                                  .map((c) => c.id)
                                  .toList(),
                            );
                        if (!ctx.mounted) return;
                        if (await ref
                                .read(transferFilesProvider)
                                .save(ctx, file) &&
                            ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                      } catch (e) {
                        if (ctx.mounted) showError(ctx, e);
                      } finally {
                        if (ctx.mounted) update(() => saving = false);
                      }
                    },
              child: Text(saving ? '正在导出…' : '导出'),
            ),
          ],
        ),
      ),
    );
  }
}
