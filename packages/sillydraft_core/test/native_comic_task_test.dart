import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'comic_task_test.dart' show ComicTextModel, ComicImageModel;

void main() {
  late StoryRepository repo;
  late TaskRunner runner;
  late ComicService service;
  late Novel novel;
  late Chapter chapter;
  late ModelConnection connection;
  late List<ProviderRequest> requests;
  var images = 0;
  var failAudit = false;
  Completer<void>? imageGate, imageStarted;
  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '漫画', workFormat: WorkFormat.comic);
    chapter = await repo.createChapter(branchId: novel.activeBranchId);
    connection = ModelConnection(
      id: 'test',
      name: 'test',
      baseUrl: 'http://localhost:1',
      model: 'test',
      kind: ModelKind.both,
      maxOutputTokens: 8192,
    );
    requests = [];
    images = 0;
    failAudit = false;
    imageGate = imageStarted = null;
    final directory = await Directory.systemTemp.createTemp('native-comic-');
    addTearDown(() => directory.delete(recursive: true));
    runner = TaskRunner(
      repository: repo,
      assetLibrary: AssetLibrary(repository: repo, directory: directory),
      providerFactory: (c) async => ComicTextModel(c, (r) {
        requests.add(r);
        final stage = (r.messages.first['content'] as String).split('\n').first;
        switch (stage) {
          case 'COMIC/original-plan':
            return jsonEncode({
              'panels': [
                {
                  'id': 'p1',
                  'factIds': <String>[],
                  'sceneId': 'train',
                  'description': '女孩看手机',
                  'continuity': '蓝衣女孩',
                  'texts': [
                    {'kind': 'dialogue', 'speaker': '女孩', 'text': '谁？'},
                  ],
                  'referenceAssetIds': <String>[],
                },
                {
                  'id': 'p2',
                  'factIds': <String>[],
                  'sceneId': 'train',
                  'description': '手机发亮',
                  'continuity': '蓝衣女孩',
                  'texts': <dynamic>[],
                  'referenceAssetIds': <String>[],
                },
              ],
              'continuity': '女孩收到短信',
            });
          case 'COMIC/original-audit':
            if (failAudit) throw StateError('audit offline');
            return '{"issues":[]}';
          case 'COMIC/directions':
            return jsonEncode({
              'directions': List.generate(
                3,
                (i) => {
                  'title': '方向$i',
                  'summary': '查看车厢$i',
                  'event': '女孩走向车厢$i',
                },
              ),
            });
          case 'COMIC/image-rating':
            return '{"nsfw":false}';
          case 'COMIC/page-prompt':
            return '{"prompt":"完整漫画页，两格，气泡对白：谁？"}';
          default:
            throw StateError(stage);
        }
      }),
      imageProviderFactory: (c) async => ComicImageModel(c, (r, refs) async {
        images++;
        if (imageStarted?.isCompleted == false) imageStarted!.complete();
        await imageGate?.future;
        expect(r.prompt, contains('谁？'));
        return GeneratedImage(bytes: testPicture());
      }),
    );
    service = ComicService(repository: repo, runner: runner);
  });
  tearDown(() async {
    await runner.close();
    await repo.close();
  });
  Future<GenerationTask> compose({bool draw = true, String? head}) async =>
      runner.wait(
        (await service.compose(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          instruction: '雨夜收到未来短信',
          connection: connection,
          imageConnection: draw ? connection : null,
          expectedRevisionId: head,
        )).id,
      );

  test('opening draws one page without writing prose; three directions continue once', () async {
    final first = await compose();
    expect(first.status, TaskStatus.completed, reason: first.error);
    var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.complete, isTrue);
    expect(head.document.pages.length, 1);
    expect(images, 1);
    expect(
      (await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).content.text.trim(),
      isEmpty,
    );
    final directions = await runner.wait(
      (await service.suggestDirections(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(directions.status, TaskStatus.completed, reason: directions.error);
    expect(directions.result['directions'], hasLength(3));
    expect(images, 1);
    final next = await compose(head: head.id);
    expect(next.status, TaskStatus.completed, reason: next.error);
    head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.pages, hasLength(2));
    expect(head.document.complete, isTrue);
    expect(images, 2);
    expect(
      requests.every(
        (r) => !(r.messages.first['content'] as String).contains('COMIC/facts'),
      ),
      isTrue,
    );
  });
  test('storyboard-only works without image configuration; incomplete pages block continuation', () async {
    final task = await compose(draw: false);
    expect(task.status, TaskStatus.completed, reason: task.error);
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(head.document.checked, isTrue);
    expect(head.document.complete, isFalse);
    expect(images, 0);
    await expectLater(compose(head: head.id), throwsFormatException);
    final draw = await runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
        expectedRevisionId: head.id,
      )).id,
    );
    expect(draw.status, TaskStatus.completed, reason: draw.error);
    expect(images, 1);
  });
  test('stale direction selection cannot append or call a model', () async {
    await compose();
    final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: head.document,
      expectedRevisionId: head.id,
    );
    final count = requests.length;
    await expectLater(compose(head: head.id), throwsA(isA<ComicConflict>()));
    expect(requests.length, count);
  });
  test('concurrent opening requests create only one drawing task', () async {
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    addTearDown(() {
      if (!imageGate!.isCompleted) imageGate!.complete();
    });
    final attempts = await Future.wait(
      List.generate(2, (_) async {
        try {
          return await service.compose(
            branchId: novel.activeBranchId,
            chapterId: chapter.id,
            instruction: '雨夜收到短信',
            connection: connection,
            imageConnection: connection,
          );
        } catch (error) {
          return error;
        }
      }),
    );
    final tasks = attempts.whereType<GenerationTask>().toList();
    expect(tasks, hasLength(1));
    expect(
      attempts.where((v) => v is FormatException || v is ComicConflict),
      hasLength(1),
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    imageGate!.complete();
    final done = await runner.wait(tasks.single.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(images, 1);
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.document.pages,
      hasLength(1),
    );
  });
  test('cancelled original retains storyboard and reuses late image on explicit resume', () async {
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    addTearDown(() {
      if (!imageGate!.isCompleted) imageGate!.complete();
    });
    final task = await service.compose(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      instruction: '雨夜收到短信',
      connection: connection,
      imageConnection: connection,
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    final planned = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    await runner.cancel(task.id);
    imageGate!.complete();
    final cancelled = await runner.wait(task.id);
    expect(cancelled.status, TaskStatus.cancelled);
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      planned.id,
    );
    expect(planned.document.checked, isTrue);
    expect(planned.document.complete, isFalse);
    final callCount = requests.length;
    final resumed = await runner.wait((await runner.resume(task.id)).id);
    expect(resumed.status, TaskStatus.completed, reason: resumed.error);
    expect(
      (await repo.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document.complete,
      isTrue,
    );
    expect(images, 1);
    expect(requests.length, callCount);
  });
  test(
    'retry preserves generated panel IDs and completed planning call',
    () async {
      failAudit = true;
      final failed = await compose(draw: false);
      expect(failed.status, TaskStatus.failed);
      final audit = requests.last;
      failAudit = false;
      final done = await runner.wait((await runner.resume(failed.id)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(
        requests.where(
          (r) => (r.messages.first['content'] as String).startsWith(
            'COMIC/original-plan',
          ),
        ),
        hasLength(1),
      );
      expect(
        requests.last.messages.last['content'],
        audit.messages.last['content'],
      );
    },
  );
  test(
    'rechecking original after previous head changes restores continuation',
    () async {
      await compose();
      final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final next = await repo.createChapter(branchId: novel.activeBranchId);
      final task = await runner.wait(
        (await service.compose(
          branchId: novel.activeBranchId,
          chapterId: next.id,
          instruction: '下一话',
          connection: connection,
          imageConnection: connection,
        )).id,
      );
      expect(task.status, TaskStatus.completed, reason: task.error);
      var head = (await repo.getComic(novel.activeBranchId, next.id))!;
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: first.document,
        expectedRevisionId: first.id,
      );
      expect(
        await repo.comicSourcesCurrent(novel.activeBranchId, head.document),
        isFalse,
      );
      final check = await runner.wait(
        (await service.check(
          branchId: novel.activeBranchId,
          chapterId: next.id,
          connection: connection,
          expectedRevisionId: head.id,
        )).id,
      );
      expect(check.status, TaskStatus.completed, reason: check.error);
      head = (await repo.getComic(novel.activeBranchId, next.id))!;
      expect(
        await repo.comicSourcesCurrent(novel.activeBranchId, head.document),
        isTrue,
      );
      expect(head.document.checked, isTrue);
    },
  );
  test('late page image cannot overwrite an author edit', () async {
    final plan = await compose(draw: false);
    expect(plan.status, TaskStatus.completed);
    final before = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    final draw = await service.generateImages(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: connection,
      promptConnection: connection,
    );
    await imageStarted!.future.timeout(const Duration(seconds: 5));
    final edited = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: before.document,
      expectedRevisionId: before.id,
    );
    imageGate!.complete();
    final done = await runner.wait(draw.id);
    expect(done.result['comicCandidates'], contains(chapter.id));
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      edited.id,
    );
  });
}
