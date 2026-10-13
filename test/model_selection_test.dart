import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

ModelConnection connection(String id, Map<String, dynamic> fields) =>
    ModelConnection.fromJson({
      'id': id,
      'name': id,
      'baseUrl': 'http://localhost:8188',
      'model': 'first',
      ...fields,
    });

void main() {
  late AppServices services;
  setUp(() {
    services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
  });
  tearDown(() => services.close());

  test('image-only remote tasks can still confirm cancellation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final config = ModelConnection(
      id: 'remote-image',
      name: '远程生图',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'illustrator',
      protocol: ModelProtocol.sillyDraftRunner,
      kind: ModelKind.image,
    );
    await services.saveConnection(config, apiKey: 'remote-secret');
    final novel = await services.repository.createNovel(title: '远程取消');
    final task = await services.repository.createTask(
      branchId: novel.activeBranchId,
      kind: TaskKind.illustration,
      input: {'connection': config.raw},
    );
    var requests = 0;
    server.listen((r) async {
      requests++;
      expect(r.method, 'DELETE');
      expect(r.uri.path, '/v1/jobs/${task.id}');
      expect(r.headers.value('authorization'), 'Bearer remote-secret');
      r.response.headers.contentType = ContentType.json;
      r.response.write('{"status":"cancelled"}');
      await r.response.close();
    });
    await services.runner.cancel(task.id);
    expect(
      (await services.repository.getTask(task.id)).status,
      TaskStatus.cancelled,
    );
    expect(requests, 1);
    final provider = await services.provider(config);
    addTearDown(provider.close);
    await expectLater(
      provider.generate(ProviderRequest(executionId: task.id)).toList(),
      throwsA(isA<ProviderException>()),
    );
    expect(
      requests,
      1,
      reason: 'image-only profiles must not submit text jobs',
    );
  });

  test(
    'one connection retains multiple models and selects a model per role',
    () async {
      await services.saveConnection(
        connection('shared', {
          'models': ['first', 'second'],
          'kind': 'text',
        }),
        apiKey: 'one-shared-key',
      );
      await services.repository.setSetting('modelRoles', {
        'writing': 'shared',
        'writingModel': 'second',
        'editor': 'shared',
        'editorModel': 'first',
      });
      expect((await services.connections()).single.raw['models'], [
        'first',
        'second',
      ]);
      expect((await services.connectionFor('writing'))!.model, 'second');
      expect((await services.connectionFor('editor'))!.model, 'first');
      expect(await services.secrets.read('model/shared'), 'one-shared-key');
      expect(await services.connectionFor('image'), isNull);
    },
  );

  test('image connections never become writing or editor fallbacks', () async {
    await services.saveConnection(connection('image', {'kind': 'image'}));
    expect(await services.connectionFor('writing'), isNull);
    expect(await services.connectionFor('analysis'), isNull);
    expect(await services.connectionFor('editor'), isNull);
    expect((await services.connectionFor('image'))!.id, 'image');
  });

  test(
    'legacy role preferences and removed model choices fall back safely',
    () async {
      await services.saveConnection(connection('legacy', {}));
      await services.repository.setSetting('modelRoles', {'writing': 'legacy'});
      expect((await services.connectionFor('writing'))!.model, 'first');
      expect((await services.connectionFor('image'))!.id, 'legacy');
      await services.repository.setSetting('modelRoles', {
        'writing': 'legacy',
        'writingModel': 'removed',
      });
      expect((await services.connectionFor('writing'))!.model, 'first');
    },
  );

  test(
    'invalid saved model lists are rejected instead of silently truncated',
    () {
      expect(
        () => connection('bad', {
          'models': ['first', ''],
        }),
        throwsFormatException,
      );
      expect(
        () => connection('bad', {
          'models': ['second'],
        }),
        throwsFormatException,
      );
    },
  );
}
