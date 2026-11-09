part of 'comic_canvas.dart';

List<Widget> _gapped(List<Widget> items, double gap) => [
  for (final (i, item) in items.indexed) ...[
    if (i > 0) SizedBox(height: gap),
    item,
  ],
];

/// A card with the standard 16 px inner padding.
Widget _card(List<Widget> children) => FCard(
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _gapped(children, 12),
    ),
  ),
);

/// The three directions of the newest finished suggestion task, if any.
List<Map> _directionsOf(Iterable<GenerationTask> tasks) =>
    (tasks
                    .where((t) => t.status == TaskStatus.completed)
                    .firstOrNull
                    ?.result['directions']
                as List? ??
            [])
        .cast<Map>();

/// The page labelled with [ComicDocument.pageTranscript]'s text, built from
/// [panels] parsed once per build rather than decoding the document per page.
Widget _pageImage(
  Map<String, dynamic> page,
  List<Map<String, dynamic>> panels,
) => page['assetId'] is String
    ? AssetImageView(
        assetId: page['assetId'] as String,
        label: panels
            .where((p) => (page['panelIds'] as List).contains(p['id']))
            .map(
              (p) =>
                  '${p['description']}\n${(p['texts'] as List).map((t) => '${t['speaker']}：${t['text']}').join('\n')}',
            )
            .join('\n\n'),
      )
    : const Padding(padding: EdgeInsets.all(16), child: Text('尚未绘制'));

/// Where a running comic task is: its steps, the current one marked.
class _Progress extends StatelessWidget {
  const _Progress({
    required this.task,
    required this.number,
    required this.onCancel,
  });
  final GenerationTask task;
  final int number;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final sheets = task.result['comicSheets'] as Map?;
    final steps = [
      if (task.input['comicAction'] == 'compose') ...[
        ('plan', '编排分镜'),
        ('check', '检查连贯'),
      ],
      if (task.input['comicCharacterSheets'] == true)
        (
          'sheets',
          (sheets?['total'] ?? 0) == 0
              ? '画角色定妆图'
              : '画角色定妆图（${sheets!['done']}/${sheets['total']}）',
        ),
      ('page', '画第 $number 页'),
    ];
    // A queued task has no stage yet: it is at its first step.
    final current = max(
      0,
      steps.indexWhere((s) => s.$1 == task.result['comicStage']),
    );
    return _card([
      for (final (i, (_, label)) in steps.indexed)
        Row(
          children: [
            Icon(
              i < current
                  ? FLucideIcons.circleCheck
                  : i == current
                  ? FLucideIcons.circleDot
                  : FLucideIcons.circle,
              size: 16,
              color: i > current
                  ? theme.colors.mutedForeground
                  : theme.colors.foreground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: i == current
                    ? const TextStyle(fontWeight: FontWeight.w600)
                    : muted,
              ),
            ),
          ],
        ),
      Row(
        children: [
          Expanded(child: Text('离开也会继续', style: muted)),
          const SizedBox(width: 8),
          comicButton('取消', onCancel),
        ],
      ),
    ]);
  }
}

/// Picking a direction only fills the field; it never starts drawing.
class _DirectionCards extends StatelessWidget {
  const _DirectionCards({
    required this.directions,
    required this.picked,
    required this.onPick,
  });
  final List<Map> directions;
  final String? picked;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _gapped([
        for (final d in directions)
          FTappable(
            selected: d['event'] == picked,
            focusedOutlineStyle: const FFocusedOutlineStyleDelta.delta(),
            onPress: () => onPick(d['event'] as String),
            builder: (context, states, _) {
              final selected = states.contains(FTappableVariant.selected);
              return DecoratedBox(
                decoration: BoxDecoration(
                  color: selected || states.contains(FTappableVariant.hovered)
                      ? theme.colors.secondary
                      : null,
                  border: Border.all(
                    color: selected
                        ? theme.colors.primary
                        : theme.colors.border,
                  ),
                  borderRadius: theme.style.borderRadius.md,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        d['title'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        d['summary'] as String,
                        style: theme.typography.body.sm.copyWith(
                          color: theme.colors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ], 8),
    );
  }
}

/// One page: tapping selects it; [toolbar] shows while hovered, focused or
/// selected. The footer carries the page number and its status chips.
class _PageTile extends StatelessWidget {
  const _PageTile({
    required this.id,
    required this.number,
    required this.selected,
    required this.onPress,
    required this.child,
    this.toolbar,
    this.footer = const [],
  });
  final String id;
  final int number;
  final bool selected;
  final VoidCallback onPress;
  final Widget child;
  final Widget? toolbar;
  final List<Widget> footer;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final radius = theme.style.borderRadius.md;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTappable(
          key: Key('comic-page-$id'),
          semanticsLabel: '第 $number 页',
          selected: selected,
          focusedOutlineStyle: const FFocusedOutlineStyleDelta.delta(),
          onPress: onPress,
          builder: (context, states, _) => Stack(
            children: [
              DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selected
                        ? theme.colors.primary
                        : const Color(0x00000000),
                    width: 2,
                  ),
                  borderRadius: radius,
                ),
                child: ClipRRect(borderRadius: radius, child: child),
              ),
              if (toolbar != null &&
                  (selected ||
                      states.contains(FTappableVariant.hovered) ||
                      states.contains(FTappableVariant.focused)))
                Positioned(
                  top: 8,
                  right: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colors.background.withValues(alpha: .9),
                      borderRadius: radius,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: toolbar,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '第 $number 页',
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
            ...footer,
          ],
        ),
      ],
    );
  }
}

