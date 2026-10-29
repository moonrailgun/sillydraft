import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'support/image_scene.dart';

class ReferencePainter implements ImageProvider {
  ReferencePainter(this.config, this.requests, this.counts);
  @override
  final ModelConnection config;
  final List<ImageRequest> requests;
  final List<int> counts;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    requests.add(request);
    counts.add(references.length);
    return GeneratedImage(bytes: testPicture());
  }

  @override
  void close() {}
}

void main() {
  test(
    'reference planning keeps lore type and chapter visibility checks',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final branch = (await repo.createNovel(title: '参考资料')).activeBranchId;
      final chapter = await repo.createChapter(branchId: branch);
      final fork = await repo.forkBranch(branchId: branch, name: '其他分支');
      final hidden = await repo.saveLoreEntry(
        branchId: fork.id,
        kind: LoreKind.character,
        name: '阿青',
        content: 'hidden character',
      );
      final character = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '阿青',
        content: 'short black hair',
      );
      await repo.createChapter(branchId: branch);
      final future = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '阿青',
        content: 'future character',
      );
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (_) async =>
            throw StateError('No generation expected'),
      );
      addTearDown(runner.close);
      final service = IllustrationService(repository: repo, runner: runner);
      for (final id in [hidden.id, future.id, 'missing']) {
        await expectLater(
          service.planReferences(
            branchId: branch,
            chapterId: chapter.id,
            subjects: [
              {
                'kind': 'character',
                'name': '阿青',
                'prompt': 'short black hair',
                'loreId': id,
              },
            ],
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        service.planReferences(
          branchId: branch,
          chapterId: chapter.id,
          subjects: [
            {
              'kind': 'location',
              'name': '阿青',
              'prompt': 'wooden cabin',
              'loreId': character.id,
            },
          ],
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'correction',
            allOf(
              contains('character'),
              contains('location'),
              contains('list_lore'),
            ),
          ),
        ),
      );
      await expectLater(
        service.planReferences(
          branchId: branch,
          subjects: [
            {'kind': 'character', 'name': '阿青', 'prompt': 'short black hair'},
          ],
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'a full reference library rejects a new selected image before generation',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final branch = (await repo.createNovel(title: '参考资料')).activeBranchId;
      final assets = <StoryAsset>[];
      for (var i = 0; i < 9; i++) {
        assets.add(
          await repo.storeAsset(
            branchId: branch,
            name: '阿青',
            prepared: PreparedAsset(
              hash: i.toString() * 64,
              thumbnailHash: 'a' * 64,
              width: 1,
              height: 1,
              byteLength: 1,
            ),
            metadata: {
              'referenceKind': 'character',
              'referencePrompt': 'short black hair',
            },
          ),
        );
      }
      final entry = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '阿青',
        content: '阿青',
        data: {
          'referencePrompt': 'short black hair',
          'images': assets.take(8).map((a) => a.id).toList(),
        },
      );
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (_) async =>
            throw StateError('No generation expected'),
      );
      addTearDown(runner.close);
      final service = IllustrationService(repository: repo, runner: runner);
      final plans = await service.planReferences(
        branchId: branch,
        subjects: [
          {'kind': 'character', 'name': '阿青', 'prompt': 'short black hair'},
        ],
      );
      await expectLater(
        service.addAssetReferences(branch, null, plans, [assets.last.id]),
        throwsFormatException,
      );
      expect(plans.single.assetId, assets.first.id);
      expect(
        (await repo.getLoreEntry(
          branchId: branch,
          id: entry.id,
        )).data['images'],
        hasLength(8),
      );
    },
  );

  test(
    'selected references keep their description, type and planned subject',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final branch = (await repo.createNovel(title: '参考资料')).activeBranchId;
      final asset = await repo.storeAsset(
        branchId: branch,
        name: '阿青',
        prepared: PreparedAsset(
          hash: 'a' * 64,
          thumbnailHash: 'b' * 64,
          width: 1,
          height: 1,
          byteLength: 1,
        ),
        metadata: {'prompt': 'original generation prompt', 'source': 'import'},
      );
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (_) async =>
            throw StateError('No generation expected'),
      );
      addTearDown(runner.close);
      final service = IllustrationService(repository: repo, runner: runner);
      final plans = await service.planReferences(
        branchId: branch,
        subjects: [
          {
            'kind': 'character',
            'name': '阿青',
            'prompt': 'new guessed appearance',
          },
        ],
      );
      await expectLater(
        service.addAssetReferences(branch, null, plans, [asset.id]),
        throwsFormatException,
      );
      for (final (kind, prompt) in [
        (LoreKind.world, 'test'),
        (LoreKind.character, '  '),
        (LoreKind.location, 'a' * 4001),
      ]) {
        await expectLater(
          repo.setAssetReference(asset.id, kind: kind, prompt: prompt),
          throwsFormatException,
        );
      }
      await repo.setAssetReference(
        asset.id,
        kind: LoreKind.character,
        prompt: ' short black hair ',
      );
      expect((await repo.getAsset(asset.id)).metadata, {
        'prompt': 'original generation prompt',
        'source': 'import',
        'referenceKind': 'character',
        'referencePrompt': 'short black hair',
      });
      await service.addAssetReferences(branch, null, plans, [asset.id]);
      expect(plans, hasLength(1));
      expect(plans.single.assetId, asset.id);
      expect(plans.single.prompt, 'short black hair');
      await service.ensureReference(
        branchId: branch,
        connection: ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        ),
        reference: plans.single,
      );
      final saved = (await repo.listLore(branch)).single;
      expect(saved.data['images'], [asset.id]);
      expect(saved.data['referencePrompt'], 'short black hair');
    },
  );

  test('scene facts cannot be omitted or changed under the same id', () {
    final scene = validateImageScene(emptyImageContext['scene']);
    expect(
      () => validateImageScene({...scene}..remove('lighting')),
      throwsFormatException,
    );
    expect(
      () => checkSceneContinuity({...scene, 'weather': 'rain'}, scene),
      throwsFormatException,
    );
    checkSceneContinuity({...scene, 'characters': 'none'}, scene);
    expect(
      () => validateSceneReferences({...scene, 'characters': 'A Qing'}, []),
      throwsFormatException,
    );
    expect(
      () => validateSceneReferences({...scene, 'location': 'wooden cabin'}, []),
      throwsFormatException,
    );
  });

  test(
    'generic model image capacity is explicit and survives serialization',
    () {
      for (final capacity in [0, 1, 16]) {
        final connection = ModelConnection(
          id: 'image',
          name: 'image',
          baseUrl: 'http://localhost:1',
          model: 'test',
          maxReferenceImages: capacity,
        );
        expect(
          referenceLimit(ModelConnection.fromJson(connection.raw)),
          capacity,
        );
      }
      expect(
        () => ModelConnection(
          id: 'image',
          name: 'image',
          baseUrl: 'http://localhost:1',
          model: 'test',
          maxReferenceImages: -1,
        ),
        throwsFormatException,
      );
      expect(
        () => ModelConnection(
          id: 'image',
          name: 'image',
          baseUrl: 'http://localhost:1',
          model: 'test',
          maxReferenceImages: 17,
        ),
        throwsFormatException,
      );
    },
  );
  for (final limit in [0, 1, 16]) {
    test(
      'reference creation, reuse and stable descriptions with $limit inputs',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final dir = Directory.systemTemp.createTempSync('visual-reference-');
        addTearDown(() => dir.deleteSync(recursive: true));
        final novel = await repo.createNovel(title: '雾港');
        final branch = novel.activeBranchId;
        final connection = ModelConnection(
          id: 'image',
          name: 'image',
          baseUrl: 'http://localhost:1',
          model: 'test',
          protocol: limit == 0
              ? ModelProtocol.novelAI
              : limit == 1
              ? ModelProtocol.comfyUI
              : ModelProtocol.openAICompatible,
          comfyWorkflow: limit != 1
              ? null
              : ComfyWorkflow(
                  nodes: {
                    '1': {
                      'class_type': 'LoadImage',
                      'inputs': {'image': '', 'text': ''},
                    },
                  },
                  promptInput: '1.text',
                  outputNode: '1',
                  imageInputs: ['1.image'],
                ),
        );
        final requests = <ImageRequest>[], counts = <int>[];
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (_) async => throw StateError('No text call'),
          assetLibrary: AssetLibrary(repository: repo, directory: dir),
          imageProviderFactory: (c) async =>
              ReferencePainter(c, requests, counts),
        );
        addTearDown(runner.close);
        final service = IllustrationService(repository: repo, runner: runner);
        final subjects = [
          {
            'kind': 'location',
            'name': '渡口',
            'prompt': 'stone quay, red wooden arch',
          },
          {
            'kind': 'character',
            'name': '阿青',
            'prompt': 'short black hair, green eyes',
          },
        ];
        final plans = await service.planReferences(
          branchId: branch,
          subjects: subjects,
        );
        for (final plan in plans) {
          await service.ensureReference(
            branchId: branch,
            connection: connection,
            reference: plan,
          );
        }
        final task = await service.generate(
          branchId: branch,
          connection: connection,
          name: '相遇',
          request: ImageRequest(
            prompt: 'At dawn in the rain, A Qing stands at the quay.',
          ),
          visualReferences: plans,
        );
        final done = await runner.wait(task.id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect(requests, hasLength(3));
        expect(counts, [
          0,
          0,
          limit == 0
              ? 0
              : limit == 1
              ? 1
              : 2,
        ]);
        expect(requests.last.prompt, contains('stone quay, red wooden arch'));
        expect(requests.last.prompt, contains('short black hair, green eyes'));
        expect(requests.last.prompt, contains('At dawn in the rain'));
        final asset = await repo.getAsset(done.result['assetId'] as String);
        if (limit > 0) {
          expect(
            (asset.metadata['references'] as List).first['id'],
            plans[1].assetId,
          );
        }
        expect(
          (await repo.listLore(branch))
              .every((e) => e.certainty == LoreCertainty.inference),
          isTrue,
        );
        final reused = await service.planReferences(
          branchId: branch,
          subjects: [
            for (final subject in subjects)
              {...subject, 'prompt': 'unwanted new appearance'},
          ],
        );
        for (final plan in reused) {
          await service.ensureReference(
            branchId: branch,
            connection: connection,
            reference: plan,
          );
        }
        expect(requests, hasLength(3));
        expect(reused.first.prompt, subjects.first['prompt']);
        expect(reused.last.assetId, plans.last.assetId);
      },
    );
  }
}
