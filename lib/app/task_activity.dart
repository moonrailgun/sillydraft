import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../features/agent/agent_providers.dart';
import '../features/agent/task_screen.dart';
import 'services.dart';
import 'widgets.dart';

final activeTasksProvider = FutureProvider<List<GenerationTask>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listTasks(activeOnly: true);
});

/// Sits above the navigator; immersive pages can hide it with their controls.
class TaskActivityFrame extends ConsumerStatefulWidget {
  const TaskActivityFrame({
    super.key,
    required this.navigator,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  ConsumerState<TaskActivityFrame> createState() => _TaskActivityFrameState();
}

class _TaskActivityFrameState extends ConsumerState<TaskActivityFrame> {
  final _hiddenBy = <Object>{};

  void _setHidden(Object owner, bool hidden) {
    if (!mounted) return;
    final changed = hidden ? _hiddenBy.add(owner) : _hiddenBy.remove(owner);
    if (changed) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(activeTasksProvider).value ?? const [];
    final active = tasks.isNotEmpty && _hiddenBy.isEmpty;
    final theme = context.theme;
    // Keep the navigator at the same position when the banner appears/disappears.
    return Column(
      children: [
        if (active)
          ColoredBox(
            color: theme.colors.background,
            child: SafeArea(
              bottom: false,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '请保持应用打开',
                          style: theme.typography.body.xs.copyWith(
                            color: theme.colors.mutedForeground,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: FPopover(
                            popoverAnchor: Alignment.topRight,
                            childAnchor: Alignment.bottomRight,
                            popoverBuilder: (context, popover) => SizedBox(
                              width: 288,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '任务进行中',
                                      style: theme.typography.body.lg,
                                    ),
                                    const SizedBox(height: 8),
                                    const Text(
                                      '请勿离开或关闭应用，以免任务中断。可以在应用内自由切换页面。',
                                    ),
                                    const SizedBox(height: 12),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxHeight: 240,
                                      ),
                                      child: ListView.separated(
                                        shrinkWrap: true,
                                        padding: EdgeInsets.zero,
                                        itemCount: tasks.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(height: 8),
                                        itemBuilder: (context, index) {
                                          final task = tasks[index];
                                          return FTile(
                                            title: Text(
                                              taskKindLabels[task.kind]!,
                                            ),
                                            subtitle: Text(
                                              taskStatusLabels[task.status]!,
                                            ),
                                            suffix: const Icon(
                                              FLucideIcons.chevronRight,
                                            ),
                                            onPress: () {
                                              popover.hide();
                                              widget.navigator.currentState
                                                  ?.push(
                                                    MaterialPageRoute<void>(
                                                      builder: (_) =>
                                                          TaskScreen(
                                                            taskId: task.id,
                                                          ),
                                                    ),
                                                  );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            builder: (context, popover, _) => FButton(
                              key: const Key('task-activity'),
                              variant: FButtonVariant.outline,
                              size: FButtonSizeVariant.sm,
                              mainAxisSize: MainAxisSize.min,
                              onPress: popover.toggle,
                              prefix: SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: theme.colors.primary,
                                ),
                              ),
                              child: Flexible(
                                child: Text('${tasks.length} 个任务进行中'),
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
          )
        else
          const SizedBox.shrink(),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: active,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

/// Matches the global task banner to the controls of the current page.
class TaskActivityVisibility extends StatefulWidget {
  const TaskActivityVisibility({
    super.key,
    required this.visible,
    required this.child,
  });
  final bool visible;
  final Widget child;

  @override
  State<TaskActivityVisibility> createState() => _TaskActivityVisibilityState();
}

class _TaskActivityVisibilityState extends State<TaskActivityVisibility> {
  _TaskActivityFrameState? _frame;
  bool _onstage = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _frame = context.findAncestorStateOfType<_TaskActivityFrameState>();
    // Overlay keeps this enabled behind dialogs, but disables covered pages.
    _onstage = TickerMode.valuesOf(context).enabled;
    _update();
  }

  @override
  void didUpdateWidget(TaskActivityVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }

  void _update() => WidgetsBinding.instance.addPostFrameCallback((_) {
    _frame?._setHidden(this, mounted && _onstage && !widget.visible);
  });

  @override
  void dispose() {
    _update();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
