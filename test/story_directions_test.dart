import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/reader/next_chapter.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

/// Proposes three directions when asked for them, else writes two
/// sentences, the second once [gate] allows. The first [failures] chapters
/// fail.
class _Model implements ModelProvider {
  _Model(this.config, this.requests, [this.gate, this.failures]);
  @override
  final ModelConnection config;
  final List<ProviderRequest> requests;
  final Future<void>? gate;
  final List<int>? failures;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    requests.add(request);
    if (jsonEncode(request.messages).contains('后续走向')) {
      yield TextDelta(
        jsonEncode({
          'candidates': [
            for (final (title, summary) in [
              ('出海', '她登上货船，追查父亲的下落'),
              ('留守', '她守住灯塔，等风暴过去'),
              ('报信', '她连夜赶往镇上报信'),
            ])
              {'title': title, 'summary': summary, 'opening': '$title。'},
          ],
        }),
      );
    } else {
      if (failures case final f? when f.first > 0) {
        f.first--;
        throw const ProviderException('http_500', '模型服务暂时不可用');
      }
      yield const TextDelta('她推开门。');
      await gate;
      yield const TextDelta('她守在灯下。');
    }
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => ['test'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

typedef _Open = ({AppServices services, String branchId, String chapterId});

/// A one-chapter book in the reader, with a model that answers when [model].
Future<_Open> _open(
  WidgetTester tester, {
  List<ProviderRequest>? requests,
  Future<void>? gate,
  List<int>? failures,
  bool model = true,
  int contextWindow = 200000,
  String text = '风暴要来了。',
  Map<String, Object>? reader,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = StoryRepository.memory();
  final services = AppServices(
    repository: repo,
    secrets: MemorySecrets(),
    modelProviderFactory: (c) async =>
        _Model(c, requests ?? [], gate, failures),
  );
  addTearDown(services.close);
  if (model) {
    await services.saveConnection(
      ModelConnection(
        id: 'test',
        name: '测试模型',
        baseUrl: 'http://localhost:1/v1',
        model: 'test',
        contextWindow: contextWindow,
      ),
    );
  }
  if (reader != null) await repo.setSetting('reader', reader);
  final novel = await repo.createNovel(title: '灯塔');
  final chapter = await repo.createChapter(
    branchId: novel.activeBranchId,
    title: '风暴前夜',
    content: ManuscriptContent.plainText(text),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(ReaderScreen(branchId: novel.activeBranchId)),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  return (
    services: services,
    branchId: novel.activeBranchId,
    chapterId: chapter.id,
  );
}

Future<List<GenerationTask>> _directionRuns(_Open book) async => [
  for (final t in await book.services.repository.listTasks(
    branchId: book.branchId,
  ))
    if (t.kind == TaskKind.branches) t,
];

void main() {
  testWidgets('regenerating replaces the chapter and keeps its old revision', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    const refusal = 'I cannot fulfill this request.';
    final requests = <ProviderRequest>[];
    final book = await _open(
      tester,
      text: refusal,
      requests: requests,
      gate: gate.future,
      reader: {'autoDirections': false},
    );
    final repo = book.services.repository;
    final original = (await repo.getStory(book.branchId)).chapters.single;
    final previous = await repo.createTask(
      branchId: book.branchId,
      chapterId: original.id,
      baseRevisionId: original.revisionId,
      kind: TaskKind.writing,
      input: {'brief': '她在船上遇见了旧识。'},
    );
    await repo.updateTask(previous.id, status: TaskStatus.completed);
    await tester.pumpAndSettle();
    final again = find.byKey(const Key('chapter-regenerate'));
    expect(again, findsOneWidget);
    await tester.ensureVisible(again);
    await tester.pumpAndSettle();
    await tester.tap(again);
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byKey(const Key('chapter-stop')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const Key('chapter-stop')), findsOneWidget);
    expect(jsonEncode(requests.single.messages), contains('她在船上遇见了旧识。'));
    expect(jsonEncode(requests.single.messages), contains('重新写当前章节的完整正文'));
    expect(find.byKey(const Key('chapter-regenerate')), findsNothing);
    expect(
      (await repo.getStory(book.branchId)).chapters.single.revisionId,
      original.revisionId,
    );
    gate.complete();
    await tester.pumpAndSettle();
    final chapter = (await repo.getStory(book.branchId)).chapters.single;
    expect(chapter.id, original.id);
    expect(chapter.content.text.trim(), '她推开门。她守在灯下。');
    expect(
      (await repo.getRevision(original.revisionId)).content.text.trim(),
      refusal,
    );
    expect(find.byKey(const Key('chapter-regenerate')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed regeneration keeps the chapter and can be retried', (
    tester,
  ) async {
    final requests = <ProviderRequest>[];
    final book = await _open(
      tester,
      failures: [1],
      requests: requests,
      reader: {'autoDirections': false},
    );
    final again = find.byKey(const Key('chapter-regenerate'));
    await tester.ensureVisible(again);
    await tester.pumpAndSettle();
    await tester.tap(again);
    await tester.pumpAndSettle();
    final repo = book.services.repository;
    expect(
      (await repo.getStory(book.branchId)).chapters.single.content.text.trim(),
      '风暴要来了。',
    );
    expect(find.textContaining('模型服务暂时不可用'), findsOneWidget);
    final retry = find.byKey(const Key('chapter-again'));
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(
      (await repo.getStory(book.branchId)).chapters.single.content.text.trim(),
      '她推开门。她守在灯下。',
    );
    expect(
      '重新写当前章节的完整正文'.allMatches(jsonEncode(requests.last.messages)),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('regeneration preserves edits made while the model is writing', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final book = await _open(
      tester,
      gate: gate.future,
      reader: {'autoDirections': false},
    );
    final repo = book.services.repository;
    final original = (await repo.getStory(book.branchId)).chapters.single;
    final again = find.byKey(const Key('chapter-regenerate'));
    await tester.ensureVisible(again);
    await tester.pumpAndSettle();
    await tester.tap(again);
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byKey(const Key('chapter-stop')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const Key('chapter-stop')), findsOneWidget);
    await repo.saveChapter(
      branchId: book.branchId,
      chapterId: original.id,
      expectedRevisionId: original.revisionId,
      content: ManuscriptContent.plainText('作者刚改好的正文。'),
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      (await repo.getStory(book.branchId)).chapters.single.content.text.trim(),
      '作者刚改好的正文。',
    );
    final pending = await repo.listProposals(
      book.branchId,
      status: ProposalStatus.pending,
    );
    expect(pending, hasLength(1));
    expect(pending.single.content.text.trim(), '她推开门。她守在灯下。');
    expect(find.textContaining('这一章没有自动写入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual candidates keep their review flow in a saved chapter', (
    tester,
  ) async {
    final book = await _open(tester, reader: {'autoDirections': false});
    final repo = book.services.repository;
    final chapter = (await repo.getStory(book.branchId)).chapters.single;
    final task = await repo.createTask(
      branchId: book.branchId,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      kind: TaskKind.rewrite,
      input: {'brief': '修改对话'},
    );
    final proposal = await repo.createProposal(
      branchId: book.branchId,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('待审阅的正文。'),
      taskId: task.id,
    );
    await repo.updateTask(
      task.id,
      status: TaskStatus.completed,
      result: {'proposalId': proposal.id},
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chapter-draft')), findsNothing);
    expect(find.byKey(const Key('chapter-regenerate')), findsOneWidget);
    expect(
      (await repo.getProposal(proposal.id)).status,
      ProposalStatus.pending,
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'the next chapter is numbered the way the book numbers its chapters',
    () {
      Chapter chapter(String title) => Chapter(
        id: title,
        branchId: 'b',
        title: title,
        position: 0,
        revisionId: 'r',
        content: ManuscriptContent.plainText(''),
      );
      expect(nextChapterTitle([], '开端'), '第一章 开端');
      expect(nextChapterTitle([chapter('一')], '出海'), '第二章 出海');
      expect(nextChapterTitle([chapter('第十九章 雨')], '晴'), '第二十章 晴');
      expect(nextChapterTitle([chapter('第一百零四章')], '归'), '第一百零五章 归');
      expect(nextChapterTitle([chapter('第12章 码头')], '灯塔'), '第13章 灯塔');
      expect(
        [
          for (final n in [10, 12, 20, 110, 1001]) chineseNumber(n),
        ],
        ['十', '十二', '二十', '一百一十', '一千零一'],
      );
    },
  );

  testWidgets('a chapter that failed waits on its page and is written again', (
    tester,
  ) async {
    final book = await _open(tester, failures: [1]);
    final pick = find.byKey(const Key('direction-continue-0'));
    await tester.ensureVisible(pick);
    await tester.pumpAndSettle();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    expect(find.text('第二章 出海'), findsWidgets);
    expect(find.textContaining('模型服务暂时不可用'), findsOneWidget);
    final again = find.byKey(const Key('chapter-again'));
    await tester.ensureVisible(again);
    await tester.pumpAndSettle();
    await tester.tap(again);
    await tester.pumpAndSettle();
    final story = await book.services.repository.getStory(book.branchId);
    // Written into the same chapter: no second one for the retry.
    expect(story.chapters, hasLength(2));
    expect(story.chapters.last.content.text, contains('她守在灯下。'));
    expect(find.byKey(const Key('chapter-draft')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a write that cannot start says why in plain words', (
    tester,
  ) async {
    // Room for the directions, not for a chapter with 2048 tokens of reply.
    final book = await _open(tester, contextWindow: 2300);
    final pick = find.byKey(const Key('direction-continue-0'));
    await tester.ensureVisible(pick);
    await tester.pumpAndSettle();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    final story = await book.services.repository.getStory(book.branchId);
    expect(story.chapters, hasLength(2));
    expect(find.textContaining('的上下文装不下这次写作'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'directions come by themselves, and picking one writes the next chapter in place',
    (tester) async {
      final requests = <ProviderRequest>[];
      final gate = Completer<void>();
      final book = await _open(tester, requests: requests, gate: gate.future);
      // A failed check must not leave the writer waiting at closing time.
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final repo = book.services.repository;
      // Nothing to press: a short chapter shows its end at once.
      expect(find.text('1. 出海'), findsOneWidget);
      expect(find.text('2. 留守'), findsOneWidget);
      expect(find.text('3. 报信'), findsOneWidget);
      expect(await _directionRuns(book), hasLength(1));

      final before = (await repo.getBranchVariables(book.branchId)).version;
      final pick = find.byKey(const Key('direction-continue-1'));
      await tester.ensureVisible(pick);
      await tester.pumpAndSettle();
      await tester.tap(pick);
      // The text keeps arriving, so the page never settles meanwhile.
      for (
        var i = 0;
        i < 100 &&
            find.textContaining('她推开门。', findRichText: true).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      // The page turns to the new chapter and the text arrives on it; no
      // task page, no review.
      expect(find.text('生成任务'), findsNothing);
      expect(find.text('第二章 留守'), findsWidgets);
      expect(find.byKey(const Key('chapter-draft')), findsOneWidget);
      expect(find.textContaining('她推开门。', findRichText: true), findsOneWidget);
      expect(jsonEncode(requests.last.messages), contains('她守住灯塔，等风暴过去'));

      gate.complete();
      await tester.pumpAndSettle();
      final story = await repo.getStory(book.branchId);
      expect(story.chapters.map((c) => c.title), ['风暴前夜', '第二章 留守']);
      expect(story.chapters.first.content.text.trim(), '风暴要来了。');
      expect(story.chapters.last.title, '第二章 留守');
      expect(story.chapters.last.content.text, contains('她推开门。她守在灯下。'));
      // Taken in by itself, committing the chapter's story state with it
      // (per-chapter snapshots are checked in the core tests).
      expect(
        await repo.listProposals(book.branchId, status: ProposalStatus.pending),
        isEmpty,
      );
      expect(
        (await repo.getBranchVariables(book.branchId)).version,
        before + 1,
      );
      expect(find.byKey(const Key('chapter-draft')), findsNothing);
      expect(find.textContaining('她守在灯下。', findRichText: true), findsOneWidget);

      // The new end has new directions of its own.
      final end = find.byKey(const Key('story-directions'));
      await tester.ensureVisible(end);
      await tester.pumpAndSettle();
      expect(await _directionRuns(book), hasLength(2));
      expect(find.text('1. 出海'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an adjusted brief writes the chapter from the edit', (
    tester,
  ) async {
    final requests = <ProviderRequest>[];
    final book = await _open(tester, requests: requests);
    final adjust = find.byKey(const Key('direction-adjust-0'));
    await tester.ensureVisible(adjust);
    await tester.pumpAndSettle();
    await tester.tap(adjust);
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('direction-brief-0'));
    expect(field, findsOneWidget);
    await tester.enterText(
      find.descendant(of: field, matching: find.byType(EditableText)),
      '写下一章：她在船上遇见了旧识。',
    );
    final write = find.byKey(const Key('direction-continue-0'));
    await tester.ensureVisible(write);
    await tester.pumpAndSettle();
    await tester.tap(write);
    await tester.pumpAndSettle();
    // The chapter's own request; the new end then asks for directions.
    final writing = requests.where(
      (r) => !jsonEncode(r.messages).contains('后续走向'),
    );
    expect(jsonEncode(writing.last.messages), contains('她在船上遇见了旧识'));
    final story = await book.services.repository.getStory(book.branchId);
    expect(story.chapters.last.title, '第二章 出海');
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a model, or with the setting off, nothing is called', (
    tester,
  ) async {
    final none = await _open(tester, model: false);
    expect(find.byKey(const Key('directions-suggest')), findsOneWidget);
    expect(await _directionRuns(none), isEmpty);
    await tester.pumpWidget(const SizedBox());

    final off = await _open(tester, reader: {'autoDirections': false});
    final suggest = find.byKey(const Key('directions-suggest'));
    expect(suggest, findsOneWidget);
    expect(await _directionRuns(off), isEmpty);
    await tester.ensureVisible(suggest);
    await tester.pumpAndSettle();
    await tester.tap(suggest);
    await tester.pumpAndSettle();
    expect(find.text('1. 出海'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'directions wait for the end to come into view, and the end clears the bars',
    (tester) async {
      final book = await _open(
        tester,
        text: List.generate(60, (i) => '第 $i 段：雾从港口升起。').join('\n'),
      );
      expect(await _directionRuns(book), isEmpty);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byType(SingleChildScrollView).first,
          )
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(await _directionRuns(book), hasLength(1));
      expect(find.text('1. 出海'), findsOneWidget);

      // With the bars showing, the last control still scrolls above the
      // bottom bar.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.textContaining('本章约剩')).top;
      expect(tester.getRect(find.text('分支与结局')).bottom, lessThanOrEqualTo(bar));
      expect(tester.takeException(), isNull);
    },
  );
}
