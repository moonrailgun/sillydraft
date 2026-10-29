import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

/// What the author sees while the next chapter waits for the sidecar.
const sidecarWaitNotice = '等待上一章的旁路整理完成后再写…';

/// Starts the sidecar on [chapterId] when it is on, or always when
/// [manual]. Null when it does not run: switched off, or no model to run it
/// with. [SidecarSetup] says which model that is.
Future<GenerationTask?> startSidecar(
  AppServices services, {
  required String branchId,
  required String chapterId,
  bool manual = false,
}) async {
  final setup = await _setup(services);
  if (!manual && !_runsAfterEachChapter(setup)) return null;
  final connection = setup.connection;
  if (connection == null) {
    throw FormatException(
      await services.connectionFor('writing') == null
          ? '请先在设置里配置资料整理模型。'
          : '旁路整理需要支持工具调用的模型连接，远程执行器暂不支持。',
    );
  }
  return services.sidecar.start(
    branchId: branchId,
    chapterId: chapterId,
    connection: connection,
    duties: setup.settings.duties,
  );
}

Future<SidecarSetup> _setup(AppServices services) =>
    SidecarSetup.read(services.repository, localCli: services.remote == null);

/// Whether [startSidecar] starts a run on its own after a chapter.
bool _runsAfterEachChapter(SidecarSetup setup) =>
    setup.enabled &&
    setup.settings.duties.isNotEmpty &&
    setup.connection != null;

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

/// Once [task] has written its chapter, starts the sidecar on the text that
/// was taken in. A result left for the author starts it when accepted.
Future<void> sidecarAfterWrite(
  AppServices services,
  GenerationTask task,
) async {
  final done = await services.runner.wait(task.id);
  final proposal = done.result['proposalId'];
  if (proposal is String &&
      (await services.repository.getProposal(proposal)).status ==
          ProposalStatus.accepted) {
    await startSidecar(
      services,
      branchId: done.branchId,
      chapterId: done.chapterId!,
    );
  }
}

/// Organizes the accepted chapters from this round, skipping later edits and
/// deletions. Repeated writes to one chapter use only its final revision.
Future<void> sidecarAfterAgent(
  AppServices services,
  GenerationTask task,
) async {
  final done = await services.runner.wait(task.id);
  final written = done.result['writtenChapters'] as Map? ?? const {};
  if (written.isEmpty) return;
  final story = await services.repository.getStory(done.branchId);
  for (final chapter in story.chapters) {
    if (written[chapter.id] != chapter.revisionId) continue;
    final run = await startSidecar(
      services,
      branchId: done.branchId,
      chapterId: chapter.id,
    );
    // Later chapters should see the notes saved for earlier ones.
    if (run != null) await services.runner.wait(run.id);
  }
}

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
/// writing. With no run after each chapter, held steps start none and are not
/// waited for.
Future<void> awaitSidecar(
  AppServices services,
  String branchId, {
  VoidCallback? onWait,
  Duration limit = const Duration(minutes: 3),
}) async {
  final starting = _runsAfterEachChapter(await _setup(services))
      ? [...?_starting[branchId]]
      : const <Future<void>>[];
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

final sidecarSetupProvider = FutureProvider<SidecarSetup>((ref) {
  ref.watch(repositoryChangesProvider);
  return _setup(ref.watch(servicesProvider));
});

/// The sidecar's switches on the settings page: on after each chapter, and
/// each duty.
class SidecarSwitches extends ConsumerWidget {
  const SidecarSwitches({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(sidecarSetupProvider),
    builder: (setup) {
      final settings = setup.settings;
      Future<void> save(SidecarSettings next) async {
        try {
          await ref
              .read(repositoryProvider)
              .setSetting(SidecarSettings.key, next.toJson());
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      }

      String name(ModelConnection c) => '「${c.name} · ${c.model}」';
      final analysis = setup.analysis, writing = setup.writing;
      final note = analysis != null
          ? '默认开启：已选资料整理模型${name(analysis)}，整理用它。'
          : '默认关闭：未选能调用工具的资料整理模型，'
                '${writing == null ? '写作模型也不能调用工具，无法整理。' : '开启或手动整理时改用写作模型${name(writing)}。'}';
      return FTileGroup(
        children: [
          FTile(
            key: const Key('sidecar-enabled'),
            prefix: const Icon(FLucideIcons.sparkles),
            title: const Text('写完一章后自动整理'),
            subtitle: Text(
              note,
              overflow: TextOverflow.visible,
              softWrap: true,
            ),
            suffix: FSwitch(
              value: setup.enabled,
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
