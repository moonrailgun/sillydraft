import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

/// The wide workspace: tools on the left, the page in the middle and the
/// outline on the right. Either side folds away without losing its state;
/// dragging a divider, or the arrow keys on it, resizes that side, and the
/// widths are kept.
class ResizableWorkspace extends ConsumerStatefulWidget {
  const ResizableWorkspace({
    super.key,
    required this.tools,
    required this.content,
    required this.outline,
    this.toolsOpen = true,
    this.outlineOpen = true,
  });
  final Widget tools, content, outline;
  final bool toolsOpen, outlineOpen;
  @override
  ConsumerState<ResizableWorkspace> createState() => _ResizableState();
}

class _ResizableState extends ConsumerState<ResizableWorkspace> {
  double? _tools, _outline;

  static const _toolsRange = (min: 280.0, initial: 380.0);
  static const _outlineRange = (min: 200.0, max: 420.0, initial: 280.0);

  /// The page keeps at least this much; the sides give way first.
  static const _page = 360.0;

  Future<void> _persist() async {
    try {
      final saved = ref.read(settingProvider('workspaceLayout')).value;
      await ref.read(repositoryProvider).setSetting('workspaceLayout', {
        ...?saved,
        'toolsWidth': ?_tools,
        'outlineWidth': ?_outline,
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(settingProvider('workspaceLayout')).value;
    double stored(String key, double fallback) =>
        saved?[key] is num ? (saved![key] as num).toDouble() : fallback;
    return LayoutBuilder(
      builder: (context, constraints) {
        final open = [widget.toolsOpen, widget.outlineOpen];
        final room = constraints.maxWidth - 12 * open.where((o) => o).length;
        final toolsMax = math.max(_toolsRange.min, room * .45);
        // A folded pane keeps its width offstage: its contents stay laid out
        // as they were and return unchanged.
        var tools = (_tools ?? stored('toolsWidth', _toolsRange.initial)).clamp(
          _toolsRange.min,
          toolsMax,
        );
        var outline =
            (_outline ?? stored('outlineWidth', _outlineRange.initial)).clamp(
              _outlineRange.min,
              _outlineRange.max,
            );
        // Too narrow for all three: narrow the tools, then the outline.
        var over =
            (widget.toolsOpen ? tools : 0) +
            (widget.outlineOpen ? outline : 0) +
            _page -
            room;
        if (over > 0 && widget.toolsOpen) {
          final cut = math.min(over, tools - _toolsRange.min);
          tools -= cut;
          over -= cut;
        }
        if (over > 0 && widget.outlineOpen) {
          outline -= math.min(over, outline - _outlineRange.min);
        }
        return Row(
          children: [
            Offstage(
              offstage: !widget.toolsOpen,
              child: SizedBox(
                key: const Key('workspace-tools'),
                width: tools,
                child: widget.tools,
              ),
            ),
            if (widget.toolsOpen)
              _Divider(
                key: const Key('workspace-tools-divider'),
                label: '工具面板宽度',
                width: tools,
                min: _toolsRange.min,
                max: toolsMax,
                onResize: (delta) => setState(
                  () => _tools = ((_tools ?? tools) + delta).clamp(
                    _toolsRange.min,
                    toolsMax,
                  ),
                ),
                onEnd: _persist,
              ),
            Expanded(child: widget.content),
            if (widget.outlineOpen)
              _Divider(
                key: const Key('workspace-divider'),
                label: '目录面板宽度',
                width: outline,
                min: _outlineRange.min,
                max: _outlineRange.max,
                // The outline is on the right: dragging left widens it.
                end: true,
                onResize: (delta) => setState(
                  () => _outline = ((_outline ?? outline) + delta).clamp(
                    _outlineRange.min,
                    _outlineRange.max,
                  ),
                ),
                onEnd: _persist,
              ),
            Offstage(
              offstage: !widget.outlineOpen,
              child: SizedBox(
                key: const Key('workspace-outline'),
                width: outline,
                child: widget.outline,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The handle between a side pane and the page. [onResize] gets how much
/// wider the pane should be; for an [end] pane that is a drag to the left.
class _Divider extends StatefulWidget {
  const _Divider({
    super.key,
    required this.label,
    required this.width,
    required this.min,
    required this.max,
    required this.onResize,
    required this.onEnd,
    this.end = false,
  });
  final String label;
  final double width, min, max;
  final ValueChanged<double> onResize;
  final VoidCallback onEnd;
  final bool end;
  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool _focused = false;

  void _step(double delta) {
    widget.onResize(delta);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final sign = widget.end ? -1.0 : 1.0;
    String px(double v) => '${v.clamp(widget.min, widget.max).round()} 像素';
    return Focus(
      onFocusChange: (value) => setState(() => _focused = value),
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key != LogicalKeyboardKey.arrowLeft &&
            key != LogicalKeyboardKey.arrowRight) {
          return KeyEventResult.ignored;
        }
        _step((key == LogicalKeyboardKey.arrowRight ? 20 : -20) * sign);
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: widget.label,
        slider: true,
        value: px(widget.width),
        increasedValue: px(widget.width + 20),
        decreasedValue: px(widget.width - 20),
        onIncrease: () => _step(20),
        onDecrease: () => _step(-20),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) =>
                widget.onResize(details.delta.dx * sign),
            onHorizontalDragEnd: (_) => widget.onEnd(),
            child: SizedBox(
              width: 12,
              child: Center(
                child: Container(
                  width: _focused ? 3 : 1,
                  color: _focused
                      ? context.theme.colors.primary
                      : context.theme.colors.border,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
