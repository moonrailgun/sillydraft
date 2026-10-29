import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../features/agent/agent_providers.dart';
import '../features/agent/task_screen.dart';
import 'services.dart';

final activeTasksProvider = FutureProvider<List<GenerationTask>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listTasks(activeOnly: true);
});

/// Each page places this in its header; task changes never resize the slot.
class TaskActivityAction extends ConsumerWidget {
  const TaskActivityAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(activeTasksProvider).value ?? const [];
    final theme = context.theme;
    final navigator = Navigator.of(context);
    final label = '${tasks.length} 个任务进行中';
    return SizedBox.square(
      dimension: 40,
      child: tasks.isEmpty
          ? null
          : FPopover(
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
                      Text('任务进行中', style: theme.typography.body.lg),
                      const SizedBox(height: 8),
                      const Text('请勿离开或关闭应用，以免任务中断。可以在应用内自由切换页面。'),
                      const SizedBox(height: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 240),
                        child: ListView.separated(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          itemCount: tasks.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final task = tasks[index];
                            return FTile(
                              title: Text(taskKindLabels[task.kind]!),
                              subtitle: Text(taskStatusLabels[task.status]!),
                              suffix: const Icon(FLucideIcons.chevronRight),
                              onPress: () {
                                popover.hide();
                                navigator.push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => TaskScreen(taskId: task.id),
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
              builder: (context, popover, _) => FTooltip(
                tipBuilder: (_, _) => Text(label),
                child: FHeaderAction(
                  key: const Key('task-activity'),
                  style: const FHeaderActionStyleDelta.delta(
                    padding: .value(EdgeInsets.all(8)),
                  ),
                  semanticsLabel: label,
                  onPress: popover.toggle,
                  icon: ExcludeSemantics(
                    child: SizedBox.square(
                      dimension: 24,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colors.primary,
                          ),
                          Center(
                            child: Text(
                              tasks.length > 99 ? '99+' : '${tasks.length}',
                              textScaler: TextScaler.noScaling,
                              style: theme.typography.body.xs.copyWith(
                                fontSize: 10,
                                color: theme.colors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
