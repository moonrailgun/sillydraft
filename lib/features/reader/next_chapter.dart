import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_providers.dart';
import '../resources/writing_profile.dart';

const _digits = '零一二三四五六七八九';
const _values = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};
const _units = {'十': 10, '百': 100, '千': 1000};

/// [n] in Chinese numerals, as chapter numbers are written: 十二, 一百零五.
String chineseNumber(int n) {
  if (n <= 0 || n >= 10000) return '$n';
  final out = StringBuffer();
  var zero = false;
  for (final (unit, name) in [(1000, '千'), (100, '百'), (10, '十'), (1, '')]) {
    final d = n ~/ unit % 10;
    if (d == 0) {
      zero = out.isNotEmpty;
      continue;
    }
    if (zero) out.write('零');
    zero = false;
    // 十二, not 一十二, when the tens lead.
    if (!(unit == 10 && d == 1 && out.isEmpty)) out.write(_digits[d]);
    out.write(name);
  }
  return '$out';
}

/// The number in a chapter title such as 第十二章 or 第12章.
({int number, bool arabic})? _chapterNumber(String title) {
  final match = RegExp(r'^第([0-9]+|[零〇一二两三四五六七八九十百千]+)章').firstMatch(title);
  if (match == null) return null;
  final text = match.group(1)!;
  final arabic = int.tryParse(text);
  if (arabic != null) return (number: arabic, arabic: true);
  var total = 0, digit = 0;
  for (final c in text.split('')) {
    if (_values[c] case final v?) {
      digit = v;
    } else {
      total += (digit == 0 ? 1 : digit) * _units[c]!;
      digit = 0;
    }
  }
  return (number: total + digit, arabic: false);
}

/// The title of the chapter after [chapters], numbered the way the book
/// numbers its chapters, then [name].
String nextChapterTitle(List<Chapter> chapters, String name) {
  final last = chapters.lastOrNull;
  final found = last == null ? null : _chapterNumber(last.title);
  final n = (found?.number ?? chapters.length) + 1;
  final number = found?.arabic == true ? '$n' : chineseNumber(n);
  return '第$number章 ${name.trim()}'.trim();
}

/// The brief that writes the next chapter along [direction].
String chapterBrief(Map direction) =>
    '写下一章《${direction['title']}》：沿下面这个走向展开，自然衔接上一章的结尾，'
    '保持人物动机与叙事视角一致。只写这一章的正文，不重复已有内容。\n'
    '${direction['summary']}';

/// Writes [scene] from [brief] with the branch's preset, card and books, and
/// takes the result into the scene as soon as it is written, story state
/// included, so every chapter keeps its own snapshot to fork or roll back
/// to.
Future<GenerationTask> writeScene(
  WidgetRef ref,
  Scene scene, {
  required String brief,
}) async {
  final services = ref.read(servicesProvider);
  final connection = await services.connectionFor('writing');
  if (connection == null) throw const FormatException('请先在设置里添加写作模型连接。');
  final profile = await WritingContext.load(services, scene.branchId);
  return services.writing.startPrepared(
    await services.writing.prepare(
      branchId: scene.branchId,
      sceneId: scene.id,
      connection: connection,
      brief: brief,
      append: true,
      preset: profile.preset,
      card: profile.card,
      userName: profile.userName,
      persona: profile.persona,
      worldBooks: profile.books,
      globalRegex: profile.regex,
      selectedOrderId: profile.selectedOrderId,
      expectedRevisionId: scene.revisionId,
      autoAccept: true,
    ),
  );
}

/// Starts the next chapter of [story] along [brief] and returns its scene:
/// a new chapter at the end, or the last one when it is still empty, as an
/// earlier attempt may have left it.
Future<Scene> startNextChapter(
  WidgetRef ref,
  StorySnapshot story, {
  required String name,
  required String brief,
}) async {
  final services = ref.read(servicesProvider), repo = services.repository;
  // No chapter for a request that cannot run.
  if (await services.connectionFor('writing') == null) {
    throw const FormatException('请先在设置里添加写作模型连接。');
  }
  final last = story.scenes.lastOrNull;
  final Scene scene;
  if (last != null && last.content.text.trim().isEmpty) {
    final chapter = story.chapters.firstWhere((c) => c.id == last.chapterId);
    final alone = story.scenesInChapter(chapter.id).length == 1;
    final title = alone
        ? nextChapterTitle(
            story.chapters.take(story.chapters.indexOf(chapter)).toList(),
            name,
          )
        : name;
    if (alone) {
      await repo.renameChapter(
        branchId: story.branch.id,
        chapterId: chapter.id,
        title: title,
      );
    }
    await repo.renameScene(
      branchId: story.branch.id,
      sceneId: last.id,
      title: title,
    );
    scene = await repo.getScene(branchId: story.branch.id, sceneId: last.id);
  } else {
    final title = nextChapterTitle(story.chapters, name);
    final chapter = await repo.createChapter(
      branchId: story.branch.id,
      title: title,
    );
    scene = await repo.createScene(
      branchId: story.branch.id,
      chapterId: chapter.id,
      title: title,
    );
  }
  await writeScene(ref, scene, brief: brief);
  return scene;
}

/// An empty scene being written: the text as it arrives, set like the rest
/// of the book, which becomes the scene's text once written. A failure, or
/// a result that could not be taken in because the scene or the story state
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
    await writeScene(
      ref,
      await repo.getScene(branchId: task.branchId, sceneId: task.sceneId!),
      brief: task.input['brief'] as String? ?? '',
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
