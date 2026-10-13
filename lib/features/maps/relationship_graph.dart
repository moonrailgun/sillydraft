import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

class RelationshipGraph extends StatefulWidget {
  const RelationshipGraph({
    super.key,
    required this.entries,
    required this.onOpen,
  });
  final List<LoreEntry> entries;
  final ValueChanged<LoreEntry> onOpen;
  @override
  State<RelationshipGraph> createState() => _GraphState();
}

class _GraphState extends State<RelationshipGraph> {
  String? _focus;
  final _positions = <String, Offset>{};
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final all = widget.entries.where((e) => !e.deleted).toList(),
          relations = widget.entries
              .where((e) => !e.deleted && e.kind == LoreKind.relationship)
              .toList();
      final endpointIds = {
        for (final r in relations) ...[r.data['fromId'], r.data['toId']],
      };
      final nodes = all
          .where(
            (e) =>
                e.kind == LoreKind.character ||
                e.kind == LoreKind.organization ||
                endpointIds.contains(e.id),
          )
          .toList();
      if (nodes.isEmpty) {
        return const Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text('先添加人物，再记录他们之间的关系。', textAlign: TextAlign.center),
          ),
        );
      }
      final compact = bounds.maxWidth < 700;
      final focus =
          nodes.where((n) => n.id == _focus).firstOrNull ?? nodes.first;
      final neighbors = {
        for (final r in relations.where(
          (r) => r.data['fromId'] == focus.id || r.data['toId'] == focus.id,
        )) ...[(r.data['fromId'] as String), (r.data['toId'] as String)],
      };
      final visible = compact
          ? [
              focus,
              ...nodes
                  .where((n) => n.id != focus.id && neighbors.contains(n.id))
                  .take(6),
            ]
          : nodes;
      final columns = math.max(1, math.sqrt(visible.length).ceil());
      final width = compact
              ? bounds.maxWidth
              : math.max(bounds.maxWidth, columns * 180.0 + 80),
          height = compact
              ? 480.0
              : math.max(
                  480.0,
                  (visible.length / columns).ceil() * 130.0 + 100,
                );
      for (final (i, n) in visible.indexed) {
        _positions.putIfAbsent(
          n.id,
          () => compact
              ? (i == 0
                    ? Offset(width / 2, height / 2)
                    : Offset(
                        width / 2 +
                            math.cos(
                                  (i - 1) *
                                      2 *
                                      math.pi /
                                      math.max(1, visible.length - 1),
                                ) *
                                math.min(135, width / 2 - 62),
                        height / 2 +
                            math.sin(
                                  (i - 1) *
                                      2 *
                                      math.pi /
                                      math.max(1, visible.length - 1),
                                ) *
                                135,
                      ))
              : Offset(110 + (i % columns) * 180, 100 + (i ~/ columns) * 130),
        );
      }
      final ids = visible.map((e) => e.id).toSet(),
          edges = relations
              .where(
                (r) =>
                    ids.contains(r.data['fromId']) &&
                    ids.contains(r.data['toId']),
              )
              .toList();
      final theme = context.theme, colors = theme.colors;
      return Column(
        children: [
          if (compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: FSelect<String>.rich(
                label: const Text('查看此人的关系'),
                control: FSelectControl<String>.lifted(
                  value: focus.id,
                  onChange: (v) => setState(() {
                    _focus = v;
                    _positions.clear();
                  }),
                ),
                format: (id) =>
                    nodes.where((n) => n.id == id).firstOrNull?.name ?? '',
                children: [
                  for (final n in nodes)
                    FSelectItem<String>(title: Text(n.name), value: n.id),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              compact ? '局部关系图 · 可拖动人物、双指缩放' : '拖动人物调整布局，滚轮或双指缩放',
              style: theme.typography.body.xs.copyWith(
                color: colors.mutedForeground,
              ),
            ),
          ),
          Expanded(
            child: InteractiveViewer(
              constrained: false,
              minScale: .35,
              maxScale: 3,
              boundaryMargin: const EdgeInsets.all(150),
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _GraphPainter(edges, _positions, colors),
                      ),
                    ),
                    for (final node in visible)
                      Positioned(
                        left: _positions[node.id]!.dx - 52,
                        top: _positions[node.id]!.dy - 24,
                        width: 104,
                        height: 48,
                        child: Semantics(
                          button: true,
                          label: '人物 ${node.name}',
                          child: GestureDetector(
                            onTap: () => widget.onOpen(node),
                            onPanUpdate: (d) => setState(
                              () => _positions[node.id] = Offset(
                                (_positions[node.id]!.dx + d.delta.dx).clamp(
                                  55,
                                  width - 55,
                                ),
                                (_positions[node.id]!.dy + d.delta.dy).clamp(
                                  25,
                                  height - 25,
                                ),
                              ),
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: node.id == focus.id
                                    ? colors.primary
                                    : colors.secondary,
                                border: Border.all(
                                  color: node.id == focus.id
                                      ? colors.primary
                                      : colors.border,
                                ),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: Text(
                                    node.name,
                                    maxLines: 2,
                                    textAlign: TextAlign.center,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.typography.body.sm.copyWith(
                                      color: node.id == focus.id
                                          ? colors.primaryForeground
                                          : colors.secondaryForeground,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: FButton(
              variant: FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => showAppSheet<void>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  children: [
                    for (final edge in (compact ? edges : relations))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: FTile(
                          title: Text(
                            '${all.where((e) => e.id == edge.data['fromId']).firstOrNull?.name ?? '已归档'} → ${all.where((e) => e.id == edge.data['toId']).firstOrNull?.name ?? '已归档'}',
                          ),
                          subtitle: Text(edge.name),
                          onPress: () {
                            Navigator.pop(context);
                            widget.onOpen(edge);
                          },
                        ),
                      ),
                    if ((compact ? edges : relations).isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          '尚未记录关系',
                          style: TextStyle(
                            color: context.theme.colors.mutedForeground,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              prefix: const Icon(FLucideIcons.list),
              child: const Text('查看关系列表'),
            ),
          ),
        ],
      );
    },
  );
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.relations, this.positions, this.colors);
  final List<LoreEntry> relations;
  final Map<String, Offset> positions;
  final FColors colors;
  @override
  void paint(Canvas canvas, Size size) {
    for (final edge in relations) {
      final from = positions[edge.data['fromId']],
          to = positions[edge.data['toId']];
      if (from == null || to == null) continue;
      final vector = to - from, distance = vector.distance;
      if (distance < 1) continue;
      final unit = vector / distance,
          end = to - unit * 54,
          start = from + unit * 54;
      final color = edge.certainty == LoreCertainty.fact
          ? colors.primary
          : colors.mutedForeground;
      final paint = Paint()
        ..color = color.withValues(alpha: .65)
        ..strokeWidth = 1.6;
      canvas.drawLine(start, end, paint);
      if (edge.data['directed'] != false) {
        final normal = Offset(-unit.dy, unit.dx);
        canvas.drawLine(end, end - unit * 10 + normal * 5, paint);
        canvas.drawLine(end, end - unit * 10 - normal * 5, paint);
      }
      final text = TextPainter(
        text: TextSpan(
          text: edge.name,
          style: TextStyle(
            fontSize: 11,
            color: color,
            backgroundColor: colors.background,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 130);
      text.paint(
        canvas,
        (from + to) / 2 - Offset(text.width / 2, text.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GraphPainter oldDelegate) => true;
}
