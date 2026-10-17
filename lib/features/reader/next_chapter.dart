import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../lore/sidecar.dart';
import '../resources/writing_profile.dart';
import '../settings/world_info_budget.dart';

/// The brief that writes the next chapter along [direction].
String chapterBrief(Map direction) =>
    '写下一章《${direction['title']}》：沿下面这个走向展开，自然衔接上一章的结尾，'
    '保持人物动机与叙事视角一致。只写这一章的正文，不重复已有内容。\n'
    '${direction['summary']}';

/// Writes [chapter] from [brief] with the branch's preset, card and books, and
/// takes the result into the chapter as soon as it is written, story state
/// included, so every chapter keeps its own snapshot to fork or roll back
/// to.
Future<GenerationTask> writeChapter(
  WidgetRef ref,
  Chapter chapter, {
  required String brief,
  bool rewrite = false,
  VoidCallback? onWaitSidecar,

  /// Told the summary when the world info budget left entries out; the
  /// write goes on regardless.
  ValueChanged<String>? onBudgetDrop,
}) async {
  final services = ref.read(servicesProvider);
  final connection = await services.connectionFor('writing');
  if (connection == null) throw const FormatException('请先在设置里添加写作模型连接。');
  // Written with what the sidecar records about the chapter before.
  await awaitSidecar(services, chapter.branchId, onWait: onWaitSidecar);
  final profile = await WritingContext.load(services, chapter.branchId);
  const rewriteInstruction = '重新写当前章节的完整正文，替换当前版本，不要续写或输出说明。\n原写作要求：\n';
  if (rewrite && !brief.startsWith(rewriteInstruction)) {
    brief = '$rewriteInstruction$brief';
  }
  final draft = await services.writing.prepare(
    branchId: chapter.branchId,
    chapterId: chapter.id,
    connection: connection,
    brief: brief,
    append: !rewrite,
    rewrite: rewrite,
    preset: profile.preset,
    card: profile.card,
    userName: profile.userName,
    persona: profile.persona,
    worldBooks: profile.books,
    globalRegex: profile.regex,
    selectedOrderId: profile.selectedOrderId,
    expectedRevisionId: chapter.revisionId,
    autoAccept: true,
  );
  final task = await services.writing.startPrepared(draft);
  for (final d in draft.compiled['diagnostics'] as List) {
    if (d['code'] == 'world_book_budget_summary') {
      onBudgetDrop?.call(d['message'] as String);
    }
  }
  // Held from now, so a next chapter started the moment this one is
  // written still waits for its sidecar.
  holdForSidecar(chapter.branchId, _afterWritten(services, task));
  return task;
}