/// What blocks or waits on the episode, below its pages.
extension _Notices on _ComicCanvasState {
  /// Comic work with no page to show progress at, such as checking an
  /// adaptation or drawing all of it.
  Widget _working(GenerationTask task) => _card([
    Row(
      children: [
        const Expanded(child: Text('正在处理本话…')),
        const SizedBox(width: 8),
        comicButton('查看详情', () => _open(TaskScreen(taskId: task.id))),
        const SizedBox(width: 8),
        comicButton(
          '取消',
          () => _run(() => ref.read(servicesProvider).runner.cancel(task.id)),
        ),
      ],
    ),
  ]);

  /// The newest compose stopped before it saved a page. Retrying follows
  /// [_ComicCanvasState._retryCompose].
  Widget _unsaved(GenerationTask task, ComicRevision? head, bool busy) => _card(
    [
      Text('上次没画成：${task.error.isEmpty ? '任务已中断' : task.error}'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FButton(
            mainAxisSize: MainAxisSize.min,
            onPress: busy ? null : () => _run(() => _retryCompose(task, head)),
            child: const Text('重试'),
          ),
          comicButton('查看详情', () => _open(TaskScreen(taskId: task.id))),
        ],
      ),
    ],
  );

  /// Finished tasks whose drawing could not be written to this episode.
  List<Widget> _candidates(
    Iterable<GenerationTask> related,
    ComicRevision? head,
    List<Map<String, dynamic>> pages,
  ) {
    return [
      for (final task in related.where(
        (t) =>
            !t.isActive &&
            (t.result['comicCandidates'] as List? ?? []).contains(
              widget.chapterId,
            ),
      ))
        _card([
          Text(switch (comicTaskPage(task, pages)) {
            null => '有未写入的分镜',
            final id =>
              '第 ${switch (pages.indexWhere((p) => p['id'] == id)) {
                -1 => pages.length + 1,
                final i => i + 1,
              }} 页已画好，但期间本话有改动，没有写入',
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: comicButton(
              '比较',
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
        ]),
    ];
  }

  /// The last original page has no image and nothing is drawing it: the only
  /// way on is to retry or delete it.
  List<Widget> _failure(
    Iterable<GenerationTask> related,
    ComicRevision? head,
    bool original,
    List<Map<String, dynamic>> pages,
  ) {
    if (head == null ||
        !original ||
        pages.isEmpty ||
        pages.last['assetId'] != null) {
      return [];
    }
    final n = pages.length, id = pages.last['id'] as String;
    final failed = related
        .where(
          (t) =>
              t.input['comicAction'] != 'directions' &&
              [
                TaskStatus.failed,
                TaskStatus.interrupted,
                TaskStatus.cancelled,
              ].contains(t.status),
        )
        .firstOrNull;
    // The task that drew this page may continue (see _retryPage); a page
    // nothing drew (planned by the assistant, say) gets a fresh drawing.
    final owner = failed != null && comicTaskPage(failed, pages) == id
        ? failed
        : null;
    final missing = _missingModel();
    return [
      _card([
        Text('第 $n 页没画成', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (failed != null)
          Text(
            failed.error.isEmpty
                ? '上次任务${taskStatusLabels[failed.status]}'
                : failed.error,
          ),
        if (missing != null) _settingsLink(missing),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FButton(
              mainAxisSize: MainAxisSize.min,
              onPress: _busy
                  ? null
                  : () => _run(() => _retryPage(owner, head, id)),
              child: const Text('重试'),
            ),
            comicButton(
              '删除此页',
              _busy ? null : () => _run(() => _delete(head, n - 1)),
            ),
            if (failed != null)
              comicButton('查看详情', () => _open(TaskScreen(taskId: failed.id))),
          ],
        ),
      ]),
      Text(
        '第 $n 页处理好后可以继续画',
        style: context.theme.typography.body.sm.copyWith(
          color: context.theme.colors.mutedForeground,
        ),
      ),
    ];
  }
}
