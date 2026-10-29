import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'task_runner_test.dart' show ScriptProvider;

const cabin = {
  'id': 'rainy-cabin',
  'time': 'night',
  'location': 'wooden cabin',
  'weather': 'rain outside',
  'lighting': 'warm oil lamp on the table',
  'layout': 'window on the left',
  'props': 'wooden table and oil lamp',
  'characters': 'A Qing',
};
const subjects = [
  {
    'kind': 'location',
    'name': 'wooden cabin',
    'prompt': 'wooden cabin, window on the left, wooden table',
  },
  {
    'kind': 'character',
    'name': 'A Qing',
    'prompt': 'short black hair, green eyes',
  },
];

class _Painter implements ImageProvider {
  _Painter(this.config, this.draw);
  @override
  final ModelConnection config;
  final Future<GeneratedImage> Function(ImageRequest, GenerationCancellation?)
  draw;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) => draw(request, cancellation);
  @override
  void close() {}
}

void main() {
  for (final batch in [false, true]) {
    test(
      'wrong lore kind can be corrected before image approval: $batch',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final dir = Directory.systemTemp.createTempSync('agent-lore-error-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final novel = await repo.createNovel(title: '雨夜木屋');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('她推门进屋。'),
        );
        final world = await repo.saveLoreEntry(
          branchId: chapter.branchId,
          kind: LoreKind.world,
          name: '角色:A Qing',
          content: 'short black hair, green eyes',
        );
        final character = await repo.saveLoreEntry(
          branchId: chapter.branchId,
          kind: LoreKind.character,
          name: 'A Qing',
          content: 'short black hair, green eyes',
        );
        final conversation = await repo.createConversation(
          branchId: chapter.branchId,
        );
        final connection = ModelConnection(
          id: 'image',
          name: 'image',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        final errors = <Map<String, dynamic>>[];
        final imageRequests = <ImageRequest>[];
        var rounds = 0;
        final runner = TaskRunner(
          repository: repo,
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            final round = rounds++;
            if (round > 0) {
              errors.add(
                jsonDecode(request.messages.last['content'] as String)
                    as Map<String, dynamic>,
              );
            }
            if (round > 1) {
              yield const TextDelta('无法生成');
              yield const GenerationFinished('stop');
              return;
            }
            final item = {
              'name': '推门进屋',
              'prompt': 'A Qing enters a dim cabin',
              if (batch) 'quote': '她推门进屋。',
              'scene': cabin,
              'subjects': [
                subjects.first,
                {
                  ...subjects.last,
                  'loreId': round == 0 ? world.id : character.id,
                },
              ],
            };
            yield ToolCallReady(
              'image-$round',
              batch ? 'generate_images' : 'generate_image',
              batch
                  ? {
                      'images': [item],
                    }
                  : item,
            );
            yield const GenerationFinished('tool_calls');
          }),
          imageProviderFactory: (c) async => _Painter(c, (request, _) async {
            imageRequests.add(request);
            return GeneratedImage(bytes: testPicture());
          }),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          message: '生成本章插图',
          attachChapterId: chapter.id,
          illustrationOnly: !batch,
          illustrationBatch: batch,
        );
        GenerationTask pending = task;
        for (var i = 0; i < 300; i++) {
          pending = await repo.getTask(task.id);
          if (!pending.isActive ||
              pending.result['imageConfirmation'] != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(errors, hasLength(1));
        expect(errors.single['code'], 'invalid_arguments');
        expect(
          errors.single['error'],
          allOf(
            contains(world.id),
            contains('world'),
            contains('character'),
            contains('list_lore'),
          ),
        );
        final messages = await repo.getAgentMessages(conversation);
        expect(
          jsonDecode(messages.singleWhere((m) => m.role == 'tool').content),
          errors.single,
        );
        expect(imageRequests, isEmpty);
        expect(await repo.listAssets(novel.id), isEmpty);
        final unchanged = await repo.listLore(chapter.branchId);
        expect(unchanged, hasLength(2));
        expect(unchanged.every((e) => e.data['images'] == null), isTrue);
        final confirmation = pending.result['imageConfirmation'] as Map;
        expect(confirmation['newReferences'], hasLength(2));
        await runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: true,
        );
        final done = await runner.wait(task.id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect(imageRequests, hasLength(3));
        final savedCharacter = await repo.getLoreEntry(
          branchId: chapter.branchId,
          id: character.id,
        );
        expect(savedCharacter.data['images'], hasLength(1));
        final savedWorld = await repo.getLoreEntry(
          branchId: chapter.branchId,
          id: world.id,
        );
        expect(savedWorld.revisionId, world.revisionId);
        expect(savedWorld.kind, LoreKind.world);
        expect(rounds, 2);
      },
    );
  }

  for (final outcome in [
    'complete',
    'reject',
    'fail',
    'cancel',
    'changed',
    'incomplete',
    'conflict',
    'missing subjects',
    'oversized prompt',
    'oversized labels',
  ]) {
    test('scene and reference pipeline: $outcome', () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final dir = Directory.systemTemp.createTempSync('agent-visual-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final novel = await repo.createNovel(title: '雨夜木屋');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('她推门进屋。\n她坐到桌前。'),
      );
      final conversation = await repo.createConversation(
        branchId: novel.activeBranchId,
      );
      final connection = ModelConnection(
        id: 'image',
        name: 'image',
        baseUrl: 'http://localhost:1',
        model: 'test',
      );
      final imageRequests = <ImageRequest>[];
      final firstStarted = Completer<void>();
      var calls = 0;
      final runner = TaskRunner(
        repository: repo,
        assetLibrary: AssetLibrary(repository: repo, directory: dir),
        providerFactory: (c) async => ScriptProvider(c, (_, _) async* {
          if (calls++ > 0) {
            yield const TextDelta('无法生成');
            yield const GenerationFinished('stop');
            return;
          }
          yield ToolCallReady('batch', 'generate_images', {
            'images': [
              for (final (i, quote) in ['她推门进屋。', '她坐到桌前。'].indexed)
                {
                  'name': '画面$i',
                  'prompt': outcome == 'oversized labels'
                      ? 'a' *
                            (32000 -
                                visualPrompt('', [
                                  for (final subject in subjects)
                                    VisualReference(
                                      kind: LoreKind.values.byName(
                                        subject['kind']!,
                                      ),
                                      name: subject['name']!,
                                      prompt: subject['prompt']!,
                                    ),
                                ], cabin).length)
                      : outcome == 'oversized prompt'
                      ? 'a' * 31999
                      : i == 0
                      ? 'A Qing enters a dim cabin'
                      : 'A Qing sits in a cozy room',
                  'quote': quote,
                  'scene': outcome == 'incomplete'
                      ? ({...cabin}..remove('lighting'))
                      : {
                          ...cabin,
                          if (outcome == 'conflict' && i == 1)
                            'weather': 'sunny',
                        },
                  'subjects': outcome == 'missing subjects'
                      ? <Map<String, String>>[]
                      : subjects,
                },
            ],
          });
          yield const GenerationFinished('tool_calls');
        }),
        imageProviderFactory: (c) async => _Painter(c, (request, cancel) async {
          imageRequests.add(request);
          if (!firstStarted.isCompleted) firstStarted.complete();
          if (outcome == 'fail') {
            throw const ProviderException('fixture', 'reference unavailable');
          }
          if (outcome == 'cancel') {
            final cancelled = Completer<void>();
            final remove = cancel!.onCancel(cancelled.complete);
            await cancelled.future;
            remove();
            cancel.check();
          }
          if (outcome == 'changed' && imageRequests.length == 1) {
            await repo.saveChapter(
              branchId: chapter.branchId,
              chapterId: chapter.id,
              expectedRevisionId: chapter.revisionId,
              content: ManuscriptContent.plainText('已经转场。'),
            );
          }
          return GeneratedImage(bytes: testPicture());
        }),
      );
      addTearDown(runner.close);
      final task = await EditorAgent(repository: repo, runner: runner).send(
        conversationId: conversation,
        connection: connection,
        imageConnection: connection,
        message: '本章亮点生图',
        attachChapterId: chapter.id,
        illustrationBatch: true,
      );
      GenerationTask pending = task;
      for (var i = 0; i < 300; i++) {
        pending = await repo.getTask(task.id);
        if (!pending.isActive || pending.result['imageConfirmation'] != null) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(imageRequests, isEmpty);
      if ([
        'incomplete',
        'conflict',
        'missing subjects',
        'oversized prompt',
        'oversized labels',
      ].contains(outcome)) {
        expect(pending.result['imageConfirmation'], isNull);
        expect((await runner.wait(task.id)).status, TaskStatus.failed);
        expect(await repo.listLore(chapter.branchId), isEmpty);
        return;
      }
      final confirmation = pending.result['imageConfirmation'] as Map;
      expect(confirmation['newReferences'], hasLength(2));
      for (final preview in confirmation['images'] as List) {
        for (final fact in cabin.values.skip(1)) {
          expect(preview['prompt'], contains(fact));
        }
      }
      await runner.respondToImageConfirmation(
        task.id,
        confirmation['id'] as String,
        approved: outcome != 'reject',
      );
      if (outcome == 'cancel') {
        await firstStarted.future;
        await runner.cancel(task.id);
      }
      final done = await runner.wait(task.id);
      if (outcome != 'complete') {
        expect(
          done.status,
          ['reject', 'cancel'].contains(outcome)
              ? TaskStatus.cancelled
              : TaskStatus.failed,
          reason: done.error,
        );
        expect(
          imageRequests.every((r) => r.prompt.contains('reference,')),
          isTrue,
        );
        if (outcome == 'reject') {
          expect(await repo.listAssets(novel.id), isEmpty);
        }
        if (outcome == 'fail') expect(imageRequests, hasLength(1));
        return;
      }
      expect(done.status, TaskStatus.completed, reason: done.error);
      expect(imageRequests, hasLength(4));
      final lore = await repo.listLore(chapter.branchId);
      expect(lore, hasLength(2));
      final character = lore.singleWhere((e) => e.kind == LoreKind.character);
      final location = lore.singleWhere((e) => e.kind == LoreKind.location);
      final assets = (await repo.listAssets(novel.id))
          .where((a) => a.purpose == AssetPurpose.illustration)
          .toList();
      final first = assets.singleWhere((a) => a.name == '画面0');
      final second = assets.singleWhere((a) => a.name == '画面1');
      expect((first.metadata['references'] as List).map((r) => r['id']), [
        character.data['images'][0],
        location.data['images'][0],
      ]);
      expect((second.metadata['references'] as List).map((r) => r['id']), [
        character.data['images'][0],
        first.id,
        location.data['images'][0],
      ]);
      expect(second.metadata['scene'], cabin);
      expect(
        imageRequests.last.prompt,
        contains('Reference image 1: character A Qing'),
      );
      expect(
        imageRequests.last.prompt,
        contains('Reference image 2: previous view of this scene'),
      );
      expect(
        imageRequests.last.prompt,
        contains('Reference image 3: location wooden cabin'),
      );
      final service = IllustrationService(repository: repo, runner: runner);
      expect(
        (await service.savedScenes(
          chapter.branchId,
          chapter.id,
        )).single['assetId'],
        second.id,
      );
      final inserted = await repo.insertIllustration(
        branchId: chapter.branchId,
        chapterId: chapter.id,
        expectedRevisionId: chapter.revisionId,
        assetId: first.id,
        offset: 6,
      );
      expect(
        await service.savedScenes(chapter.branchId, chapter.id),
        hasLength(1),
      );
      await repo.saveChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
        expectedRevisionId: inserted.revisionId,
        content: ManuscriptContent.plainText('走出木屋。'),
      );
      expect(await service.savedScenes(chapter.branchId, chapter.id), isEmpty);
    });
  }
}
