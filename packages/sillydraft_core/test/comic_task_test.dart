import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

class ComicTextModel implements ModelProvider {
  ComicTextModel(this.config, this.answer, {this.finish = 'stop'});
  @override
  final ModelConnection config;
  final String Function(ProviderRequest) answer;
  final String finish;
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    yield TextDelta(answer(request));
    yield GenerationFinished(finish);
  }

  @override
  void close() {}
  @override
  Future<List<String>> listModels() async => [];
}

class ComicImageModel implements ImageProvider {
  ComicImageModel(this.config, this.answer);
  @override
  final ModelConnection config;
  final Future<GeneratedImage> Function(ImageRequest, List<ImageReference>)
  answer;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) => answer(request, references);
  @override
  void close() {}
}

// Stub outputs exercise orchestration and validation, not model faithfulness.
String comicAnswer(ProviderRequest request, {bool auditFails = false}) {
  final stage = (request.messages.first['content'] as String).split('\n').first;
  final data = jsonDecode(request.messages.last['content'] as String) as Map;
  switch (stage) {
    case 'COMIC/context':
      return jsonEncode({'continuity': '阿宁在门内，门关闭。'});
    case 'COMIC/facts':
      return jsonEncode({
        'facts': [
          for (final u in data['units'] as List)
            if (u['disposition'] == 'story')
              {
                'id': 'f-${u['id']}',
                'kind': 'action',
                'summary': u['text'],
                'unitIds': [u['id']],
                'evidence': u['text'],
                'dependsOn': <String>[],
              },
        ],
      });
    case 'COMIC/panels':
      return jsonEncode({
        'panels': [
          for (final f in data['facts'] as List)
            {
              'id': 'p-${f['id']}',
              'factIds': [f['id']],
              'sceneId': (data['previousPanels'] as List).isEmpty
                  ? 'room'
                  : (data['previousPanels'] as List).last['sceneId'],
              'description': f['summary'],
              'continuity': '门关闭',
              'texts': <dynamic>[],
              'referenceAssetIds': <String>[],
            },
        ],
        'continuity': '门关闭，信在袖内。',
      });
    case 'COMIC/audit':
      return jsonEncode({
        'issues': auditFails ? ['u0：遗漏没有开门的否定'] : <String>[],
      });
    case 'COMIC/image-rating':
      return jsonEncode({'nsfw': false});
    case 'COMIC/image-prompt':
      return jsonEncode({
        'prompt': 'A single comic panel, closed door, no text',
        'nsfw': false,
      });
    case 'COMIC/page-prompt':
      return jsonEncode({'prompt': '完整漫画页，包含分镜与对白'});
    default:
      throw StateError(stage);
  }
}

