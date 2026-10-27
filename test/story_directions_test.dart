import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/editor/workspace_screen.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft/features/reader/next_chapter.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

/// Proposes three directions when asked for them, else writes two
/// sentences, the second once [gate] allows. The first [failures] chapters
/// fail.
class _Model implements ModelProvider {
  _Model(
    this.config,
    this.requests,
    this.gate,
    this.failures,
    this.recommendation,
    this.startGate,
  );
  @override
  final ModelConnection config;
  final List<ProviderRequest> requests;
  final Future<void>? gate;
  final List<int>? failures;
  final bool recommendation;
  final Future<void>? startGate;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    requests.add(request);
    if (jsonEncode(request.messages).contains('后续走向')) {
      yield TextDelta(
        jsonEncode({
          if (recommendation)
            'recommendation': {
              'index': 1,
              'reason': '延续克制的悬疑风格，先让风暴兑现章末的危机，再推进寻父线索。',
            },
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
      if (startGate != null) {
        yield const ReasoningDelta('构思新的情节。');
        await startGate;
      }
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
  Future<void>? startGate,
  List<int>? failures,
  bool model = true,
  bool workspace = false,
  bool recommendation = true,
  String text = '风暴要来了。',
  Map<String, Object>? reader,
  Widget Function(HtmlBlockRequest)? htmlBuilder,
}) async {
  tester.view.physicalSize = workspace
      ? const Size(1400, 900)
      : const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = StoryRepository.memory();
  final services = AppServices(
    repository: repo,
    secrets: MemorySecrets(),
    modelProviderFactory: (c) async =>
        _Model(c, requests ?? [], gate, failures, recommendation, startGate),
  );
  addTearDown(services.close);
  if (model) {
    await services.saveConnection(
      ModelConnection(
        id: 'test',
        name: '测试模型',
        baseUrl: 'http://localhost:1/v1',
        model: 'test',
      ),
    );
  }
  // The sidecar's own model calls are covered in sidecar_flow_test.dart.
  await repo.setSetting(SidecarSettings.key, {'enabled': false});
  if (reader != null) await repo.setSetting('reader', reader);
  final novel = await repo.createNovel(title: '灯塔');
  final chapter = await repo.createChapter(
    branchId: novel.activeBranchId,
    name: '风暴前夜',
    content: ManuscriptContent.plainText(text),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        servicesProvider.overrideWithValue(services),
        if (htmlBuilder != null)
          htmlBlockBuilderProvider.overrideWithValue(htmlBuilder),
      ],
      child: testHost(
        workspace
            ? NovelWorkspace(novelId: novel.id)
            : ReaderScreen(branchId: novel.activeBranchId),
      ),
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
  test('chapter draft waits for prose after configured inline reasoning', () {
    String displayed(String partialText) => ChapterDraft.textOf(
      GenerationTask(
        id: 'test',
        branchId: 'test',
        kind: TaskKind.rewrite,
        status: TaskStatus.running,
        input: {
          'reasoningFormat': {
            'prefix': '<think>',
            'suffix': '</think>',
            'separator': '\n\n',
          },
        },
        partialText: partialText,
        reasoning: '',
        error: '',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    for (final text in ['', '  ', '<th', '<think>构思', '<think>构思</think>\n']) {
      expect(displayed(text), isEmpty);
    }
    expect(displayed('<think>构思</think>\n\n她推开门。'), '她推开门。');
    expect(displayed('她推开门。'), '她推开门。');
  });

  testWidgets('the model recommendation belongs to its chosen direction', (
    tester,
  ) async {
    final book = await _open(tester);
    final recommended = find.byKey(const Key('direction-1'));
    expect(
      find.descendant(of: recommended, matching: find.text('推荐')),
      findsOneWidget,
    );
    expect(find.text('推荐'), findsOneWidget);
    expect(
      find.descendant(
        of: recommended,
        matching: find.textContaining('先让风暴兑现章末的危机'),
      ),
      findsOneWidget,
    );
    expect(find.text('按推荐写下一章'), findsOneWidget);
    expect(find.text('写下一章'), findsNWidgets(2));
    expect(await _directionRuns(book), hasLength(1));
    expect(
      (await book.services.repository.getStory(book.branchId)).chapters,
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('directions without a recommendation remain usable', (
    tester,
  ) async {
    await _open(tester, recommendation: false);
    expect(find.text('推荐'), findsNothing);
    expect(find.textContaining('此批走向未附推荐'), findsOneWidget);
    expect(find.text('写下一章'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  for (final workspace in [false, true]) {
    testWidgets(
      'a direction forks and writes in ${workspace ? 'the workspace' : 'the reader'}',
      (tester) async {
        final requests = <ProviderRequest>[];
        final book = await _open(
          tester,
          requests: requests,
          workspace: workspace,
        );
        final repo = book.services.repository;
        final original = await repo.getStory(book.branchId);
        expect(find.text('分支与结局'), findsNothing);
        final adjust = find.byKey(const Key('direction-adjust-0'));
        await tester.ensureVisible(adjust);
        await tester.pumpAndSettle();
        await tester.tap(adjust);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('direction-brief-0')),
            matching: find.byType(EditableText),
          ),
          '她独自出海，先去寻找失踪的船长。',
        );
        final fork = find.byKey(const Key('direction-fork-0'));
        await tester.ensureVisible(fork);
        await tester.pumpAndSettle();
        await tester.tap(fork);
        await tester.pumpAndSettle();
        final novel = await repo.getNovel(original.novel.id);
        expect(novel.activeBranchId, isNot(book.branchId));
        expect(await repo.listBranches(novel.id), hasLength(2));
        final source = await repo.getStory(book.branchId);
        expect(source.chapters, hasLength(1));
        expect(
          source.chapters.single.revisionId,
          original.chapters.single.revisionId,
        );
        final story = await repo.getStory(novel.activeBranchId);
        expect(story.branch.parentBranchId, book.branchId);
        expect(story.branch.name, '出海');
        expect(story.chapters, hasLength(2));
        expect(
          story.chapters.first.revisionId,
          original.chapters.single.revisionId,
        );
        expect(story.chapters.last.content.text.trim(), '她推开门。她守在灯下。');
        final write = (await repo.listTasks(branchId: novel.activeBranchId))
            .singleWhere((task) => task.kind == TaskKind.writing);
        expect(write.input['brief'], '她独自出海，先去寻找失踪的船长。');
        expect(
          find.textContaining('她推开门。', findRichText: true),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('continuation appends to the current chapter only once', (
    tester,
  ) async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final requests = <ProviderRequest>[];
    final book = await _open(
      tester,
      requests: requests,
      gate: gate.future,
      reader: {'autoDirections': false},
    );
    final repo = book.services.repository;
    final original = (await repo.getStory(book.branchId)).chapters.single;
    final continuation = find.byKey(const Key('chapter-continue'));
    expect(continuation, findsOneWidget);
    await tester.ensureVisible(continuation);
    await tester.pumpAndSettle();
    await tester.tap(continuation);
    await tester.tap(continuation);
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byKey(const Key('chapter-stop')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const Key('chapter-stop')), findsOneWidget);
    expect(requests, hasLength(1));
    expect(jsonEncode(requests.single.messages), contains('风暴要来了。'));
    expect(continuation, findsNothing);
    expect(
      (await repo.getStory(book.branchId)).chapters.single.revisionId,
      original.revisionId,
    );
    gate.complete();
    await tester.pumpAndSettle();
    final chapter = (await repo.getStory(book.branchId)).chapters.single;
    expect(chapter.id, original.id);
    expect(chapter.content.text.trim(), '风暴要来了。\n\n她推开门。她守在灯下。');
    expect(
      (await repo.getRevision(original.revisionId)).content.text.trim(),
      '风暴要来了。',
    );
    expect(continuation, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('regenerating replaces the chapter and keeps its old revision', (
    tester,
  ) async {
    final gate = Completer<void>();
    final startGate = Completer<void>();
    const refusal = 'I cannot fulfill this request.';
    final requests = <ProviderRequest>[];
    final book = await _open(
      tester,
      text: refusal,
      requests: requests,
      gate: gate.future,
      startGate: startGate.future,
      reader: {'autoDirections': false},
    );
    addTearDown(() {
      if (!startGate.isCompleted) startGate.complete();
      if (!gate.isCompleted) gate.complete();
    });
    final repo = book.services.repository;
    final original = (await repo.getStory(book.branchId)).chapters.single;
    final previous = await repo.createTask(
      branchId: book.branchId,
      chapterId: original.id,
      baseRevisionId: original.revisionId,
      kind: TaskKind.writing,
      input: {
        'brief': '她在船上遇见了旧识。',
        'append': true,
        'originalContent': ManuscriptContent.plainText('').toJson(),
      },
    );
    await repo.updateTask(previous.id, status: TaskStatus.completed);
    final continuation = await repo.createTask(
      branchId: book.branchId,
      chapterId: original.id,
      baseRevisionId: original.revisionId,
      kind: TaskKind.writing,
      input: {
        'brief': '只输出要追加的正文。',
        'append': true,
        'originalContent': original.content.toJson(),
      },
    );
    await repo.updateTask(continuation.id, status: TaskStatus.completed);
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
    expect(jsonEncode(requests.single.messages), isNot(contains(refusal)));
    expect(jsonEncode(requests.single.messages), isNot(contains('只输出要追加的正文')));
    expect(find.textContaining(refusal, findRichText: true), findsOneWidget);
    // Progress writes use a real stopwatch, independent of the widget clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 270)),
    );
    startGate.complete();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find
          .textContaining('她推开门。', findRichText: true)
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(find.textContaining('她推开门。', findRichText: true), findsOneWidget);
    expect(find.textContaining(refusal, findRichText: true), findsNothing);
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

  for (final stop in ['cancel', 'fail']) {
    testWidgets('$stop after regeneration starts restores the saved chapter', (
      tester,
    ) async {
      final gate = Completer<void>();
      final book = await _open(
        tester,
        gate: gate.future,
        reader: {'autoDirections': false},
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final repo = book.services.repository;
      final original = (await repo.getStory(book.branchId)).chapters.single;
      final again = find.byKey(const Key('chapter-regenerate'));
      await tester.ensureVisible(again);
      await tester.pumpAndSettle();
      await tester.tap(again);
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find
            .textContaining('她推开门。', findRichText: true)
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      expect(find.textContaining('她推开门。', findRichText: true), findsOneWidget);
      expect(find.textContaining('风暴要来了。', findRichText: true), findsNothing);
      if (stop == 'cancel') {
        await tester.tap(find.byKey(const Key('chapter-stop')));
        await tester.pump();
        gate.complete();
      } else {
        gate.completeError(const ProviderException('interrupted', '连接中断'));
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('风暴要来了。', findRichText: true), findsOneWidget);
      expect(
        (await repo.getStory(book.branchId)).chapters.single.revisionId,
        original.revisionId,
      );
      expect(
        find.textContaining(stop == 'cancel' ? '已停止。' : '连接中断'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in ['regenerate', 'continue']) {
    testWidgets('failed $action keeps the chapter and can be retried', (
      tester,
    ) async {
      final requests = <ProviderRequest>[];
      final book = await _open(
        tester,
        failures: [1],
        requests: requests,
        reader: {'autoDirections': false},
      );
      final again = find.byKey(Key('chapter-$action'));
      await tester.ensureVisible(again);
      await tester.pumpAndSettle();
      await tester.tap(again);
      await tester.pumpAndSettle();
      final repo = book.services.repository;
      expect(
        (await repo.getStory(book.branchId)).chapters.single.content.text
            .trim(),
        '风暴要来了。',
      );
      expect(find.textContaining('模型服务暂时不可用'), findsOneWidget);
      final retry = find.byKey(const Key('chapter-again'));
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(
        (await repo.getStory(book.branchId)).chapters.single.content.text
            .trim(),
        action == 'continue' ? '风暴要来了。\n\n她推开门。她守在灯下。' : '她推开门。她守在灯下。',
      );
      expect(
        '重新写当前章节的完整正文'.allMatches(jsonEncode(requests.last.messages)),
        hasLength(action == 'continue' ? 0 : 1),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('$action preserves edits made while the model is writing', (
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
      final again = find.byKey(Key('chapter-$action'));
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
        (await repo.getStory(book.branchId)).chapters.single.content.text
            .trim(),
        '作者刚改好的正文。',
      );
      final pending = await repo.listProposals(
        book.branchId,
        status: ProposalStatus.pending,
      );
      expect(pending, hasLength(1));
      expect(
        pending.single.content.text.trim(),
        action == 'continue' ? '风暴要来了。\n\n她推开门。她守在灯下。' : '她推开门。她守在灯下。',
      );
      expect(find.textContaining('这一章没有自动写入'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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

  const inputPage = '```html\n<html><body>选择下一步</body></html>\n```';

  testWidgets('preset input writes one next chapter and keeps the original', (
    tester,
  ) async {
    final requests = <ProviderRequest>[];
    final gate = Completer<void>();
    late TavernBridge bridge;
    final book = await _open(
      tester,
      requests: requests,
      gate: gate.future,
      text: inputPage,
      reader: {'autoDirections': false},
      htmlBuilder: (request) {
        bridge = request.bridge!;
        return const Text('预设选项');
      },
    );
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    const brief = '走进山洞 | 保留 /cut 原文';
    final first = bridge.handleMessage(
      jsonEncode({
        'id': 1,
        'method': 'continueWriting',
        'args': [brief],
      }),
    );
    for (
      var i = 0;
      i < 100 && find.byKey(const Key('chapter-draft')).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(requests, hasLength(1));
    expect((await first).ok, isTrue);
    expect(jsonEncode(requests.single.messages), contains(brief));
    expect(find.text('生成正文'), findsNothing);
    expect(find.byKey(const Key('chapter-draft')), findsOneWidget);
    final duplicate = await bridge.handleMessage(
      jsonEncode({
        'id': 2,
        'method': 'continueWriting',
        'args': [brief],
      }),
    );
    expect(duplicate.ok, isFalse);
    expect(requests, hasLength(1));
    gate.complete();
    await tester.pumpAndSettle();
    final story = await book.services.repository.getStory(book.branchId);
    expect(story.chapters, hasLength(2));
    expect(story.chapters.first.content.text.trim(), inputPage);
    expect(story.chapters.last.content.text, contains('她推开门。她守在灯下。'));
    expect(
      await book.services.repository.listProposals(
        book.branchId,
        status: ProposalStatus.pending,
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('preset input without a writing model leaves the story intact', (
    tester,
  ) async {
    late TavernBridge bridge;
    final book = await _open(
      tester,
      model: false,
      text: inputPage,
      reader: {'autoDirections': false},
      htmlBuilder: (request) {
        bridge = request.bridge!;
        return const Text('预设选项');
      },
    );
    Object? error;
    bridge
        .handleMessage(
          jsonEncode({
            'id': 1,
            'method': 'continueWriting',
            'args': ['走进山洞'],
          }),
        )
        .then((result) => error = result.ok ? null : result.payload);
    await tester.pumpAndSettle();
    expect(error, contains('写作模型连接'));
    expect(
      (await book.services.repository.getStory(book.branchId)).chapters,
      hasLength(1),
    );
  });

  testWidgets('a chapter that failed waits on its page and is written again', (
    tester,
  ) async {
    final book = await _open(tester, failures: [1]);
    final pick = find.byKey(const Key('direction-continue-0'));
    await Scrollable.ensureVisible(tester.element(pick), alignment: 0.5);
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

  testWidgets('a one-tap write tells of entries the budget left out', (
    tester,
  ) async {
    final book = await _open(tester);
    final repo = book.services.repository;
    await repo.storeResource(
      id: 'book',
      kind: ResourceKind.worldBook,
      name: '灯塔设定',
      filename: 'book.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: {
        'name': '灯塔设定',
        'entries': {
          '1': {'uid': 1, 'constant': true, 'content': '旧灯塔'},
        },
      },
    );
    await repo.setSetting('writing/${book.branchId}', {
      'worldBookIds': ['book'],
    });
    await repo.setSetting(
      WorldInfoBudget.settingKey,
      const WorldInfoBudget(cap: 1).toJson(),
    );
    final pick = find.byKey(const Key('direction-continue-0'));
    await tester.ensureVisible(pick);
    await tester.pumpAndSettle();
    await tester.tap(pick);
    await tester.pumpAndSettle();
    // Written all the same; the notice says why and how to raise it.
    final story = await repo.getStory(book.branchId);
    expect(story.chapters.last.content.text, contains('她守在灯下。'));
    expect(
      find.textContaining('世界书预算不够，1 个条目未放入。本次预算 1 token，受「预算上限」限制'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('world-book-budget-notice')));
    await tester.pumpAndSettle();
    expect(find.textContaining('世界书预算不够'), findsNothing);
    await tester.enterText(find.byKey(const Key('world-info-budget-cap')), '0');
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(
      WorldInfoBudget.fromJson(
        await repo.getSetting(WorldInfoBudget.settingKey),
      ).cap,
      0,
    );
    expect(tester.takeException(), isNull);
  });

  for (final fork in [false, true]) {
    testWidgets(
      'a ${fork ? 'forked' : 'current'} write that cannot start says why',
      (tester) async {
        final book = await _open(tester);
        // Limit writing only after the directions have been generated.
        final connection = (await book.services.connections()).single;
        await book.services.saveConnection(
          ModelConnection.fromJson({...connection.raw, 'contextWindow': 2300}),
        );
        await tester.pumpAndSettle();
        final pick = find.byKey(
          Key('direction-${fork ? 'fork' : 'continue'}-0'),
        );
        await Scrollable.ensureVisible(tester.element(pick), alignment: 0.5);
        await tester.pumpAndSettle();
        await tester.tap(pick);
        await tester.pumpAndSettle();
        final repo = book.services.repository;
        final source = await repo.getStory(book.branchId);
        final novel = await repo.getNovel(source.novel.id);
        final story = await repo.getStory(novel.activeBranchId);
        expect(story.chapters, hasLength(2));
        if (fork) {
          expect(novel.activeBranchId, isNot(book.branchId));
          expect(source.chapters, hasLength(1));
          expect(story.chapters.last.content.text.trim(), isEmpty);
          expect(find.text(story.chapters.last.title), findsWidgets);
        }
        expect(find.textContaining('的上下文装不下这次写作'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

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
      expect(
        jsonEncode(requests.last.messages),
        isNot(contains('先让风暴兑现章末的危机')),
      );

      gate.complete();
      await tester.pumpAndSettle();
      final story = await repo.getStory(book.branchId);
      expect(story.chapters.map((c) => c.title), ['第一章 风暴前夜', '第二章 留守']);
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
      expect(
        tester.getRect(find.byKey(const Key('directions-again'))).bottom,
        lessThanOrEqualTo(bar),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
