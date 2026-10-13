import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/widgets.dart';

import '../../app/widgets.dart';

/// A foldable tree of JSON: objects and arrays open on tap, strings show
/// their real line breaks and fold when long.
class JsonTreeView extends StatelessWidget {
  const JsonTreeView(this.value, {super.key});
  final Object? value;
  @override
  Widget build(BuildContext context) => SelectionArea(
    child: DefaultTextStyle.merge(
      style: context.theme.typography.body.sm.copyWith(
        fontFamily: 'monospace',
        color: context.theme.colors.foreground,
      ),
      child: _JsonNode(null, value, depth: 0),
    ),
  );
}

class _JsonNode extends StatefulWidget {
  const _JsonNode(this.name, this.value, {required this.depth});
  final String? name;
  final Object? value;
  final int depth;
  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  /// Containers start open near the root unless they are large; strings
  /// start folded.
  late bool _open = switch (widget.value) {
    final Map<String, dynamic> m => widget.depth < 2 && m.length <= 100,
    final List<dynamic> l => widget.depth < 2 && l.length <= 100,
    _ => false,
  };

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final muted = TextStyle(color: colors.mutedForeground);
    final name = widget.name == null
        ? null
        : TextSpan(text: '${widget.name}: ', style: muted);
    final value = widget.value;
    if (value is Map || value is List) {
      final children = value is Map
          ? [for (final e in value.entries) ('${e.key}', e.value)]
          : [for (final (i, v) in (value as List).indexed) ('$i', v)];
      final summary = value is Map
          ? '{ ${children.length} 项 }'
          : '[ ${children.length} 项 ]';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTappable(
            onPress: children.isEmpty ? null : _toggle,
            child: Row(
              children: [
                Icon(
                  _open ? FLucideIcons.chevronDown : FLucideIcons.chevronRight,
                  size: 14,
                  color: colors.mutedForeground,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        ?name,
                        TextSpan(text: summary, style: muted),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_open && children.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 6, top: 2, bottom: 2),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: colors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (key, child) in children)
                    _JsonNode(key, child, depth: widget.depth + 1),
                ],
              ),
            ),
        ],
      );
    }
    final accent = colors.brightness == Brightness.dark
        ? const Color(0xFF7AB8FF)
        : const Color(0xFF1F6FC5);
    final text = value is String
        ? value.replaceAll('\r\n', '\n')
        : '${value ?? 'null'}';
    final long =
        value is String &&
        (text.length > 300 || '\n'.allMatches(text).length > 4);
    final folded = long && !_open;
    final leaf = Padding(
      padding: const EdgeInsets.only(left: 18, top: 1, bottom: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                ?name,
                TextSpan(
                  text: text.isEmpty
                      ? '""'
                      : folded
                      ? text.substring(0, 300.clamp(0, text.length))
                      : text,
                  style: value is String ? null : TextStyle(color: accent),
                ),
              ],
            ),
            maxLines: folded ? 5 : null,
            overflow: folded ? TextOverflow.ellipsis : null,
          ),
          if (long)
            Text(folded ? '展开全部 · ${text.length} 字' : '收起', style: muted),
        ],
      ),
    );
    return long ? FTappable(onPress: _toggle, child: leaf) : leaf;
  }
}
