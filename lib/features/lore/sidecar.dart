import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

/// What the author sees while the next chapter waits for the sidecar.
const sidecarWaitNotice = '等待上一章的旁路整理完成后再写…';

/// Starts the sidecar on [chapterId] when the author keeps it on, or always
/// when [manual]. Null when it does not run: switched off, or no model to
/// run it with. It runs a tool loop, so like the editor it needs a
/// connection that serves tool calls.
Future<GenerationTask?> startSidecar(
  AppServices services, {
  required String branchId,
  required String chapterId,
  bool manual = false,
}) async {
  final settings = SidecarSettings.fromJson(
    await services.repository.getSetting(SidecarSettings.key),
  );
  if (!manual && (!settings.enabled || settings.duties.isEmpty)) return null;
  final candidates = [
    await services.connectionFor('analysis'),
    await services.connectionFor('writing'),
  ].nonNulls;
  final connection = candidates
      .where((c) => connectionServes(c, 'editor'))
      .firstOrNull;
  if (connection == null) {
    if (!manual) return null;
    throw FormatException(
      candidates.isEmpty ? '请先在设置里配置资料整理模型。' : '旁路整理需要支持工具调用的模型连接，远程执行器暂不支持。',
    );
  }
  return services.sidecar.start(
    branchId: branchId,
    chapterId: chapterId,
    connection: connection,
    duties: settings.duties,
  );
}

/// [startSidecar] for a chapter that just changed, where a failure must not
/// get in the author's way: it can be run again from the lore page.
void startSidecarQuietly(
  AppServices services, {
  required String branchId,
  required String chapterId,
}) => holdForSidecar(
  branchId,
  startSidecar(services, branchId: branchId, chapterId: chapterId),
);

/// Background steps per branch that may yet start a sidecar task.
final _starting = <String, Set<Future<void>>>{};

/// Runs [step], which may start a sidecar on [branchId], in the background:
/// until it ends, [awaitSidecar] waits for it, so the next chapter cannot
/// slip in before the sidecar task exists. A failure is dropped; the sidecar
/// can be run again from the lore page.
void holdForSidecar(String branchId, Future<void> step) {
  final steps = _starting.putIfAbsent(branchId, () => {});
  final quiet = step.then((_) {}, onError: (_) {});
  steps.add(quiet);
  unawaited(quiet.whenComplete(() => steps.remove(quiet)));
}

/// Waits for this branch's sidecar runs, and for steps that may still start
/// one, so the next chapter is written with what they record. [onWait] fires
/// once when there is one to wait for; a failed run does not stop the
/// writing.
Future<void> awaitSidecar(
  AppServices services,
  String branchId, {
  VoidCallback? onWait,
  Duration limit = const Duration(minutes: 3),
}) async {
  final starting = [...?_starting[branchId]];
  Future<List<GenerationTask>> running() async => [
    for (final task in await services.repository.listTasks(
      branchId: branchId,
      activeOnly: true,
    ))
      if (task.kind == TaskKind.sidecar) task,
  ];
  if (starting.isEmpty && (await running()).isEmpty) return;
  onWait?.call();
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  // ponytail: a fixed cap so a stuck run never blocks writing; make it a
  // setting if slow local models need longer.
  final timer = Timer(limit, finish);
  unawaited(
    Future.wait(starting)
        // Listed again: a step that just ended may have started a run.
        .then((_) => running())
        .then(
          (runs) => Future.wait([
            for (final task in runs) services.runner.wait(task.id),
          ]),
        )
        .then((_) {}, onError: (_) {})
        .whenComplete(finish),
  );
  await done.future;
  timer.cancel();
}

final sidecarSettingsProvider = FutureProvider<SidecarSettings>((ref) async {
  ref.watch(repositoryChangesProvider);
  return SidecarSettings.fromJson(
    await ref.watch(repositoryProvider).getSetting(SidecarSettings.key),
  );
});

/// The sidecar's switches on the settings page: on after each chapter, and
/// each duty.
class SidecarSwitches extends ConsumerWidget {
  const SidecarSwitches({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(sidecarSettingsProvider),
    builder: (settings) {
      Future<void> save(SidecarSettings next) async {
        try {
          await ref
              .read(repositoryProvider)
              .setSetting(SidecarSettings.key, next.toJson());
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      }

      return FTileGroup(
        children: [
          FTile(
            key: const Key('sidecar-enabled'),
            prefix: const Icon(FLucideIcons.sparkles),
            title: const Text('写完一章后自动整理'),
            subtitle: const Text('关闭后仍可在资料页手动整理'),
            suffix: FSwitch(
              value: settings.enabled,
              onChange: (v) => save(settings.copyWith(enabled: v)),
            ),
          ),
          for (final duty in SidecarDuty.values)
            FTile(
              key: Key('sidecar-${duty.name}'),
              title: Text(duty.title),
              suffix: FSwitch(
                value: settings.duties.contains(duty),
                onChange: (v) => save(
                  settings.copyWith(
                    duties: v
                        ? {...settings.duties, duty}
                        : ({...settings.duties}..remove(duty)),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
