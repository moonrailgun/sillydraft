import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/theme.dart' show touchPlatform;
import '../../app/widgets.dart';
import '../agent/agent_screen.dart' show imageEngineLabel;
import 'asset_image.dart';
import 'illustration_detail.dart' show showIllustrationDetail;

final illustrationGraphProvider =
    FutureProvider.family<IllustrationGraph, String>((ref, branchId) {
      ref.watch(repositoryContentChangesProvider);
      return ref.watch(repositoryProvider).illustrationGraph(branchId);
    });

class IllustrationRelations extends ConsumerStatefulWidget {
  const IllustrationRelations({
    super.key,
    required this.branchId,
    required this.assetId,
  });
  final String branchId, assetId;
  @override
  ConsumerState<IllustrationRelations> createState() =>
      _IllustrationRelationsState();
}

class _IllustrationRelationsState extends ConsumerState<IllustrationRelations> {
  bool _busy = false, _cancelled = false, _failed = false;
  String? _taskId, _message, _activeId;
  Map<String, String> _remaining = {};
  GenerationCancellation? _routingCancellation;

  @override
  void dispose() {
    _routingCancellation?.cancel();
    super.dispose();
  }

  Future<void> _regenerate(
    List<String> ids, {
    bool edit = false,
    bool resume = false,
  }) async {
    if (_busy) return;
    final services = ref.read(servicesProvider), branchId = widget.branchId;
    setState(() => _busy = true);
    _failed = false;
    try {
      await services.flushDrafts();
      final graph = await services.repository.illustrationGraph(branchId);
      final assets = ids.map(graph.current).toList();
      final painter = await services.connectionFor('image');
      final writer = await services.connectionFor('analysis');
      final nsfwPainter = await services.connectionFor('imageNsfw');
      if (painter == null || writer == null) {
        throw const FormatException('请先在设置中配置普通生图引擎和资料整理模型');
      }
      final engines = <String, ModelConnection>{};
      final prompts = <String, String>{}, parameters = <String, dynamic>{};
      for (final (index, asset) in assets.indexed) {
        final task = asset.taskId == null
            ? null
            : await services.repository.getTask(asset.taskId!);
        final saved = task?.input['connection'];
        final original = saved is Map
            ? ModelConnection.fromJson(saved.cast<String, dynamic>())
            : null;
        engines[asset.id] = original ?? painter;
        prompts[asset.id] =
            (resume ? _remaining[ids[index]] : null) ??
            IllustrationService.sourcePrompt(
              asset,
              tags: original?.protocol == ModelProtocol.novelAI,
            );
        parameters[asset.id] =
            (task?.input['imageRequest'] as Map?)?['parameters'] ?? {};
      }
      if (!mounted) return;
      var editedPrompt = prompts[assets.first.id]!;
      final engineLabels = {
        for (final c in engines.values) imageEngineLabel(c),
      };
      final confirmed =
          await showAppDialog<bool>(
            context: context,
            builder: (context) {
              final colors = context.theme.colors;
              final muted = context.theme.typography.body.xs.copyWith(
                color: colors.mutedForeground,
                height: 1.4,
              );
              return AppDialog(
                title: Text(edit ? '重新生成此图' : '重新生成 ${assets.length} 张关联图片'),
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('使用最新参考图依次生成。成功后替换当前分支正文里的对应图片；失败时保留旧图并停止。'),
                    const SizedBox(height: 8),
                    const Text('确认后重新判断 NSFW，按设置中的对应引擎编写提示词；切换引擎时使用该引擎的默认参数。'),
                    if (engineLabels.length == 1) ...[
                      const SizedBox(height: 8),
                      Text('上次生图引擎：${engineLabels.single}', style: muted),
                    ],
                    const SizedBox(height: 16),
                    if (edit) ...[
                      FTextField(
                        control: FTextFieldControl.managed(
                          initial: TextEditingValue(text: editedPrompt),
                          onChange: (value) => editedPrompt = value.text,
                        ),
                        label: const Text('画面描述'),
                        minLines: 3,
                        maxLines: 6,
                      ),
                      if (assets.first.purpose == AssetPurpose.reference) ...[
                        const SizedBox(height: 8),
                        Text('修改画面描述会同步更新关联资料的外观描述。', style: muted),
                      ],
                      const SizedBox(height: 16),
                    ],
                    for (final (i, asset) in assets.indexed) ...[
                      if (i > 0) const SizedBox(height: 16),
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: context.theme.style.borderRadius.sm,
                            child: AssetImageView(
                              assetId: asset.id,
                              thumbnail: true,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              label: asset.name,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  asset.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  [
                                    '参考：${graph.referenceIds(asset).map((id) => graph.assets[id]?.name ?? '图片已删除').join('、').emptyFallback('无')}',
                                    if (engineLabels.length > 1)
                                      '上次生图引擎：${imageEngineLabel(engines[asset.id]!)}',
                                  ].join('\n'),
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      FAccordion(
                        children: [
                          FAccordionItem(
                            title: const Text('上次提示词与参数'),
                            child: Text(
                              '${prompts[asset.id]}\n\n${const JsonEncoder.withIndent('  ').convert(parameters[asset.id])}',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                actions: [
                  FButton(
                    variant: FButtonVariant.outline,
                    onPress: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  FButton(
                    onPress: () => Navigator.pop(context, true),
                    child: const Text('开始生成'),
                  ),
                ],
              );
            },
          ) ??
          false;
      if (edit) prompts[assets.first.id] = editedPrompt.trim();
      if (!confirmed) return;
      _cancelled = false;
      _routingCancellation = GenerationCancellation();
      _remaining = Map.of(prompts);
      for (final (index, asset) in assets.indexed) {
        if (_cancelled) break;
        if (mounted) {
          setState(() {
            _activeId = asset.id;
            _message = '正在生成 ${index + 1}/${assets.length} · ${asset.name}';
          });
        }
        final task = await services.illustrations.regenerate(
          branchId: branchId,
          assetId: asset.id,
          connection: painter,
          promptConnection: writer,
          nsfwConnection: nsfwPainter,
          cancellation: _routingCancellation,
          prompt: prompts[asset.id],
        );
        _taskId = task.id;
        if (_cancelled) await services.runner.cancel(task.id);
        final done = await services.runner.wait(task.id);
        _taskId = null;
        if (done.status != TaskStatus.completed) {
          throw FormatException(
            done.status == TaskStatus.cancelled
                ? '已取消，旧图和已完成图片均已保留'
                : '${asset.name}生成失败：${done.error}',
          );
        }
        if (done.result['replacementError'] case final String error) {
          throw FormatException(error);
        }
        _remaining.remove(asset.id);
      }
      if (mounted) {
        setState(
          () => _message = _cancelled
              ? '已停止，已完成图片均已保留'
              : '已完成 ${assets.length} 张，正文图片已同步更新',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _failed = !_cancelled;
          _message = e is FormatException ? e.message : '$e';
        });
      }
    } finally {
      _routingCancellation = null;
      _taskId = _activeId = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AsyncView(
    value: ref.watch(illustrationGraphProvider(widget.branchId)),
    builder: (graph) {
      final root = graph.current(widget.assetId);
      final List<StoryAsset> descendants;
      try {
        descendants = graph.descendants(root.id);
      } on FormatException catch (e) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Text(e.message),
        );
      }
      final theme = context.theme, colors = theme.colors;
      final stale = [root, ...descendants].where(graph.isStale).length;
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '图片关联',
              style: theme.typography.body.md.copyWith(
                color: colors.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              descendants.isEmpty
                  ? '还没有图片以这张图作参考。'
                  : '${descendants.length} 张图片以这张图作参考'
                        '${stale == 0 ? '，都与当前版本一致。' : '，$stale 张参考图不一致。'}',
              style: theme.typography.body.sm.copyWith(
                color: colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (descendants.isNotEmpty)
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    variant: stale > 0
                        ? FButtonVariant.primary
                        : FButtonVariant.outline,
                    prefix: const Icon(FLucideIcons.refreshCw),
                    onPress: _busy
                        ? null
                        : () => _regenerate(
                            descendants.map((a) => a.id).toList(),
                          ),
                    child: Text('全部重新生成（${descendants.length} 张）'),
                  ),
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: FButtonVariant.outline,
                  onPress: _busy
                      ? null
                      : () => _regenerate([root.id], edit: true),
                  child: const Text('重新生成此图'),
                ),
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_busy && (_failed || _remaining.isEmpty)) ...[
                        Icon(
                          _failed
                              ? FLucideIcons.circleAlert
                              : FLucideIcons.circleCheck,
                          size: 16,
                          color: _failed
                              ? colors.destructive
                              : colors.mutedForeground,
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(
                          _message!,
                          style: TextStyle(
                            color: _failed ? colors.destructive : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_busy)
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      size: FButtonSizeVariant.sm,
                      variant: FButtonVariant.outline,
                      onPress: () async {
                        _cancelled = true;
                        _routingCancellation?.cancel();
                        if (_taskId case final id?) {
                          await ref.read(servicesProvider).runner.cancel(id);
                        }
                      },
                      child: const Text('停止生成'),
                    )
                  else if (_remaining.isNotEmpty)
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      size: FButtonSizeVariant.sm,
                      variant: FButtonVariant.outline,
                      onPress: () =>
                          _regenerate(_remaining.keys.toList(), resume: true),
                      child: Text('继续未完成（${_remaining.length} 张）'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            _Diagram(
              graph: graph,
              root: root,
              descendants: descendants,
              activeId: _activeId,
              onGenerate: _busy ? null : (id) => _regenerate([id], edit: true),
            ),
          ],
        ),
      );
    },
  );
}

class _Diagram extends StatelessWidget {
  const _Diagram({
    required this.graph,
    required this.root,
    required this.descendants,
    this.activeId,
    this.onGenerate,
  });
  final IllustrationGraph graph;
  final StoryAsset root;
  final List<StoryAsset> descendants;
  final String? activeId;
  final void Function(String)? onGenerate;

  @override
  Widget build(BuildContext context) {
    final nodes = <String, StoryAsset>{};
    void include(StoryAsset a) {
      if (nodes.containsKey(a.id)) return;
      nodes[a.id] = a;
      for (final id in graph.linkedReferenceIds(a)) {
        if (graph.assets[id] case final parent?) include(parent);
      }
    }

    include(root);
    for (final a in descendants) {
      include(a);
    }
    final depths = <String, int>{};
    int depth(String id, Set<String> path) {
      if (depths[id] case final d?) return d;
      if (!path.add(id)) return 0;
      var result = 0;
      for (final parent in graph.linkedReferenceIds(nodes[id]!)) {
        if (nodes.containsKey(parent)) {
          result = math.max(result, depth(parent, {...path}) + 1);
        }
      }
      return depths[id] = result;
    }

    for (final id in nodes.keys) {
      depth(id, {});
    }
    final levels = <int, List<StoryAsset>>{};
    for (final a in nodes.values) {
      levels.putIfAbsent(depths[a.id]!, () => []).add(a);
    }
    final theme = context.theme, colors = theme.colors;
    final scaler = MediaQuery.textScalerOf(context);
    final nameStyle = theme.typography.body.sm.copyWith(
      color: colors.foreground,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );
    final metaStyle = theme.typography.body.xs.copyWith(
      color: colors.mutedForeground,
      height: 1.3,
    );
    final changed = {
      for (final a in nodes.values)
        for (final id in graph.changedInputs(a)) (id, a.id),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 16.0, rowGap = 40.0, inset = 16.0;
        final cardWidth = constraints.maxWidth < 480 ? 140.0 : 176.0;
        final imageHeight = (cardWidth * .66).roundToDouble();
        final cardHeight =
            imageHeight +
            12 +
            scaler.scale(nameStyle.fontSize!) * 1.3 +
            4 +
            scaler.scale(metaStyle.fontSize!) * 1.3 +
            12 +
            2;
        final width =
            levels.values.map((l) => l.length).reduce(math.max) *
                (cardWidth + gap) -
            gap;
        final height =
            (levels.keys.reduce(math.max) + 1) * (cardHeight + rowGap) - rowGap;
        final positions = <String, Offset>{};
        for (final level in levels.keys.toList()..sort()) {
          final row = levels[level]!;
          // Order each row by its parents' positions so links cross less.
          double anchor(StoryAsset a) {
            final xs = [
              for (final id in graph.linkedReferenceIds(a))
                if (positions[id] case final p?) p.dx,
            ];
            return xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;
          }

          int chapter(StoryAsset a) {
            final i = graph.chapters.indexWhere(
              (c) => graph.placements(a.id).contains(c),
            );
            return i < 0 ? graph.chapters.length : i;
          }

          row.sort(
            (a, b) => anchor(a) != anchor(b)
                ? anchor(a).compareTo(anchor(b))
                : chapter(a).compareTo(chapter(b)),
          );
          final start = (width - (row.length * (cardWidth + gap) - gap)) / 2;
          for (final (i, a) in row.indexed) {
            positions[a.id] = Offset(
              start + i * (cardWidth + gap),
              level * (cardHeight + rowGap),
            );
          }
        }
        final edges = [
          for (final a in nodes.values)
            for (final id in graph.linkedReferenceIds(a))
              if (positions.containsKey(id))
                (
                  positions[id]! + Offset(cardWidth / 2, cardHeight),
                  positions[a.id]! + Offset(cardWidth / 2, 0),
                  changed.contains((id, a.id)),
                ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.muted,
                borderRadius: theme.style.borderRadius.lg,
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(
                  horizontal: math.max(
                    inset,
                    (constraints.maxWidth - width) / 2,
                  ),
                  vertical: inset,
                ),
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _Connections(
                            edges: edges,
                            color: colors.mutedForeground.withValues(alpha: .5),
                            changedColor: colors.destructive,
                          ),
                        ),
                      ),
                      for (final a in nodes.values)
                        Positioned(
                          left: positions[a.id]!.dx,
                          top: positions[a.id]!.dy,
                          width: cardWidth,
                          height: cardHeight,
                          child: _Node(
                            asset: a,
                            graph: graph,
                            current: a.id == root.id,
                            generating: a.id == activeId,
                            imageHeight: imageHeight,
                            nameStyle: nameStyle,
                            metaStyle: metaStyle,
                            onGenerate: onGenerate,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (changed.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 2,
                    child: ColoredBox(color: colors.destructive),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text('红线：生成后，这张参考图已更换或修改', style: metaStyle)),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Node extends StatelessWidget {
  const _Node({
    required this.asset,
    required this.graph,
    required this.current,
    required this.generating,
    required this.imageHeight,
    required this.nameStyle,
    required this.metaStyle,
    this.onGenerate,
  });
  final StoryAsset asset;
  final IllustrationGraph graph;
  final bool current, generating;
  final double imageHeight;
  final TextStyle nameStyle, metaStyle;
  final void Function(String)? onGenerate;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme, colors = theme.colors;
    final radius = theme.style.borderRadius.md;
    final stale = graph.isStale(asset);
    final placed = graph.placements(asset.id).map((c) => c.title).join('、');
    return FTappable.static(
      key: ValueKey('illustration-node-${asset.id}'),
      semanticsLabel: asset.name,
      onPress: () => showIllustrationDetail(
        context,
        assetId: asset.id,
        branchId: graph.branchId,
      ),
      builder: (context, states, _) => DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(
            color: current
                ? colors.primary
                : states.contains(FTappableVariant.hovered)
                ? colors.mutedForeground
                : colors.border,
            width: current ? 2 : 1,
          ),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: colors.background,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: imageHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      AssetImageView(
                        assetId: asset.id,
                        thumbnail: true,
                        height: imageHeight,
                        fit: BoxFit.cover,
                        // Portraits keep the face in a landscape crop.
                        alignment: asset.height > asset.width
                            ? const Alignment(0, -.7)
                            : Alignment.center,
                        label: asset.name,
                      ),
                      if (generating)
                        ColoredBox(
                          color: colors.background.withValues(alpha: .6),
                        ),
                      if (stale || current || generating)
                        Positioned(
                          left: 8,
                          top: 8,
                          child: FBadge(
                            variant: stale && !generating
                                ? FBadgeVariant.destructive
                                : FBadgeVariant.primary,
                            style: stale && !generating
                                ? FBadgeStyleDelta.delta(
                                    decoration: DecorationDelta.shapeDelta(
                                      color: colors.background,
                                    ),
                                  )
                                : const FBadgeStyleDelta.context(),
                            child: Text(
                              generating
                                  ? '生成中'
                                  : stale
                                  ? '参考图不一致'
                                  : '当前',
                            ),
                          ),
                        ),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        child: Visibility(
                          visible:
                              touchPlatform ||
                              states.contains(FTappableVariant.hovered) ||
                              states.contains(FTappableVariant.focused),
                          maintainSize: true,
                          maintainAnimation: true,
                          maintainState: true,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.background.withValues(alpha: .9),
                              borderRadius: theme.style.borderRadius.md,
                            ),
                            child: IconAction(
                              tooltip: '重新生成${asset.name}',
                              icon: FLucideIcons.refreshCw,
                              onPress: onGenerate == null
                                  ? null
                                  : () => onGenerate!(asset.id),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        asset.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nameStyle,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        asset.purpose == AssetPurpose.reference &&
                                placed.isEmpty
                            ? '参考图'
                            : placed.emptyFallback('未插入正文'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: metaStyle,
                      ),
                    ],
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

class _Connections extends CustomPainter {
  const _Connections({
    required this.edges,
    required this.color,
    required this.changedColor,
  });
  final List<(Offset, Offset, bool)> edges;
  final Color color, changedColor;
  @override
  void paint(Canvas canvas, Size size) {
    // Changed links last so they stay on top where lines overlap.
    for (final (from, to, changed) in [
      ...edges.where((e) => !e.$3),
      ...edges.where((e) => e.$3),
    ]) {
      final paint = Paint()
        ..color = changed ? changedColor : color
        ..strokeWidth = changed ? 2 : 1.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final middle = (from.dy + to.dy) / 2;
      canvas.drawPath(
        Path()
          ..moveTo(from.dx, from.dy)
          ..cubicTo(from.dx, middle, to.dx, middle, to.dx, to.dy - 2),
        paint,
      );
      canvas.drawPath(
        Path()
          ..moveTo(to.dx - 5, to.dy - 7)
          ..lineTo(to.dx, to.dy - 2)
          ..lineTo(to.dx + 5, to.dy - 7),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _Connections oldDelegate) => true;
}

extension on String {
  String emptyFallback(String fallback) => isEmpty ? fallback : this;
}