void main() {
  late StoryRepository repo;
  late Novel novel;
  late Chapter chapter;
  late TaskRunner runner;
  late ComicService service;
  late ModelConnection connection;
  late List<ProviderRequest> requests;
  var auditFails = false,
      nsfw = false,
      finish = 'stop',
      images = 0,
      failImage = 0;
  var disconnectText = false;
  String? Function(ProviderRequest)? answerOverride;
  final imageConnections = <ModelConnection>[];
  final imageRequests = <ImageRequest>[];
  final imageRefs = <List<ImageReference>>[];
  Completer<void>? imageGate, imageStarted;
  setUp(() async {
    repo = StoryRepository.memory();
    novel = await repo.createNovel(title: '门外');
    chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('阿宁藏起信。她按住门闩，没有开门。'),
    );
    connection = ModelConnection(
      id: 'test',
      name: 'test',
      baseUrl: 'http://localhost:1',
      model: 'test',
      kind: ModelKind.both,
      maxOutputTokens: 8192,
    );
    requests = [];
    auditFails = false;
    nsfw = false;
    disconnectText = false;
    answerOverride = null;
    imageConnections.clear();
    imageRequests.clear();
    imageRefs.clear();
    finish = 'stop';
    images = 0;
    failImage = 0;
    imageGate = null;
    imageStarted = null;
    final directory = await Directory.systemTemp.createTemp('comic-tasks-');
    addTearDown(() => directory.delete(recursive: true));
    runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ComicTextModel(c, (r) {
        requests.add(r);
        if (disconnectText) {
          disconnectText = false;
          throw const ProviderException('disconnected', 'connection lost');
        }
        final overridden = answerOverride?.call(r);
        if (overridden != null) return overridden;
        if ((r.messages.first['content'] as String).startsWith(
          'COMIC/image-rating',
        )) {
          return jsonEncode({'nsfw': nsfw});
        }
        return comicAnswer(r, auditFails: auditFails);
      }, finish: finish),
      assetLibrary: AssetLibrary(repository: repo, directory: directory),
      imageProviderFactory: (c) async => ComicImageModel(c, (r, refs) async {
        images++;
        imageConnections.add(c);
        imageRequests.add(r);
        imageRefs.add(refs);
        if (images == failImage) {
          throw const ProviderException('test', 'image failed');
        }
        if (imageStarted?.isCompleted == false) imageStarted!.complete();
        await imageGate?.future;
        return GeneratedImage(bytes: testPicture());
      }),
    );
    service = ComicService(repository: repo, runner: runner);
  });
  tearDown(() async {
    await runner.close();
    await repo.close();
  });
  // These fixtures model pre-upgrade v1 documents and already-frozen panel
  // tasks. New author actions are tested as whole-page tasks in native_comic_task_test.
  Future<GenerationTask> legacyAdapt({
    required String branchId,
    required List<String> chapterIds,
    required ModelConnection connection,
    String style = '',
  }) async {
    final task = await runner.wait(
      (await service.adapt(
        branchId: branchId,
        chapterIds: chapterIds,
        connection: connection,
        style: style,
      )).id,
    );
    for (final id in chapterIds) {
      final head = await repo.getComic(branchId, id);
      if (head == null || !head.document.hasPages) continue;
      final json = head.document.toJson()
        ..remove('origin')
        ..remove('pages')
        ..remove('audit');
      json['version'] = 1;
      final doc = ComicDocument.fromJson(json);
      final audit = head.document.toJson()['audit'];
      await repo.saveComic(
        branchId: branchId,
        chapterId: id,
        expectedRevisionId: head.id,
        document: ComicDocument.fromJson({
          ...json,
          if (audit != null)
            'audit': <String, dynamic>{
              ...Map<String, dynamic>.from(audit as Map),
              'fingerprint': doc.fingerprint,
            },
        }),
      );
    }
    return task;
  }

  Future<GenerationTask> legacyImages({
    required String branchId,
    required String chapterId,
    required ModelConnection connection,
    required ModelConnection promptConnection,
    ModelConnection? nsfwConnection,
    String? panelId,
  }) async {
    final head = (await repo.getComic(branchId, chapterId))!;
    expect(head.document.hasPages, isFalse);
    final story = await repo.getStory(branchId);
    final index = story.chapters.indexWhere((c) => c.id == chapterId);
    final previous = index > 0
        ? await repo.getComic(branchId, story.chapters[index - 1].id)
        : null;
    return runner.start(
      branchId: branchId,
      kind: TaskKind.comic,
      input: {
        'comicAction': 'images',
        'connection': connection.raw,
        'promptConnection': promptConnection.raw,
        'nsfwConnection': ?nsfwConnection?.raw,
        'comicDocuments': [head.document.toJson()],
        'comicHeads': {chapterId: head.id},
        'panelId': ?panelId,
        'comicPreviousPanel': ?previous?.document.panels.lastOrNull,
        'comicPreviousChapterId': ?previous?.chapterId,
        'comicPreviousRevisionId': ?previous?.id,
      },
    );
  }

  Future<GenerationTask> adapt() async => runner.wait(
    (await legacyAdapt(
      branchId: novel.activeBranchId,
      chapterIds: [chapter.id],
      connection: connection,
      style: '黑白',
    )).id,
  );
  Future<GenerationTask> draw(String chapterId, {String? panelId}) async =>
      runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: chapterId,
          connection: connection,
          promptConnection: connection,
          panelId: panelId,
        )).id,
      );
  Future<Chapter> nextChapter(String text) async {
    final next = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText(text),
    );
    final task = await runner.wait(
      (await legacyAdapt(
        branchId: novel.activeBranchId,
        chapterIds: [next.id],
        connection: connection,
      )).id,
    );
    expect(task.status, TaskStatus.completed, reason: task.error);
    return next;
  }

  test(
    'new novel adaptation draws a whole page and keeps source evidence',
    () async {
      final plan = await runner.wait(
        (await service.adapt(
          branchId: novel.activeBranchId,
          chapterIds: [chapter.id],
          connection: connection,
        )).id,
      );
      expect(plan.status, TaskStatus.completed, reason: plan.error);
      var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      expect(head.document.hasPages, isTrue);
      expect(head.document.isOriginal, isFalse);
      expect(head.document.sourceRevisionId, chapter.revisionId);
      expect(head.document.facts, isNotEmpty);
      final draw = await runner.wait(
        (await service.generateImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          promptConnection: connection,
        )).id,
      );
      expect(draw.status, TaskStatus.completed, reason: draw.error);
      head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      expect(head.document.complete, isTrue);
      expect(head.document.pages, hasLength(1));
      expect(images, 1);
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).revisionId,
        chapter.revisionId,
      );
    },
  );

  test('whole-document draw redraws a flagged adaptation page', () async {
    final plan = await runner.wait(
      (await service.adapt(
        branchId: novel.activeBranchId,
        chapterIds: [chapter.id],
        connection: connection,
      )).id,
    );
    expect(plan.status, TaskStatus.completed, reason: plan.error);
    Future<GenerationTask> drawAll(String head) async => runner.wait(
      (await service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
        expectedRevisionId: head,
      )).id,
    );
    var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect((await drawAll(head.id)).status, TaskStatus.completed);
    head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final json = head.document.toJson();
    (json['pages'] as List).first['visualReview'] = true;
    final flagged = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      document: ComicDocument.fromJson(json),
      expectedRevisionId: head.id,
    );
    expect(images, 1);
    final redraw = await drawAll(flagged.id);
    expect(redraw.status, TaskStatus.completed, reason: redraw.error);
    // Adaptations keep the review flag: the page is drawn again.
    expect(images, 2);
  });

  test(
    'explicit legacy redraw upgrades to pages without losing old images',
    () async {
      await adapt();
      final oldDraw = await draw(chapter.id);
      expect(oldDraw.status, TaskStatus.completed, reason: oldDraw.error);
      final old = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      expect(old.document.hasPages, isFalse);
      final count = images;
      final redraw = await runner.wait(
        (await service.generateImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          panelId: old.document.panels.first['id'] as String,
          connection: connection,
          promptConnection: connection,
        )).id,
      );
      expect(redraw.status, TaskStatus.completed, reason: redraw.error);
      final current = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      expect(current.document.hasPages, isTrue);
      expect(current.document.complete, isTrue);
      expect(
        current.document.panels.map((p) => p['texts']),
        old.document.panels.map((p) => p['texts']),
      );
      expect(images, count + 1);
      final restored = (await repo.listComicRevisions(
        novel.activeBranchId,
        chapter.id,
      )).singleWhere((revision) => revision.id == old.id);
      expect(restored.document.toJson(), old.document.toJson());
      for (final id in old.document.assetIds) {
        expect(await repo.getAsset(id), isNotNull);
      }
    },
  );

  test('facts then panels then original-source audit; re-adaptation stays candidate', () async {
    final done = await adapt();
    expect(done.status, TaskStatus.completed, reason: done.error);
    final saved = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(saved.document.checked, isTrue);
    final stages = requests
        .map((r) => (r.messages.first['content'] as String).split('\n').first)
        .toList();
    expect(stages, ['COMIC/facts', 'COMIC/panels', 'COMIC/audit']);
    expect(requests.last.messages.last['content'], contains('没有开门'));
    expect(
      (await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      )).revisionId,
      chapter.revisionId,
    );
    final again = await adapt();
    expect(again.result['comicCandidates'], contains(chapter.id));
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      saved.id,
    );
  });
  for (final existingSecond in [false, true]) {
    for (final interrupted in [false, true]) {
      test(
        'candidate batch covers both chapters (existing second: $existingSecond, resume: $interrupted)',
        () async {
          await adapt();
          final second = existingSecond
              ? await nextChapter('她松开门闩。')
              : await repo.createChapter(
                  branchId: novel.activeBranchId,
                  content: ManuscriptContent.plainText('她松开门闩。'),
                );
          final heads = {
            for (final id in [chapter.id, second.id])
              id: (await repo.getComic(novel.activeBranchId, id))?.id,
          };
          requests.clear();
          if (interrupted) {
            answerOverride = (r) {
              if ((r.messages.first['content'] as String).startsWith(
                    'COMIC/facts',
                  ) &&
                  (r.messages.last['content'] as String).contains('松开')) {
                throw const ProviderException(
                  'test',
                  'second chapter interrupted',
                );
              }
              return null;
            };
          }
          var task = await runner.wait(
            (await legacyAdapt(
              branchId: novel.activeBranchId,
              chapterIds: [chapter.id, second.id],
              connection: connection,
            )).id,
          );
          if (interrupted) {
            expect(task.status, TaskStatus.failed, reason: task.error);
            expect(task.result['comicDocuments'], hasLength(1));
            answerOverride = null;
            task = await runner.wait((await runner.resume(task.id)).id);
          }
          expect(task.status, TaskStatus.completed, reason: task.error);
          expect(task.result['comicDocuments'], hasLength(2));
          expect(task.result['comicCandidates'], [chapter.id, second.id]);
          final docs = task.result['comicDocuments'] as Map;
          expect(docs[second.id]['context'], docs[chapter.id]['continuity']);
          expect(
            docs[second.id]['panels'].first['sceneId'],
            docs[chapter.id]['panels'].last['sceneId'],
          );
          expect(
            requests.where(
              (r) => (r.messages.first['content'] as String).startsWith(
                'COMIC/audit',
              ),
            ),
            hasLength(2),
          );
          for (final head in heads.entries) {
            expect(
              (await repo.getComic(novel.activeBranchId, head.key))?.id,
              head.value,
            );
          }
        },
      );
    }
  }

  for (final stage in [
    'context',
    'facts',
    'panels',
    'audit',
    'image-rating',
    'image-prompt',
  ]) {
    test(
      'invalid $stage response can be retried without repeating valid stages',
      () async {
        if (stage == 'context') {
          chapter = await repo.createChapter(
            branchId: novel.activeBranchId,
            content: ManuscriptContent.plainText('她松开门闩。'),
          );
        }
        final imageStage = stage.startsWith('image-');
        if (imageStage) await adapt();
        connection = ModelConnection.fromJson({
          ...connection.raw,
          'protocol': ModelProtocol.sillyDraftRunner.name,
        });
        answerOverride = (r) {
          if (!(r.messages.first['content'] as String).startsWith(
            'COMIC/$stage\n',
          )) {
            return null;
          }
          final out = jsonDecode(comicAnswer(r)) as Map;
          switch (stage) {
            case 'context':
              out['continuity'] = '';
            case 'facts':
              out['facts'].first['evidence'] = '原文不存在的证据';
            case 'panels':
              out['panels'].first['referenceAssetIds'] = ['invented'];
            case 'audit':
              out['issues'] = 'invalid';
            case 'image-rating':
              out['nsfw'] = 'false';
            case 'image-prompt':
              out['prompt'] = '';
          }
          return jsonEncode(out);
        };
        final panelId = imageStage
            ? (await repo.getComic(
                    novel.activeBranchId,
                    chapter.id,
                  ))!.document.panels.first['id']
                  as String
            : null;
        final failed = imageStage
            ? await draw(chapter.id, panelId: panelId)
            : await adapt();
        expect(failed.status, TaskStatus.failed);
        final count = requests.length;
        final invalid = requests.last;
        expect(
          (invalid.messages.first['content'] as String).split('\n').first,
          'COMIC/$stage',
        );
        answerOverride = null;
        final done = await runner.wait((await runner.resume(failed.id)).id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        final retried = requests[count];
        expect(retried.messages, invalid.messages);
        expect(retried.executionId, isNot(invalid.executionId));
        expect(retried.raw['retrieveOnly'], isNot(true));
        final saved = (await repo.getComic(novel.activeBranchId, chapter.id))!;
        expect(saved.document.checked, isTrue);
        if (imageStage) {
          expect(saved.document.panels.first['assetId'], isNotNull);
        }
      },
    );
  }

  test(
    'legacy completed invalid audit checkpoint is revalidated on resume',
    () async {
      answerOverride = (r) =>
          (r.messages.first['content'] as String).startsWith('COMIC/audit')
          ? '{"issues":"invalid"}'
          : null;
      final failed = await adapt();
      expect(failed.status, TaskStatus.failed);
      final calls = Map<String, dynamic>.from(
        failed.result['comicCalls'] as Map,
      );
      final key = calls.keys.last;
      calls[key] = {
        ...calls[key] as Map,
        'complete': true,
        'value': {'issues': 'invalid'},
      };
      await repo.updateTask(
        failed.id,
        status: TaskStatus.failed,
        result: {'comicCalls': calls},
      );
      final count = requests.length;
      answerOverride = null;
      final done = await runner.wait((await runner.resume(failed.id)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(requests.length, count + 1);
      expect(
        (await repo.getComic(
          novel.activeBranchId,
          chapter.id,
        ))!.document.checked,
        isTrue,
      );
    },
  );

  for (final failure in ['invalid JSON', 'truncated output']) {
    test(
      'terminal remote $failure can start a fresh execution on resume',
      () async {
        connection = ModelConnection.fromJson({
          ...connection.raw,
          'protocol': ModelProtocol.sillyDraftRunner.name,
        });
        if (failure == 'invalid JSON') {
          answerOverride = (_) => '{';
        } else {
          finish = 'length';
        }
        final failed = await adapt();
        expect(failed.status, TaskStatus.failed);
        expect(await repo.getComic(novel.activeBranchId, chapter.id), isNull);
        final invalid = requests.single;
        answerOverride = null;
        finish = 'stop';
        final done = await runner.wait((await runner.resume(failed.id)).id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect(requests[1].messages, invalid.messages);
        expect(requests[1].executionId, isNot(invalid.executionId));
        expect(requests[1].raw['retrieveOnly'], isNot(true));
        expect(
          (await repo.getComic(
            novel.activeBranchId,
            chapter.id,
          ))!.document.checked,
          isTrue,
        );
      },
    );
  }

  test('redrawing a panel marks transitive explicit image dependents in its chapter', () async {
    chapter = await repo.saveChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('她走进房间。她走到庭院。她走到街上。'),
    );
    await adapt();
    var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final panels = head.document.panels;
    for (final (i, panel) in panels.indexed) {
      panel['sceneId'] = 'scene-$i';
      panel.remove('previousPanelId');
    }
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: head.id,
      document: head.document.editPanels(panels),
    );
    final checked = await runner.wait(
      (await service.check(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
      )).id,
    );
    expect(checked.status, TaskStatus.completed, reason: checked.error);
    for (var i = 0; i < panels.length; i++) {
      head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      if (i > 0) {
        final linked = head.document.panels;
        linked[i]['referenceAssetIds'] = [linked[i - 1]['assetId']];
        await repo.saveComic(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          expectedRevisionId: head.id,
          document: head.document.editPanels(linked),
        );
      }
      final done = await draw(chapter.id, panelId: panels[i]['id'] as String);
      expect(done.status, TaskStatus.completed, reason: done.error);
    }
    final before = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document;
    expect(before.panels.map((p) => p['visualReview']), [false, false, false]);
    final redrawn = await draw(
      chapter.id,
      panelId: panels.first['id'] as String,
    );
    expect(redrawn.status, TaskStatus.completed, reason: redrawn.error);
    final after = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document;
    expect(after.panels.map((p) => p['visualReview']), [false, true, true]);
    expect(
      after.panels.first['assetId'],
      isNot(before.panels.first['assetId']),
    );
    expect(
      after.panels.skip(1).map((p) => p['assetId']),
      before.panels.skip(1).map((p) => p['assetId']),
    );
    expect(after.checked, isTrue);
    expect(images, 4);
  });
  test(
    'changed confirmation head starts neither checks nor image tasks',
    () async {
      await adapt();
      final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        document: head.document,
        expectedRevisionId: head.id,
      );
      final taskCount = (await repo.listTasks(branchId: novel.activeBranchId))
          .length;
      final requestCount = requests.length;
      await expectLater(
        service.check(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          expectedRevisionId: head.id,
        ),
        throwsA(isA<ComicConflict>()),
      );
      await expectLater(
        service.generateImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          promptConnection: connection,
          expectedRevisionId: head.id,
        ),
        throwsA(isA<ComicConflict>()),
      );
      expect(
        (await repo.listTasks(branchId: novel.activeBranchId)).length,
        taskCount,
      );
      expect(requests.length, requestCount);
      expect(images, 0);
    },
  );

  test('one repair then failed independent audit blocks images', () async {
    auditFails = true;
    final done = await adapt();
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(
      requests
          .where(
            (r) => (r.messages.first['content'] as String).startsWith(
              'COMIC/audit',
            ),
          )
          .length,
      2,
    );
    expect(
      (await repo.getComic(novel.activeBranchId, chapter.id))!.document.checked,
      isFalse,
    );
    await expectLater(
      service.generateImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
      ),
      throwsFormatException,
    );
    expect(images, 0);
  });
  test('truncated JSON output cannot pass audit', () async {
    finish = 'length';
    final done = await adapt();
    expect(done.status, TaskStatus.failed);
    expect(done.error, contains('截断'));
    expect(await repo.getComic(novel.activeBranchId, chapter.id), isNull);
  });
  test(
    'long preceding chapters and source boundaries are all reviewed',
    () async {
      chapter = await repo.saveChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: chapter.revisionId,
        content: ManuscriptContent.plainText('${'前情，' * 2100}尾声。'),
      );
      final target = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('${'动作，' * 2100}仍未开门。'),
      );
      final done = await runner.wait(
        (await legacyAdapt(
          branchId: novel.activeBranchId,
          chapterIds: [target.id],
          connection: connection,
          style: '',
        )).id,
      );
      expect(done.status, TaskStatus.completed, reason: done.error);
      final doc = (await repo.getComic(
        novel.activeBranchId,
        target.id,
      ))!.document;
      expect(doc.priorSources.single['revisionId'], chapter.revisionId);
      final context = requests
          .where(
            (r) => (r.messages.first['content'] as String).startsWith(
              'COMIC/context',
            ),
          )
          .toList();
      expect(context.length, greaterThan(1));
      expect(context.last.messages.last['content'], contains('尾声'));
      expect(
        requests
            .where(
              (r) => (r.messages.first['content'] as String).startsWith(
                'COMIC/audit',
              ),
            )
            .length,
        doc.reviewScopes.length,
      );
    },
  );
  test(
    'adult drawings stop without configured engine and use its prompt format',
    () async {
      await adapt();
      nsfw = true;
      final stopped = await runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          promptConnection: connection,
        )).id,
      );
      expect(stopped.status, TaskStatus.failed);
      expect(stopped.error, contains('NSFW'));
      expect(images, 0);
      final adult = ModelConnection.fromJson({
        ...connection.raw,
        'id': 'adult',
        'protocol': ModelProtocol.novelAI.name,
      });
      final done = await runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          promptConnection: connection,
          nsfwConnection: adult,
        )).id,
      );
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(imageConnections.every((c) => c.id == 'adult'), isTrue);
      final prompt = requests.firstWhere(
        (r) => (r.messages.first['content'] as String).startsWith(
          'COMIC/image-prompt',
        ),
      );
      expect(prompt.messages.last['content'], contains('Danbooru'));
    },
  );
  test(
    'cross chapter scene identity and previous image are carried explicitly',
    () async {
      await adapt();
      await runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
          promptConnection: connection,
        )).id,
      );
      final first = (await repo.getComic(
        novel.activeBranchId,
        chapter.id,
      ))!.document;
      final second = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('她继续按住门闩。'),
      );
      final done = await runner.wait(
        (await legacyAdapt(
          branchId: novel.activeBranchId,
          chapterIds: [second.id],
          connection: connection,
        )).id,
      );
      expect(done.status, TaskStatus.completed, reason: done.error);
      final next = (await repo.getComic(
        novel.activeBranchId,
        second.id,
      ))!.document;
      expect(next.panels.first['sceneId'], first.panels.last['sceneId']);
      await runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: second.id,
          connection: connection,
          promptConnection: connection,
        )).id,
      );
      expect(imageRefs.last, hasLength(1));
    },
  );
  test('replacing a chapter image marks downstream actual references across chapters', () async {
    await adapt();
    await draw(chapter.id);
    final second = await nextChapter('她继续按住门闩。');
    await draw(second.id);
    final third = await nextChapter('她仍没有拉开。');
    await draw(third.id);
    final secondBefore = (await repo.getComic(
      novel.activeBranchId,
      second.id,
    ))!;
    final thirdBefore = (await repo.getComic(novel.activeBranchId, third.id))!;
    expect(secondBefore.document.panels.single['referenceAssetIds'], isEmpty);
    final fork = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: '旧画面',
    );
    final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final done = await draw(
      chapter.id,
      panelId: first.document.panels.last['id'] as String,
    );
    expect(done.status, TaskStatus.completed, reason: done.error);
    for (final before in [secondBefore, thirdBefore]) {
      final after = (await repo.getComic(
        novel.activeBranchId,
        before.chapterId,
      ))!;
      expect(after.document.panels.single['visualReview'], isTrue);
      expect(
        after.document.panels.single['assetId'],
        before.document.panels.single['assetId'],
      );
      expect(after.document.checked, isTrue);
      expect(after.parentRevisionId, before.id);
      expect((await repo.getComic(fork.id, before.chapterId))!.id, before.id);
    }
    final copy = (await repo.exportProject(novel.id)).copy();
    final restored = await repo.restoreProject(
      copy.snapshot,
      encryptedSources: {},
    );
    expect(
      (await repo.getComic(
        restored.activeBranchId,
        copy.ids[third.id]!,
      ))!.document.panels.single['visualReview'],
      isTrue,
    );
  });

  test(
    'same-chapter review uses frozen references after panel links are removed',
    () async {
      expect((await adapt()).status, TaskStatus.completed);
      expect((await draw(chapter.id)).status, TaskStatus.completed);
      var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final sourceId = head.document.panels.first['assetId'];
      final dependentId = head.document.panels.last['assetId'] as String;
      expect(
        ((await repo.getAsset(dependentId)).metadata['references'] as List).any(
          (r) => r['id'] == sourceId,
        ),
        isTrue,
      );
      final separated = head.document.panels;
      separated.last.remove('previousPanelId');
      separated.last['sceneId'] = 'separate-scene';
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: head.id,
        document: head.document.editPanels(separated),
      );
      expect(
        (await runner.wait(
          (await service.check(
            branchId: novel.activeBranchId,
            chapterId: chapter.id,
            connection: connection,
          )).id,
        )).status,
        TaskStatus.completed,
      );
      head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final confirmed = head.document.panels;
      for (final p in confirmed) {
        p['visualReview'] = false;
      }
      head = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: head.id,
        document: head.document.editPanels(confirmed),
      );
      final done = await draw(
        chapter.id,
        panelId: confirmed.first['id'] as String,
      );
      expect(done.status, TaskStatus.completed, reason: done.error);
      final after = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      expect(after.document.panels.first['assetId'], isNot(sourceId));
      expect(after.document.panels.first['visualReview'], isFalse);
      expect(after.document.panels.last['assetId'], dependentId);
      expect(after.document.panels.last['visualReview'], isTrue);
      expect(after.parentRevisionId, head.id);
      expect((done.result['comicHeads'] as Map)[chapter.id], after.id);
      expect(
        (done.result['comicDocuments'] as Map)[chapter.id],
        after.document.toJson(),
      );
      final panels = after.document.panels..last['visualReview'] = false;
      final saved = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: after.id,
        document: after.document.editPanels(panels),
      );
      expect(
        saved.id,
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
      );
      expect(saved.document.panels.last['visualReview'], isFalse);
    },
  );

  test('earlier chapter actual references are flagged when a later image is redrawn', () async {
    expect((await adapt()).status, TaskStatus.completed);
    expect((await draw(chapter.id)).status, TaskStatus.completed);
    final next = await nextChapter('她走到院外。');
    var later = (await repo.getComic(novel.activeBranchId, next.id))!;
    final isolated = later.document.panels;
    isolated.single['sceneId'] = 'independent-scene';
    isolated.single.remove('previousPanelId');
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: next.id,
      expectedRevisionId: later.id,
      document: later.document.editPanels(isolated),
    );
    expect(
      (await runner.wait(
        (await service.check(
          branchId: novel.activeBranchId,
          chapterId: next.id,
          connection: connection,
        )).id,
      )).status,
      TaskStatus.completed,
    );
    expect((await draw(next.id)).status, TaskStatus.completed);
    later = (await repo.getComic(novel.activeBranchId, next.id))!;
    final sourceId = later.document.panels.single['assetId'];
    var first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final linked = first.document.panels;
    linked.first['referenceAssetIds'] = [sourceId];
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: first.id,
      document: first.document.editPanels(linked),
    );
    expect(
      (await draw(chapter.id, panelId: linked.first['id'] as String)).status,
      TaskStatus.completed,
    );
    first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final image = await repo.getAsset(
      first.document.panels.first['assetId'] as String,
    );
    expect(
      (image.metadata['references'] as List).any((r) => r['id'] == sourceId),
      isTrue,
    );
    expect(first.document.panels.first['visualReview'], isFalse);
    final done = await draw(next.id, panelId: isolated.single['id'] as String);
    expect(done.status, TaskStatus.completed, reason: done.error);
    final after = (await repo.getComic(novel.activeBranchId, next.id))!;
    expect(after.document.panels.single['assetId'], isNot(sourceId));
    expect(after.document.panels.single['visualReview'], isFalse);
    final dependent = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(dependent.document.panels.first['visualReview'], isTrue);
    expect(dependent.document.panels.first['assetId'], image.id);
  });

  test(
    'fact edits propagate review even while the source is already pending',
    () async {
      expect((await adapt()).status, TaskStatus.completed);
      expect((await draw(chapter.id)).status, TaskStatus.completed);
      final next = await nextChapter('她继续按住门闩。');
      expect((await draw(next.id)).status, TaskStatus.completed);
      var source = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      var dependent = (await repo.getComic(novel.activeBranchId, next.id))!;
      final asset = await repo.getAsset(
        dependent.document.panels.single['assetId'] as String,
      );
      expect(
        (asset.metadata['references'] as List).any(
          (r) => r['id'] == source.document.panels.last['assetId'],
        ),
        isTrue,
      );
      for (final summary in ['她把信藏进右侧袖口。', '她把信藏进左侧袖口。']) {
        final facts = source.document.facts..first['summary'] = summary;
        final panels = source.document.panels;
        for (final p in panels) {
          p['visualReview'] = true;
        }
        await repo.saveComic(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          expectedRevisionId: source.id,
          document: source.document.edit({'facts': facts, 'panels': panels}),
        );
        expect(
          (await runner.wait(
            (await service.check(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              connection: connection,
            )).id,
          )).status,
          TaskStatus.completed,
        );
        source = (await repo.getComic(novel.activeBranchId, chapter.id))!;
        dependent = (await repo.getComic(novel.activeBranchId, next.id))!;
        expect(
          source.document.panels.every((p) => p['visualReview'] == true),
          isTrue,
        );
        expect(dependent.document.panels.single['visualReview'], isTrue);
        final confirmed = dependent.document.panels
          ..single['visualReview'] = false;
        dependent = await repo.saveComic(
          branchId: novel.activeBranchId,
          chapterId: next.id,
          expectedRevisionId: dependent.id,
          document: dependent.document.editPanels(confirmed),
        );
        expect(dependent.document.panels.single['visualReview'], isFalse);
      }
    },
  );

  test('pending review traverses cross-chapter backward cycles and preserves unrelated heads', () async {
    connection = ModelConnection.fromJson({
      ...connection.raw,
      'maxReferenceImages': 0,
    });
    expect((await adapt()).status, TaskStatus.completed);
    expect((await draw(chapter.id)).status, TaskStatus.completed);
    final chapters = [chapter];
    for (final text in ['她关窗。', '她熄灯。', '她离开。']) {
      final next = await nextChapter(text);
      expect((await draw(next.id)).status, TaskStatus.completed);
      chapters.add(next);
    }
    final heads = <ComicRevision>[
      for (final c in chapters)
        (await repo.getComic(novel.activeBranchId, c.id))!,
    ];
    for (var i = 0; i < 3; i++) {
      final panels = heads[i].document.panels;
      panels.first['referenceAssetIds'] = [
        heads[(i + 1) % 3].document.panels.first['assetId'],
      ];
      heads[i] = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapters[i].id,
        expectedRevisionId: heads[i].id,
        document: heads[i].document.editPanels(panels),
      );
    }
    for (var i = 0; i < 3; i++) {
      final head = (await repo.getComic(novel.activeBranchId, chapters[i].id))!;
      final panels = head.document.panels;
      for (final p in panels) {
        p['visualReview'] = false;
      }
      heads[i] = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapters[i].id,
        expectedRevisionId: head.id,
        document: head.document.editPanels(panels),
      );
    }
    final fork = await repo.forkBranch(
      branchId: novel.activeBranchId,
      name: 'before review',
    );
    final panels = heads[2].document.panels..single['visualReview'] = true;
    final saved = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapters[2].id,
      expectedRevisionId: heads[2].id,
      document: heads[2].document.editPanels(panels),
    );
    for (var i = 0; i < 3; i++) {
      final head = (await repo.getComic(novel.activeBranchId, chapters[i].id))!;
      expect(head.document.panels.first['visualReview'], isTrue);
      expect(head.parentRevisionId, heads[i].id);
      expect((await repo.getComic(fork.id, chapters[i].id))!.id, heads[i].id);
    }
    expect(
      saved.id,
      (await repo.getComic(novel.activeBranchId, chapters[2].id))!.id,
    );
    expect(
      (await repo.getComic(novel.activeBranchId, chapters[3].id))!.id,
      heads[3].id,
    );
  });

  test(
    'an omitted automatic reference does not invalidate later images',
    () async {
      await adapt();
      await draw(chapter.id);
      final next = await nextChapter('她继续按住门闩。');
      final normalConnection = connection;
      connection = ModelConnection.fromJson({
        ...connection.raw,
        'maxReferenceImages': 0,
      });
      final drawn = await draw(next.id);
      expect(drawn.status, TaskStatus.completed, reason: drawn.error);
      expect(imageRefs.last, isEmpty);
      final before = (await repo.getComic(novel.activeBranchId, next.id))!;
      final asset = (await repo.listAssets(novel.id))
          .singleWhere((a) => a.id == before.document.panels.single['assetId']);
      expect(asset.metadata['previousSceneAssetId'], isNotNull);
      expect(asset.metadata['references'], isEmpty);
      connection = normalConnection;
      final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final redrawn = await draw(
        chapter.id,
        panelId: first.document.panels.last['id'] as String,
      );
      expect(redrawn.status, TaskStatus.completed, reason: redrawn.error);
      final after = (await repo.getComic(novel.activeBranchId, next.id))!;
      expect(after.id, before.id);
      expect(after.document.panels.single['visualReview'], isNot(true));
    },
  );

  test('late cross chapter image is retained as candidate when reference head changes', () async {
    await adapt();
    await draw(chapter.id);
    final next = await nextChapter('她继续按住门闩。');
    final before = (await repo.getComic(novel.activeBranchId, next.id))!;
    imageGate = Completer<void>();
    imageStarted = Completer<void>();
    final pending = await legacyImages(
      branchId: novel.activeBranchId,
      chapterId: next.id,
      connection: connection,
      promptConnection: connection,
    );
    await imageStarted!.future;
    final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final panels = first.document.panels;
    panels.last['assetId'] = panels.first['assetId'];
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: first.id,
      document: first.document.editPanels(panels),
    );
    imageGate!.complete();
    final done = await runner.wait(pending.id);
    expect(done.status, TaskStatus.failed);
    expect(done.result['comicCandidates'], contains(next.id));
    final after = (await repo.getComic(novel.activeBranchId, next.id))!;
    expect(after.id, before.id);
    expect(after.document.panels.single['assetId'], isNull);
    expect(await repo.listAssets(novel.id), hasLength(3));
  });

  test(
    'copied interrupted comic resumes remote images and keeps finished panels',
    () async {
      await adapt();
      final remote = ModelConnection.fromJson({
        ...connection.raw,
        'protocol': ModelProtocol.sillyDraftRunner.name,
      });
      failImage = 2;
      final failed = await runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: remote,
          promptConnection: connection,
        )).id,
      );
      expect(failed.status, TaskStatus.failed, reason: failed.error);
      final original = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final calls = requests.length;
      final remoteExecution = imageRequests.last.executionId;
      final copy = (await repo.exportProject(novel.id)).copy();
      final restored = await repo.restoreProject(
        copy.snapshot,
        encryptedSources: {},
      );
      final copiedTask = await repo.getTask(copy.ids[failed.id]!);
      final resumed = await runner.wait(
        (await runner.resume(copiedTask.id)).id,
      );
      expect(resumed.status, TaskStatus.completed, reason: resumed.error);
      expect(requests.length, calls);
      expect(images, 3);
      expect(imageRequests.last.raw['retrieveOnly'], isTrue);
      expect(imageRequests.last.executionId, remoteExecution);
      final after = (await repo.getComic(
        restored.activeBranchId,
        copy.ids[chapter.id]!,
      ))!;
      expect(
        after.document.panels.first['assetId'],
        copy.ids[original.document.panels.first['assetId']],
      );
      expect(after.document.panels.every((p) => p['assetId'] != null), isTrue);
      final children = resumed.result['comicChildren'] as Map;
      expect(
        children.keys.every(
          (key) => (key as String).startsWith('${copy.ids[chapter.id]}/'),
        ),
        isTrue,
      );
      expect(
        (resumed.result['comicDrawn'] as List).every(
          (key) => (key as String).startsWith('${copy.ids[chapter.id]}/'),
        ),
        isTrue,
      );
      final child = await repo.getTask(children.values.last as String);
      expect(child.input['frozenComic']['key'], children.keys.last);
      expect(
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
        original.id,
      );
    },
  );

  test(
    'copied uncertain text checkpoint retains the remote execution identity',
    () async {
      connection = ModelConnection.fromJson({
        ...connection.raw,
        'protocol': ModelProtocol.sillyDraftRunner.name,
      });
      disconnectText = true;
      final failed = await adapt();
      final execution = requests.single.executionId;
      final copy = (await repo.exportProject(novel.id)).copy();
      await repo.restoreProject(copy.snapshot, encryptedSources: {});
      final resumed = await runner.wait(
        (await runner.resume(copy.ids[failed.id]!)).id,
      );
      expect(resumed.status, TaskStatus.completed, reason: resumed.error);
      expect(requests[1].raw['retrieveOnly'], isTrue);
      expect(requests[1].executionId, execution);
    },
  );

  test(
    'uncertain remote calls resume by retrieving the frozen execution only',
    () async {
      connection = ModelConnection.fromJson({
        ...connection.raw,
        'protocol': ModelProtocol.sillyDraftRunner.name,
      });
      disconnectText = true;
      final failed = await adapt();
      expect(failed.status, TaskStatus.failed);
      final original = requests.single;
      final done = await runner.wait((await runner.resume(failed.id)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(requests[1].raw['retrieveOnly'], isTrue);
      expect(requests[1].executionId, original.executionId);
    },
  );
  test(
    'remote failed image reconnects the same child without submitting again',
    () async {
      await adapt();
      final remote = ModelConnection.fromJson({
        ...connection.raw,
        'protocol': ModelProtocol.sillyDraftRunner.name,
      });
      failImage = 1;
      final failed = await runner.wait(
        (await legacyImages(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: remote,
          promptConnection: connection,
        )).id,
      );
      expect(failed.status, TaskStatus.failed);
      final done = await runner.wait((await runner.resume(failed.id)).id);
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(imageRequests[1].raw['retrieveOnly'], isTrue);
      expect(
        imageRequests[1].raw['executionId'],
        imageRequests[0].raw['executionId'],
      );
    },
  );
  test('failed second image resumes without regenerating first', () async {
    await adapt();
    failImage = 2;
    final task = await legacyImages(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      connection: connection,
      promptConnection: connection,
    );
    final failed = await runner.wait(task.id);
    expect(failed.status, TaskStatus.failed, reason: failed.error);
    final before = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document;
    expect(before.panels.first['assetId'], isNotNull);
    final resumed = await runner.wait((await runner.resume(task.id)).id);
    expect(resumed.status, TaskStatus.completed, reason: resumed.error);
    final after = (await repo.getComic(
      novel.activeBranchId,
      chapter.id,
    ))!.document;
    expect(after.panels.first['assetId'], before.panels.first['assetId']);
    expect(after.panels.every((p) => p['assetId'] != null), isTrue);
    expect(images, after.panels.length + 1);
  });
  test(
    'cancelled late image remains in gallery without overwriting edits',
    () async {
      await adapt();
      imageGate = Completer<void>();
      imageStarted = Completer<void>();
      final task = await legacyImages(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
        promptConnection: connection,
      );
      await imageStarted!.future;
      final head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final edited = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: head.id,
        document: head.document.edit({'style': '彩色'}),
      );
      await runner.cancel(task.id);
      imageGate!.complete();
      await runner.wait(task.id);
      expect((await repo.listAssets(novel.id)).length, 1);
      expect(
        (await repo.getComic(novel.activeBranchId, chapter.id))!.id,
        edited.id,
      );
    },
  );
  test('restoring history keeps unresolved upstream review', () async {
    expect((await adapt()).status, TaskStatus.completed);
    expect((await draw(chapter.id)).status, TaskStatus.completed);
    final second = await nextChapter('她继续按住门闩。');
    expect((await draw(second.id)).status, TaskStatus.completed);
    final oldSecond = (await repo.getComic(novel.activeBranchId, second.id))!;
    final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(
      (await draw(
        chapter.id,
        panelId: first.document.panels.last['id'] as String,
      )).status,
      TaskStatus.completed,
    );
    final flagged = (await repo.getComic(novel.activeBranchId, second.id))!;
    expect(flagged.document.panels.single['visualReview'], isTrue);
    final restored = await repo.restoreComic(
      branchId: novel.activeBranchId,
      chapterId: second.id,
      revisionId: oldSecond.id,
      expectedRevisionId: flagged.id,
    );
    expect(
      restored.document.panels.single['assetId'],
      oldSecond.document.panels.single['assetId'],
    );
    expect(restored.document.checked, isTrue);
    expect(
      await repo.comicSourcesCurrent(novel.activeBranchId, restored.document),
      isTrue,
    );
    expect(
      restored.document.panels.single['visualReview'],
      isTrue,
      reason: 'The restored picture still depends on the replaced previous chapter picture.',
    );
    expect(restored.parentRevisionId, flagged.id);
    final history = await repo.listComicRevisions(
      novel.activeBranchId,
      second.id,
    );
    expect(
      history
          .singleWhere((r) => r.id == oldSecond.id)
          .document
          .panels
          .single['visualReview'],
      isFalse,
    );
  });

  test('redrawing later referenced panel flags earlier dependent', () async {
    expect((await adapt()).status, TaskStatus.completed);
    var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final separated = head.document.panels;
    for (final (i, panel) in separated.indexed) {
      panel['sceneId'] = 'scene-$i';
      panel.remove('previousPanelId');
    }
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: head.id,
      document: head.document.editPanels(separated),
    );
    final checked = await runner.wait(
      (await service.check(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        connection: connection,
      )).id,
    );
    expect(checked.status, TaskStatus.completed, reason: checked.error);
    expect((await draw(chapter.id)).status, TaskStatus.completed);
    head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final linked = head.document.panels;
    final laterAsset = linked.last['assetId'] as String;
    linked.first['referenceAssetIds'] = [laterAsset];
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: head.id,
      document: head.document.editPanels(linked),
    );
    expect(
      (await draw(chapter.id, panelId: linked.first['id'] as String)).status,
      TaskStatus.completed,
    );
    final before = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(before.document.panels.first['visualReview'], isFalse);
    final assets = await repo.listAssets(novel.id);
    final dependent = assets.singleWhere(
      (a) => a.id == before.document.panels.first['assetId'],
    );
    expect(
      (dependent.metadata['references'] as List).any(
        (r) => r['id'] == laterAsset,
      ),
      isTrue,
    );
    expect(
      (await draw(chapter.id, panelId: linked.last['id'] as String)).status,
      TaskStatus.completed,
    );
    final after = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    expect(after.document.panels.last['assetId'], isNot(laterAsset));
    expect(
      after.document.panels.first['assetId'],
      before.document.panels.first['assetId'],
    );
    expect(
      after.document.panels.first['visualReview'],
      isTrue,
      reason: 'An earlier panel can explicitly reference a later panel from the gallery.',
    );
  });

  for (final referenceState in ['pending', 'confirmed', 'omitted']) {
    test(
      'redraw respects actual upstream reference state: $referenceState',
      () async {
        expect((await adapt()).status, TaskStatus.completed);
        expect((await draw(chapter.id)).status, TaskStatus.completed);
        final second = await nextChapter('她继续按住门闩。');
        expect((await draw(second.id)).status, TaskStatus.completed);
        final third = await nextChapter('她仍没有拉开。');
        expect((await draw(third.id)).status, TaskStatus.completed);
        final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
        expect(
          (await draw(
            chapter.id,
            panelId: first.document.panels.last['id'] as String,
          )).status,
          TaskStatus.completed,
        );
        final pendingSecond = (await repo.getComic(
          novel.activeBranchId,
          second.id,
        ))!;
        final pendingThird = (await repo.getComic(
          novel.activeBranchId,
          third.id,
        ))!;
        expect(pendingSecond.document.panels.single['visualReview'], isTrue);
        expect(pendingThird.document.panels.single['visualReview'], isTrue);
        if (referenceState == 'confirmed') {
          final confirmed = pendingSecond.document.panels;
          confirmed.single['visualReview'] = false;
          await repo.saveComic(
            branchId: novel.activeBranchId,
            chapterId: second.id,
            expectedRevisionId: pendingSecond.id,
            document: pendingSecond.document.editPanels(confirmed),
          );
        } else if (referenceState == 'omitted') {
          connection = ModelConnection.fromJson({
            ...connection.raw,
            'maxReferenceImages': 0,
          });
        }
        expect(
          (await draw(
            third.id,
            panelId: pendingThird.document.panels.single['id'] as String,
          )).status,
          TaskStatus.completed,
        );
        final redrawn = (await repo.getComic(novel.activeBranchId, third.id))!;
        final assets = await repo.listAssets(novel.id);
        final image = assets.singleWhere(
          (a) => a.id == redrawn.document.panels.single['assetId'],
        );
        expect(
          (image.metadata['references'] as List).any(
            (r) => r['id'] == pendingSecond.document.panels.single['assetId'],
          ),
          referenceState != 'omitted',
        );
        expect(
          redrawn.document.panels.single['visualReview'],
          referenceState == 'pending',
        );
      },
    );
  }

  test(
    'redraw retains review from an explicit nonadjacent reference',
    () async {
      expect((await adapt()).status, TaskStatus.completed);
      expect((await draw(chapter.id)).status, TaskStatus.completed);
      final second = await nextChapter('她继续按住门闩。');
      expect((await draw(second.id)).status, TaskStatus.completed);
      final third = await nextChapter('她仍没有拉开。');
      expect((await draw(third.id)).status, TaskStatus.completed);
      final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final pending = first.document.panels;
      final pendingAsset = pending.last['assetId'] as String;
      pending.last['visualReview'] = true;
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: first.id,
        document: first.document.editPanels(pending),
      );
      final head = (await repo.getComic(novel.activeBranchId, third.id))!;
      final linked = head.document.panels;
      linked.single['referenceAssetIds'] = [pendingAsset];
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: third.id,
        expectedRevisionId: head.id,
        document: head.document.editPanels(linked),
      );
      expect(
        (await draw(third.id, panelId: linked.single['id'] as String)).status,
        TaskStatus.completed,
      );
      final redrawn = (await repo.getComic(novel.activeBranchId, third.id))!;
      final image = await repo.getAsset(
        redrawn.document.panels.single['assetId'] as String,
      );
      expect(
        (image.metadata['references'] as List).any(
          (r) => r['id'] == pendingAsset,
        ),
        isTrue,
      );
      expect(redrawn.document.panels.single['visualReview'], isTrue);
    },
  );
  test('backward reference chains invalidate later chapters', () async {
    chapter = await repo.saveChapter(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('阿宁藏信。她锁门。她关窗。'),
    );
    expect((await adapt()).status, TaskStatus.completed);
    var first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final separated = first.document.panels;
    expect(separated, hasLength(3));
    for (final (i, p) in separated.indexed) {
      p['sceneId'] = 'isolated-$i';
      p.remove('previousPanelId');
    }
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: first.id,
      document: first.document.editPanels(separated),
    );
    expect(
      (await runner.wait(
        (await service.check(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
          connection: connection,
        )).id,
      )).status,
      TaskStatus.completed,
    );
    expect((await draw(chapter.id)).status, TaskStatus.completed);
    first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    final linked = first.document.panels;
    linked[0]['referenceAssetIds'] = [linked[1]['assetId']];
    linked[1]['referenceAssetIds'] = [linked[2]['assetId']];
    first = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: first.id,
      document: first.document.editPanels(linked),
    );
    final confirmed = first.document.panels;
    for (final p in confirmed) {
      p['visualReview'] = false;
    }
    first = await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      expectedRevisionId: first.id,
      document: first.document.editPanels(confirmed),
    );
    final second = await nextChapter('她走向门口。');
    var secondHead = (await repo.getComic(novel.activeBranchId, second.id))!;
    final dependent = secondHead.document.panels;
    dependent.single['sceneId'] = 'isolated-next-chapter';
    dependent.single.remove('previousPanelId');
    dependent.single['referenceAssetIds'] = [
      first.document.panels[0]['assetId'],
    ];
    await repo.saveComic(
      branchId: novel.activeBranchId,
      chapterId: second.id,
      expectedRevisionId: secondHead.id,
      document: secondHead.document.editPanels(dependent),
    );
    expect(
      (await runner.wait(
        (await service.check(
          branchId: novel.activeBranchId,
          chapterId: second.id,
          connection: connection,
        )).id,
      )).status,
      TaskStatus.completed,
    );
    expect((await draw(second.id)).status, TaskStatus.completed);
    secondHead = (await repo.getComic(novel.activeBranchId, second.id))!;
    expect(secondHead.document.panels.single['visualReview'], isFalse);
    final generated = await repo.getAsset(
      secondHead.document.panels.single['assetId'] as String,
    );
    expect(
      (generated.metadata['references'] as List).single['id'],
      first.document.panels[0]['assetId'],
    );
    expect(
      (await draw(
        chapter.id,
        panelId: first.document.panels[2]['id'] as String,
      )).status,
      TaskStatus.completed,
    );
    first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
    secondHead = (await repo.getComic(novel.activeBranchId, second.id))!;
    expect(first.document.panels[0]['visualReview'], isTrue);
    expect(first.document.panels[1]['visualReview'], isTrue);
    expect(
      secondHead.document.panels.single['visualReview'],
      isTrue,
      reason: 'D uses A, and A is now pending because A -> B -> replaced C.',
    );
  });

  for (final confirmed in [false, true]) {
    test(
      'replaced references retain their latest review state (confirmed: $confirmed)',
      () async {
        expect((await adapt()).status, TaskStatus.completed);
        expect((await draw(chapter.id)).status, TaskStatus.completed);
        final second = await nextChapter('她继续按住门闩。');
        expect((await draw(second.id)).status, TaskStatus.completed);
        final third = await nextChapter('她仍没有拉开。');
        expect((await draw(third.id)).status, TaskStatus.completed);
        var first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
        expect(
          (await draw(
            chapter.id,
            panelId: first.document.panels.last['id'] as String,
          )).status,
          TaskStatus.completed,
        );
        var secondHead = (await repo.getComic(
          novel.activeBranchId,
          second.id,
        ))!;
        expect(secondHead.document.panels.single['visualReview'], isTrue);
        final pendingAsset =
            secondHead.document.panels.single['assetId'] as String;
        if (confirmed) {
          final panels = secondHead.document.panels;
          panels.single['visualReview'] = false;
          secondHead = await repo.saveComic(
            branchId: novel.activeBranchId,
            chapterId: second.id,
            expectedRevisionId: secondHead.id,
            document: secondHead.document.editPanels(panels),
          );
        }
        var thirdHead = (await repo.getComic(novel.activeBranchId, third.id))!;
        final linked = thirdHead.document.panels;
        linked.single['referenceAssetIds'] = [pendingAsset];
        linked.single['sceneId'] = 'explicit-reference-only';
        linked.single.remove('previousPanelId');
        await repo.saveComic(
          branchId: novel.activeBranchId,
          chapterId: third.id,
          expectedRevisionId: thirdHead.id,
          document: thirdHead.document.editPanels(linked),
        );
        expect(
          (await runner.wait(
            (await service.check(
              branchId: novel.activeBranchId,
              chapterId: third.id,
              connection: connection,
            )).id,
          )).status,
          TaskStatus.completed,
        );
        expect(
          (await draw(
            second.id,
            panelId: secondHead.document.panels.single['id'] as String,
          )).status,
          TaskStatus.completed,
        );
        secondHead = (await repo.getComic(novel.activeBranchId, second.id))!;
        expect(
          secondHead.document.panels.single['assetId'],
          isNot(pendingAsset),
        );
        expect(secondHead.document.panels.single['visualReview'], isFalse);
        thirdHead = (await repo.getComic(novel.activeBranchId, third.id))!;
        expect(thirdHead.document.panels.single['visualReview'], isTrue);
        expect(
          (await draw(
            third.id,
            panelId: thirdHead.document.panels.single['id'] as String,
          )).status,
          TaskStatus.completed,
        );
        thirdHead = (await repo.getComic(novel.activeBranchId, third.id))!;
        final generated = await repo.getAsset(
          thirdHead.document.panels.single['assetId'] as String,
        );
        expect(
          (generated.metadata['references'] as List).single['id'],
          pendingAsset,
        );
        expect(
          thirdHead.document.panels.single['visualReview'],
          !confirmed,
          reason: 'Replacing a reference must preserve its latest confirmation state.',
        );
      },
    );
  }

  test(
    'reference review follows branch ancestry and checks every occurrence',
    () async {
      expect((await adapt()).status, TaskStatus.completed);
      expect((await draw(chapter.id)).status, TaskStatus.completed);
      var head = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final panels = head.document.panels;
      final assetId = panels.first['assetId'] as String;
      panels.last['assetId'] = assetId;
      panels.first['visualReview'] = false;
      panels.last['visualReview'] = true;
      head = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: head.id,
        document: ComicDocument.fromJson({
          ...head.document.toJson(),
          'panels': panels,
        }),
      );
      expect(
        await repo.comicReferencesNeedReview(novel.activeBranchId, {assetId}),
        isTrue,
      );
      final pendingFork = await repo.forkBranch(
        branchId: novel.activeBranchId,
        name: '待复核分支',
      );
      final confirmed = head.document.panels;
      for (final p in confirmed) {
        p['visualReview'] = false;
      }
      head = await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedRevisionId: head.id,
        document: head.document.editPanels(confirmed),
      );
      final confirmedFork = await repo.forkBranch(
        branchId: novel.activeBranchId,
        name: '已确认分支',
      );
      // Removing the image from each head must not discard its branch-local state.
      for (final branchId in [
        novel.activeBranchId,
        pendingFork.id,
        confirmedFork.id,
      ]) {
        final current = (await repo.getComic(branchId, chapter.id))!;
        final removed = current.document.panels;
        for (final p in removed) {
          p.remove('assetId');
          p.remove('imageTaskId');
        }
        await repo.saveComic(
          branchId: branchId,
          chapterId: chapter.id,
          expectedRevisionId: current.id,
          document: current.document.editPanels(removed),
        );
        expect(
          await repo.comicReferencesNeedReview(branchId, {assetId}),
          branchId == pendingFork.id,
        );
        expect(await repo.comicReferencesNeedReview(branchId, {}), isFalse);
      }
    },
  );

  test(
    'selected comic references take priority over automatic previous panels',
    () async {
      expect((await adapt()).status, TaskStatus.completed);
      expect((await draw(chapter.id)).status, TaskStatus.completed);
      final first = (await repo.getComic(novel.activeBranchId, chapter.id))!;
      final selectedAsset = first.document.panels.first['assetId'] as String;
      final previousAsset = first.document.panels.last['assetId'] as String;
      expect(selectedAsset, isNot(previousAsset));
      final second = await nextChapter('她继续按住门闩。');
      var head = (await repo.getComic(novel.activeBranchId, second.id))!;
      expect(
        head.document.panels.single['sceneId'],
        first.document.panels.last['sceneId'],
      );
      final panels = head.document.panels;
      panels.single['referenceAssetIds'] = [selectedAsset];
      await repo.saveComic(
        branchId: novel.activeBranchId,
        chapterId: second.id,
        expectedRevisionId: head.id,
        document: head.document.editPanels(panels),
      );
      connection = ModelConnection.fromJson({
        ...connection.raw,
        'maxReferenceImages': 1,
      });
      expect((await draw(second.id)).status, TaskStatus.completed);
      head = (await repo.getComic(novel.activeBranchId, second.id))!;
      final asset = await repo.getAsset(
        head.document.panels.single['assetId'] as String,
      );
      expect(
        (asset.metadata['references'] as List).single['id'],
        selectedAsset,
        reason: 'The confirmation says selected references are sent before the previous panel.',
      );
    },
  );
}
