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
        request = ImageRequest.fromJson({
          ...jsonObject(task.input['imageRequest'], 'imageRequest'),
          'usagePurpose': task.kind.name,
          'usageBranchId': task.branchId,
          if (task.isRemote) 'executionId': task.id,
          if (task.isRemote)
            'retrieveOnly': task.result['remoteReconnect'] == true,
        });
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
      final used =
          (references.isEmpty ? null : connection.comfyEditWorkflow) ??
          connection.comfyWorkflow;
      await repository.completeIllustrationTask(
        taskId: task.id,
        prepared: prepared,
        metadata: {
          'prompt': request.prompt,
          'revisedPrompt': output.revisedPrompt,
          'model': ?connection.sentModel,
          if (used != null && used.filename.isNotEmpty)
            'workflow': used.filename,
          'connectionId': connection.id,
          'parameters': request.parameters,
          'references': input['references'],
          'visualReferences': ?input['visualReferences'],
          'sourcePrompt': ?input['sourcePrompt'],
          'previousSceneAssetId': ?input['previousSceneAssetId'],
          'scene': ?input['scene'],
          if (input['purpose'] == AssetPurpose.reference.name)
            'referencePrompt': request.prompt,
          'illustrationAnchor': ?input['illustrationAnchor'],
          'usage': output.usage,
        },
      );
    } finally {
      provider.close();
    }
  }
}