/// Once [task] has written its chapter: names a chapter titled only by its
/// number, with the analysis model when one is set up, then starts the
/// sidecar on the text that was taken in, so its notes carry that name.
Future<void> _afterWritten(AppServices services, GenerationTask task) async {
  final done = await services.runner.wait(task.id);
  if (done.status != TaskStatus.completed) return;
  try {
    final connection =
        await services.connectionFor('analysis') ??
        await services.connectionFor('writing');
    if (connection != null) {
      await services.writing.nameChapter(
        branchId: done.branchId,
        chapterId: done.chapterId!,
        connection: connection,
      );
    }
  } catch (_) {
    // A name is a nicety: on failure the chapter keeps its number.
  }
  // A result left for review is not the chapter's text yet; accepting it
  // starts the sidecar instead.
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

/// Starts the next chapter of [story] along [brief] and returns its chapter:
/// a new chapter at the end, or the last one when it is still empty, as an
/// earlier attempt may have left it.
Future<Chapter> startNextChapter(
  WidgetRef ref,
  StorySnapshot story, {
  required String name,
  required String brief,
  VoidCallback? onWaitSidecar,
  ValueChanged<String>? onBudgetDrop,
}) async {
  final services = ref.read(servicesProvider), repo = services.repository;
  // No chapter for a request that cannot run.
  if (await services.connectionFor('writing') == null) {
    throw const FormatException('请先在设置里添加写作模型连接。');
  }
  final last = story.chapters.lastOrNull;
  final Chapter chapter;
  if (last != null && last.content.text.trim().isEmpty) {
    await repo.renameChapter(
      branchId: story.branch.id,
      chapterId: last.id,
      name: name,
    );
    chapter = await repo.getChapter(
      branchId: story.branch.id,
      chapterId: last.id,
    );
  } else {
    chapter = await repo.createChapter(branchId: story.branch.id, name: name);
  }
  await writeChapter(
    ref,
    chapter,
    brief: brief,
    onWaitSidecar: onWaitSidecar,
    onBudgetDrop: onBudgetDrop,
  );
  return chapter;
}

/// A chapter being written: the text as it arrives, set like the rest
/// of the book, which becomes the chapter's text once written. A failure, or
/// a result that could not be taken in because the chapter or the story state
/// changed meanwhile, waits here for the author.
class ChapterDraft extends ConsumerStatefulWidget {
  const ChapterDraft({
    super.key,
    required this.task,
    required this.prose,
    this.controls = _same,
  });
  final GenerationTask task;

  /// Sets text the way the page sets the book.
  final Widget Function(String text) prose;

  /// Wraps the buttons, e.g. so tapping them never turns the page.
  final Widget Function(Widget child) controls;
  static Widget _same(Widget child) => child;
  @override
  ConsumerState<ChapterDraft> createState() => _ChapterDraftState();
}

class _ChapterDraftState extends ConsumerState<ChapterDraft> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _again(ManuscriptProposal? pending) => _run(() async {
    final repo = ref.read(repositoryProvider), task = widget.task;
    if (pending != null) await repo.rejectProposal(pending.id);
    await writeChapter(
      ref,
      await repo.getChapter(
        branchId: task.branchId,
        chapterId: task.chapterId!,
      ),
      brief: task.input['brief'] as String? ?? '',
      rewrite: task.kind == TaskKind.rewrite,
      onWaitSidecar: () => toast(context, sidecarWaitNotice),
      onBudgetDrop: (summary) => showWorldInfoBudgetNotice(context, summary),
    );
  });

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final pending =
        (ref.watch(proposalsProvider(task.branchId)).value ?? const [])
            .where(
              (p) =>
                  p.id == task.result['proposalId'] &&
                  p.status == ProposalStatus.pending,
            )
            .firstOrNull;
    final text = pending?.content.text.trim() ?? task.partialText.trim();
    Widget button(
      String label,
      VoidCallback onPress, {
      Key? key,
      IconData? icon,
      bool primary = false,
    }) => FButton(
      key: key,
      variant: primary ? FButtonVariant.primary : FButtonVariant.outline,
      size: FButtonSizeVariant.sm,
      mainAxisSize: MainAxisSize.min,
      onPress: _busy ? null : onPress,
      prefix: icon == null ? null : Icon(icon),
      child: Text(label),
    );
    final String status;
    final List<Widget> actions;
    if (task.isActive) {
      status = text.isEmpty ? '正在构思这一章…' : '正在写这一章…';
      actions = [
        button(
          '停止',
          () => _run(() => ref.read(servicesProvider).runner.cancel(task.id)),
          key: const Key('chapter-stop'),
          icon: FLucideIcons.circleStop,
        ),
      ];
    } else if (pending != null) {
      status = '正文或故事变量在生成期间有变化，这一章没有自动写入。';
      actions = [
        button(
          '写入这一章',
          () => _run(() async {
            await ref.read(repositoryProvider).acceptProposal(pending.id);
            startSidecarQuietly(
              ref.read(servicesProvider),
              branchId: pending.branchId,
              chapterId: pending.chapterId,
            );
          }),
          key: const Key('chapter-accept'),
          primary: true,
        ),
        button('重新生成', () => _again(pending), icon: FLucideIcons.refreshCw),
      ];
    } else {
      status = task.error.isNotEmpty
          ? task.error
          : task.status == TaskStatus.cancelled
          ? '已停止。'
          : '这一章没有写完。';
      actions = [
        button(
          '重新生成',
          () => _again(null),
          key: const Key('chapter-again'),
          icon: FLucideIcons.refreshCw,
          primary: true,
        ),
      ];
    }
    return Column(
      key: const Key('chapter-draft'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (text.isNotEmpty) widget.prose(text),
        const SizedBox(height: 20),
        if (task.isActive) ...[const FProgress(), const SizedBox(height: 8)],
        Text(status, textAlign: TextAlign.center, style: muted),
        const SizedBox(height: 10),
        widget.controls(
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          ),
        ),
      ],
    );
  }
}
