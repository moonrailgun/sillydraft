import 'dart:async';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

class _ImageModel implements ImageProvider {
  _ImageModel(this.config, this.script);
  @override
  final ModelConnection config;
  final Future<GeneratedImage> Function(
    ImageRequest,
    List<ImageReference>,
    GenerationCancellation,
  )
  script;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) => script(request, references, cancellation ?? GenerationCancellation());
  @override
  void close() {}
}

void main() {
  test('restart makes never-started image jobs retryable instead of stranded queued', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '恢复排队任务');
    final queued = await repo.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.illustration,
      input: {},
    );
    expect(await repo.recoverInterruptedTasks(), 1);
    expect((await repo.getTask(queued.id)).status, TaskStatus.interrupted);
  });
  test('image retries are new jobs, success binds old source and never edits prose', () async {
    final dir = Directory.systemTemp.createTempSync('sillydraft-images-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final assets = AssetLibrary(repository: repo, directory: dir);
    final novel = await repo.createNovel(title: '图片任务');
    final c = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    final s = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: c.id,
      content: ManuscriptContent.plainText('雨中的渡口'),
    );
    final config = ModelConnection(
      id: 'image',
      name: 'image',
      baseUrl: 'http://localhost:1',
      model: 'image',
    );
    final gate = Completer<void>();
    var calls = 0;
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (_) async => throw StateError('must use image provider'),
      assetLibrary: assets,
      imageProviderFactory: (c) async => _ImageModel(c, (
        r,
        refs,
        cancel,
      ) async {
        expect(r.prompt, '画一个港口');
        if (++calls == 1) throw const ProviderException('quota', '测试配额错误');
        await gate.future;
        cancel.check();
        return GeneratedImage(bytes: testPicture(), revisedPrompt: '一个阴雨港口');
      }),
    );
    addTearDown(runner.close);
    final service = IllustrationService(repository: repo, runner: runner);
    final first = await service.generate(
      branchId: s.branchId,
      sceneId: s.id,
      connection: config,
      name: '港口',
      request: ImageRequest(prompt: '画一个港口'),
    );
    expect((await runner.wait(first.id)).status, TaskStatus.failed);
    expect(await repo.listAssets(novel.id), isEmpty);
    final edited = await repo.saveScene(
      branchId: s.branchId,
      sceneId: s.id,
      expectedRevisionId: s.revisionId,
      content: ManuscriptContent.plainText('编辑后已放晴'),
    );
    final retry = await runner.resume(first.id);
    expect(retry.id, isNot(first.id));
    expect(retry.retryOf, first.id);
    gate.complete();
    final done = await runner.wait(retry.id);
    expect(done.status, TaskStatus.completed);
    final asset = await repo.getAsset(done.result['assetId'] as String);
    expect(asset.sourceRevisionId, s.revisionId);
    expect(asset.metadata['prompt'], '画一个港口');
    expect(await repo.assetSourceCurrent(asset.id), false);
    expect(
      (await repo.getScene(branchId: s.branchId, sceneId: s.id)).revisionId,
      edited.revisionId,
    );
    expect(await repo.listProposals(s.branchId), isEmpty);
  });
  test(
    'cancelling an image task prevents late output from becoming an asset',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'sillydraft-cancel-image-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final novel = await repo.createNovel(title: '取消插画');
      final gate = Completer<void>(), started = Completer<void>();
      final config = ModelConnection(
        id: 'i',
        name: 'i',
        baseUrl: 'http://localhost:1',
        model: 'i',
      );
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (_) async => throw StateError('text provider'),
        assetLibrary: AssetLibrary(repository: repo, directory: dir),
        imageProviderFactory: (c) async => _ImageModel(c, (_, _, _) async {
          started.complete();
          await gate.future;
          return GeneratedImage(bytes: testPicture());
        }),
      );
      addTearDown(runner.close);
      final task = await IllustrationService(repository: repo, runner: runner)
          .generate(
            branchId: novel.activeBranchId,
            connection: config,
            name: '封面',
            request: ImageRequest(prompt: '封面'),
          );
      await started.future;
      await runner.cancel(task.id);
      gate.complete();
      expect((await runner.wait(task.id)).status, TaskStatus.cancelled);
      expect(await repo.listAssets(novel.id), isEmpty);
    },
  );
}
