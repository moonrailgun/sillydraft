part of 'task_runner.dart';

extension _IllustrationExecution on TaskRunner {
  Future<void> _executeIllustration(
    GenerationTask task,
    GenerationCancellation cancel,
  ) async {
    final factory = imageProviderFactory, library = assetLibrary;
    if (factory == null || library == null) {
      throw const ProviderException('image_unavailable', '生图服务或本地图片目录尚未配置');
    }
    final input = task.input,
        request = ImageRequest.fromJson(
          jsonObject(task.input['imageRequest'], 'imageRequest'),
        );
    final connection = ModelConnection.fromJson(
      jsonObject(input['connection'], 'connection'),
    );
    final references = <ImageReference>[];
    final novel = (await repository.getBranch(task.branchId)).novelId;
    for (final raw in (input['references'] as List? ?? [])) {
      final ref = jsonObject(raw, 'reference'),
          asset = await repository.getAsset(ref['id'] as String);
      if (asset.novelId != novel || asset.hash != ref['hash']) {
        throw const ProviderException('image_reference', '参考图片已改变或不属于当前作品');
      }
      references.add(
        ImageReference(
          bytes: await library.read(asset.id),
          mimeType: 'image/png',
        ),
      );
    }
    cancel.check();
    final provider = await factory(connection);
    try {
      await repository.updateTask(
        task.id,
        status: TaskStatus.running,
        result: {'stage': 'generating'},
      );
      final output = await provider.generate(
        request,
        references: references,
        cancellation: cancel,
      );
      cancel.check();
      await repository.updateTask(
        task.id,
        status: TaskStatus.running,
        result: {'stage': 'saving'},
      );
      PreparedAsset prepared;
      try {
        prepared = await library.prepare(output.bytes);
      } on FormatException catch (e) {
        throw ProviderException('image_data', e.message);
      }
      cancel.check();
      await repository.completeIllustrationTask(
        taskId: task.id,
        prepared: prepared,
        metadata: {
          'prompt': request.prompt,
          'revisedPrompt': output.revisedPrompt,
          'model': connection.model,
          'connectionId': connection.id,
          'parameters': request.parameters,
          'references': input['references'],
          'usage': output.usage,
        },
      );
    } finally {
      provider.close();
    }
  }
}
