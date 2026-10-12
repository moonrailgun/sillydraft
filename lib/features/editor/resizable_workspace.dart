import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

class ResizableWorkspace extends ConsumerStatefulWidget {
  const ResizableWorkspace({
    super.key,
    required this.outline,
    required this.content,
  });
  final Widget outline;
  final Widget content;
  @override
  ConsumerState<ResizableWorkspace> createState() => _ResizableState();
}

class _ResizableState extends ConsumerState<ResizableWorkspace> {
  double? _width;
  bool _focused = false;
  Future<void> _persist() async {
    try {
      await ref.read(repositoryProvider).setSetting('workspaceLayout', {
        'outlineWidth': _width,
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref
        .watch(settingProvider('workspaceLayout'))
        .value?['outlineWidth'];
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth * .55;
        final width = (_width ?? (saved is num ? saved.toDouble() : 320.0))
            .clamp(240.0, max);
        void resize(double delta, {bool persist = false}) {
          setState(
            () => _width = ((_width ?? width) + delta).clamp(240.0, max),
          );
          if (persist) _persist();
        }

        return Row(
          children: [
            SizedBox(
              key: const Key('workspace-outline'),
              width: width,
              child: widget.outline,
            ),
            Focus(
              onFocusChange: (value) => setState(() => _focused = value),
              onKeyEvent: (_, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                    event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  resize(
                    event.logicalKey == LogicalKeyboardKey.arrowLeft ? -20 : 20,
                    persist: true,
                  );
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Semantics(
                label: '目录面板宽度',
                slider: true,
                value: '${width.round()} 像素',
                increasedValue: '${(width + 20).clamp(240, max).round()} 像素',
                decreasedValue: '${(width - 20).clamp(240, max).round()} 像素',
                onIncrease: () => resize(20, persist: true),
                onDecrease: () => resize(-20, persist: true),
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    key: const Key('workspace-divider'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragUpdate: (details) =>
                        resize(details.delta.dx),
                    onHorizontalDragEnd: (_) => _persist(),
                    child: SizedBox(
                      width: 12,
                      child: Center(
                        child: Container(
                          width: _focused ? 3 : 1,
                          color: _focused
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).dividerColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: widget.content),
          ],
        );
      },
    );
  }
}
