import 'dart:async';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

class _Images implements ImageProvider {
  _Images(this.config, this.generateImage);
  @override
  final ModelConnection config;
  final Future<GeneratedImage> Function(ImageRequest, List<ImageReference>)
  generateImage;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) => generateImage(request, references);
  @override
  void close() {}
}

void main() {
  late StoryRepository repo;
  late Directory dir;
  late AssetLibrary library;
  late IllustrationService service;
  late TaskRunner runner;
  late String branch;
  late ModelConnection connection;
  late Future<GeneratedImage> Function(ImageRequest, List<ImageReference>)
  generate;
  setUp(() async {
    repo = StoryRepository.memory();
    dir = Directory.systemTemp.createTempSync('image-relations-');
    library = AssetLibrary(repository: repo, directory: dir);
    branch = (await repo.createNovel(title: '关联图片')).activeBranchId;
    connection = ModelConnection(
      id: 'image',
      name: '本地测试',
      baseUrl: 'http://localhost:1',
      model: 'image',
    );
    generate = (_, _) async => GeneratedImage(bytes: testPicture());
    runner = TaskRunner(
      repository: repo,
      assetLibrary: library,
      providerFactory: (_) async => throw StateError('no text model'),
      imageProviderFactory: (c) async =>
          _Images(c, (r, refs) => generate(r, refs)),
    );
    service = IllustrationService(repository: repo, runner: runner);
  });
  tearDown(() async {
    await runner.close();
    await repo.close();
    await dir.delete(recursive: true);
  });
  Future<StoryAsset> image(
    String name, {
    List<VisualReference> refs = const [],
    AssetPurpose purpose = AssetPurpose.illustration,
  }) async {
    final task = await service.generate(
      branchId: branch,
      connection: connection,
      name: name,
      request: ImageRequest(prompt: name),
      visualReferences: refs,
      purpose: purpose,
    );
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    return repo.getAsset(done.result['assetId'] as String);
  }

  Future<StoryAsset> regenerate(StoryAsset asset) async {
    final task = await service.regenerate(
      branchId: branch,
      assetId: asset.id,
      connection: connection,
    );
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error);
    expect(done.result['replacementError'], isNull);
    return repo.getAsset(done.result['assetId'] as String);
  }

  test('reference replacement keeps descendants visible and marks old inputs stale', () async {
    final reference = await image('红衣人物', purpose: AssetPurpose.reference);
    final lore = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: '人物',
      content: '人物',
      data: {
        'images': [reference.id],
        'referencePrompt': '红衣人物',
      },
    );
    final child = await image(
      '跑过桥',
      refs: [
        VisualReference(
          kind: LoreKind.character,
          name: '人物',
          prompt: '红衣人物',
          assetId: reference.id,
          entry: lore,
        ),
      ],
    );
    final next = await regenerate(reference);
    var graph = await repo.illustrationGraph(branch);
    expect(graph.descendants(next.id).map((a) => a.id), [child.id]);
    expect(graph.isStale(child), isTrue);
    expect(graph.changedInputs(child), {next.id});
    generate = (request, refs) async {
      expect(request.prompt, startsWith('跑过桥\n\nCanonical'));
      expect('Canonical visual context'.allMatches(request.prompt).length, 1);
      expect(refs, hasLength(1));
      return GeneratedImage(bytes: testPicture());
    };
    final updated = await regenerate(child);
    graph = await repo.illustrationGraph(branch);
    expect(graph.isStale(updated), isFalse);
    expect(graph.changedInputs(updated), isEmpty);
    expect(graph.referenceIds(updated), [next.id]);
    expect(graph.descendants(reference.id).map((a) => a.id), [updated.id]);
  });

  test(
    'regenerating an alternate reference keeps the explicit selection',
    () async {
      final defaultImage = await image('默认图', purpose: AssetPurpose.reference);
      final alternate = await image('侧面图', purpose: AssetPurpose.reference);
      final lore = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '人物',
        content: '人物',
        data: {
          'images': [defaultImage.id, alternate.id],
          'referencePrompt': '红衣人物',
        },
      );
      final child = await image(
        '桥上相遇',
        refs: [
          VisualReference(
            kind: LoreKind.character,
            name: '人物',
            prompt: '红衣人物',
            entry: lore,
            assetId: alternate.id,
          ),
        ],
      );
      final next = await regenerate(alternate);
      var graph = await repo.illustrationGraph(branch);
      expect(graph.referenceIds(child), [next.id]);
      expect(graph.isStale(child), isTrue);
      final updated = await regenerate(child);
      graph = await repo.illustrationGraph(branch);
      expect(graph.referenceIds(updated), [next.id]);
      expect(graph.isStale(updated), isFalse);
    },
  );

  test('regeneration replaces each embedded occurrence without moving text or changing history and forks', () async {
    final old = await image('插图');
    final content = ManuscriptContent.fromDelta([
      {
        'insert': '前文',
        'attributes': {'bold': true},
      },
      {
        'insert': {'image': 'asset:${old.id}'},
        'attributes': {'width': '80'},
      },
      {'insert': '\n后文\n'},
      {
        'insert': {'image': 'asset:${old.id}'},
      },
      {'insert': '\n'},
    ]);
    final chapter = await repo.createChapter(
      branchId: branch,
      content: content,
    );
    final fork = await repo.forkBranch(branchId: branch, name: '其他分支');
    final next = await regenerate(old);
    final current = await repo.getChapter(
      branchId: branch,
      chapterId: chapter.id,
    );
    expect(current.content.text, content.text);
    expect(current.content.delta[1], {
      'insert': {'image': 'asset:${next.id}'},
      'attributes': {'width': '80'},
    });
    expect(current.content.delta[3]['insert'], {'image': 'asset:${next.id}'});
    expect((await repo.getRevision(chapter.revisionId)).content, content);
    expect(
      (await repo.getChapter(branchId: fork.id, chapterId: chapter.id)).content,
      content,
    );
    expect((await repo.getAsset(old.id)).hash, old.hash);
  });

  test('concurrent manuscript edits preserve both outputs without applying a replacement', () async {
    final old = await image('插图');
    final chapter = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('前文').insertImage(0, old.id),
    );
    final gate = Completer<void>(), started = Completer<void>();
    generate = (_, _) async {
      started.complete();
      await gate.future;
      return GeneratedImage(bytes: testPicture());
    };
    final task = await service.regenerate(
      branchId: branch,
      assetId: old.id,
      connection: connection,
    );
    await started.future;
    final edit = await repo.saveChapter(
      branchId: branch,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('作者修改'),
    );
    gate.complete();
    final done = await runner.wait(task.id);
    expect(done.result['assetId'], isA<String>());
    expect(done.result['replacementError'], contains('正文'));
    expect((await repo.illustrationGraph(branch)).current(old.id).id, old.id);
    expect(
      (await repo.getChapter(
        branchId: branch,
        chapterId: chapter.id,
      )).revisionId,
      edit.revisionId,
    );
  });
  for (final change in [
    'new placement',
    'new lore',
    'reference removed',
    'reference changed',
  ]) {
    test('regeneration refuses concurrent $change', () async {
      final reference = await image('人物', purpose: AssetPurpose.reference);
      final lore = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '人物',
        content: '人物',
        data: {
          'images': [reference.id],
          'referencePrompt': '人物',
        },
      );
      final old = change.startsWith('reference')
          ? await image(
              '插图',
              refs: [
                VisualReference(
                  kind: LoreKind.character,
                  name: '人物',
                  prompt: '人物',
                  assetId: reference.id,
                  entry: lore,
                ),
              ],
            )
          : reference;
      final gate = Completer<void>(), started = Completer<void>();
      generate = (_, _) async {
        started.complete();
        await gate.future;
        return GeneratedImage(bytes: testPicture());
      };
      final task = await service.regenerate(
        branchId: branch,
        assetId: old.id,
        connection: connection,
      );
      await started.future;
      if (change == 'new placement') {
        await repo.createChapter(
          branchId: branch,
          content: ManuscriptContent.plainText('新插入').insertImage(0, old.id),
        );
      } else if (change == 'new lore') {
        await repo.saveLoreEntry(
          branchId: branch,
          kind: LoreKind.character,
          name: '新资料',
          content: '新资料',
          data: {
            'images': [old.id],
          },
        );
      } else if (change == 'reference removed') {
        await repo.deleteLoreEntry(
          branchId: branch,
          id: lore.id,
          expectedRevisionId: lore.revisionId,
        );
      } else {
        await repo.saveLoreEntry(
          branchId: branch,
          id: lore.id,
          expectedRevisionId: lore.revisionId,
          kind: lore.kind,
          name: lore.name,
          content: lore.content,
          data: {...lore.data, 'referencePrompt': '蓝衣人物'},
        );
      }
      gate.complete();
      final done = await runner.wait(task.id);
      expect(done.result['replacementError'], isNotNull);
      expect((await repo.illustrationGraph(branch)).current(old.id).id, old.id);
    });
  }

  for (final tags in [false, true]) {
    test(
      'legacy ${tags ? 'tag' : 'prose'} prompts do not duplicate visual context',
      () async {
        if (tags) {
          connection = ModelConnection(
            id: 'image',
            name: '本地测试',
            baseUrl: 'http://localhost:1',
            model: 'image',
            protocol: ModelProtocol.novelAI,
          );
        }
        final reference = await image(
          'red coat',
          purpose: AssetPurpose.reference,
        );
        final original = await image(
          'crossing bridge',
          refs: [
            VisualReference(
              kind: LoreKind.character,
              name: 'hero',
              prompt: 'red coat',
              assetId: reference.id,
            ),
          ],
        );
        final metadata = original.metadata..remove('sourcePrompt');
        final legacy = await repo.storeAsset(
          branchId: branch,
          name: original.name,
          taskId: original.taskId,
          metadata: metadata,
          prepared: PreparedAsset(
            hash: original.hash,
            thumbnailHash: original.thumbnailHash,
            width: original.width,
            height: original.height,
            byteLength: original.byteLength,
          ),
        );
        expect(
          IllustrationService.sourcePrompt(legacy, tags: tags),
          'crossing bridge',
        );
        generate = (request, refs) async {
          expect(request.prompt, original.metadata['prompt']);
          return GeneratedImage(bytes: testPicture());
        };
        await regenerate(legacy);
      },
    );
  }

  test(
    'shared descendants are deduplicated and ordered before their consumers',
    () async {
      final root = await image('root');
      VisualReference ref(StoryAsset a) => VisualReference(
        kind: LoreKind.character,
        name: a.name,
        prompt: a.name,
        assetId: a.id,
      );
      final left = await image('left', refs: [ref(root)]);
      final right = await image('right', refs: [ref(root)]);
      final shared = await image('shared', refs: [ref(left), ref(right)]);
      final graph = await repo.illustrationGraph(branch);
      final ids = graph.descendants(root.id).map((a) => a.id).toList();
      expect(ids.toSet(), {left.id, right.id, shared.id});
      expect(ids, hasLength(3));
      expect(ids.last, shared.id);
      for (final id in ids) {
        await regenerate(graph.assets[id]!);
      }
      final updated = await repo.illustrationGraph(branch);
      expect(updated.isStale(updated.current(shared.id)), isFalse);
    },
  );

  test('inherited dependencies stay connected without later parent changes leaking', () async {
    final root = await image('root');
    VisualReference ref(StoryAsset a) => VisualReference(
      kind: LoreKind.character,
      name: a.name,
      prompt: a.name,
      assetId: a.id,
    );
    final middle = await image('middle', refs: [ref(root)]);
    final leaf = await image('leaf', refs: [ref(middle)]);
    final nextRoot = await regenerate(root);
    await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: 'root',
      content: 'root',
      data: {
        'images': [nextRoot.id],
        'referencePrompt': 'root',
      },
    );
    await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('text').insertImage(0, leaf.id),
    );
    final fork = await repo.forkBranch(branchId: branch, name: 'fork');
    final laterRoot = await regenerate(nextRoot);
    final graph = await repo.illustrationGraph(fork.id);
    expect(graph.current(root.id).id, nextRoot.id);
    expect(graph.descendants(nextRoot.id).map((a) => a.id), [
      middle.id,
      leaf.id,
    ]);
    expect(graph.isStale(leaf), isTrue);
    expect(graph.referenceIds(middle), isNot(contains(laterRoot.id)));
  });

  test('removing a reference image blocks regeneration before calling the provider', () async {
    final root = await image('root');
    final lore = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: 'root',
      content: 'root',
      data: {
        'images': [root.id],
        'referencePrompt': 'root',
      },
    );
    final child = await image(
      'child',
      refs: [
        VisualReference(
          kind: LoreKind.character,
          name: 'root',
          prompt: 'root',
          assetId: root.id,
          entry: lore,
        ),
      ],
    );
    final next = await regenerate(root);
    final currentLore = await repo.getLoreEntry(branchId: branch, id: lore.id);
    await repo.saveLoreEntry(
      branchId: branch,
      id: lore.id,
      expectedRevisionId: currentLore.revisionId,
      kind: lore.kind,
      name: lore.name,
      content: lore.content,
      data: {'images': <String>[], 'referencePrompt': 'root'},
    );
    final graph = await repo.illustrationGraph(branch);
    expect(graph.descendants(next.id).map((a) => a.id), [child.id]);
    expect(graph.isStale(child), isTrue);
    generate = (_, _) async => throw StateError('must not call provider');
    await expectLater(
      service.regenerate(
        branchId: branch,
        assetId: child.id,
        connection: connection,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('edited reference description follows the replacement but leaves old metadata intact', () async {
    final root = await image('红衣人物', purpose: AssetPurpose.reference);
    await repo.setAssetReference(
      root.id,
      kind: LoreKind.character,
      prompt: '红衣人物',
    );
    final lore = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: '人物',
      content: '人物',
      data: {
        'images': [root.id],
        'referencePrompt': '红衣人物',
      },
    );
    final task = await service.regenerate(
      branchId: branch,
      assetId: root.id,
      connection: connection,
      prompt: '蓝衣人物',
    );
    final done = await runner.wait(task.id);
    expect(done.result['replacementError'], isNull);
    final next = await repo.getAsset(done.result['assetId'] as String);
    expect(next.metadata['referencePrompt'], '蓝衣人物');
    expect(
      (await repo.getLoreEntry(
        branchId: branch,
        id: lore.id,
      )).data['referencePrompt'],
      '蓝衣人物',
    );
    expect((await repo.getAsset(root.id)).metadata['referencePrompt'], '红衣人物');
  });

  for (final cancel in [false, true]) {
    test(
      '${cancel ? 'cancel' : 'failure'} preserves the old image and placements',
      () async {
        final old = await image('插图');
        final chapter = await repo.createChapter(
          branchId: branch,
          content: ManuscriptContent.plainText('正文').insertImage(0, old.id),
        );
        final gate = Completer<void>(), started = Completer<void>();
        generate = (_, _) async {
          started.complete();
          await gate.future;
          throw const ProviderException('test', '本地失败');
        };
        final task = await service.regenerate(
          branchId: branch,
          assetId: old.id,
          connection: connection,
        );
        await started.future;
        if (cancel) await runner.cancel(task.id);
        gate.complete();
        final done = await runner.wait(task.id);
        expect(done.status, cancel ? TaskStatus.cancelled : TaskStatus.failed);
        expect(
          (await repo.illustrationGraph(branch)).current(old.id).id,
          old.id,
        );
        expect(
          (await repo.getChapter(
            branchId: branch,
            chapterId: chapter.id,
          )).revisionId,
          chapter.revisionId,
        );
      },
    );
  }
}
