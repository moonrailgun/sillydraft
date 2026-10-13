import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sillydraft_server/runner_server.dart';
import 'package:test/test.dart';

const token = 'local-test-token-never-a-provider-key';

class ScriptModel implements ModelProvider {
  ScriptModel(this.config, this.script);
  @override
  final ModelConnection config;
  final Stream<ProviderEvent> Function(GenerationCancellation) script;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) => script(cancellation ?? GenerationCancellation());
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  void close() {}
}

class ScriptImage implements ImageProvider {
  ScriptImage(this.config, this.script);
  @override
  final ModelConnection config;
  final Future<GeneratedImage> Function(ImageRequest, List<ImageReference>)
  script;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) => script(request, references);
  @override
  void close() {}
}

Future<void> until(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Condition did not become true');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> gateOrCancel(
  Completer<void> gate,
  GenerationCancellation cancel,
) async {
  final stopped = Completer<void>();
  final remove = cancel.onCancel(() {
    if (!stopped.isCompleted) stopped.complete();
  });
  try {
    await Future.any([gate.future, stopped.future]);
    cancel.check();
  } finally {
    remove();
  }
}

void main() {
  late Directory directory;
  late RunnerServer server;
  late Stream<ProviderEvent> Function(GenerationCancellation) script;
  late ModelConnection profile;
  var calls = 0;
  Future<RunnerServer> open() => RunnerServer.open(
    directory: directory,
    token: token,
    profiles: {'writer': profile},
    providerFactory: (config) async {
      return ScriptModel(config, (cancel) {
        calls++;
        return script(cancel);
      });
    },
    imageProviderFactory: (config) async =>
        ScriptImage(config, (request, refs) async {
          expect(request.prompt, '画一封信');
          expect(refs.single.bytes, [1, 2, 3]);
          return GeneratedImage(
            bytes: Uint8List.fromList([4, 5, 6]),
            revisedPrompt: '远程测试图片',
          );
        }),
  );
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'sillydraft-runner-test-',
    );
    calls = 0;
    profile = ModelConnection(
      id: 'writer',
      name: '服务端测试模型',
      baseUrl: 'http://localhost:1/v1',
      model: 'test',
      maxOutputTokens: 4096,
    );
    script = (_) async* {
      yield const TextDelta('新的远程正文');
      yield const GenerationFinished('stop');
    };
    server = await open();
  });
  tearDown(() async {
    await server.close();
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> submission(String id, {String text = '写一段故事'}) => {
    'id': id,
    'profile': 'writer',
    'kind': 'text',
    'request': ProviderRequest(
      messages: [
        {'role': 'user', 'content': text},
      ],
    ).raw,
  };
  Future<({int status, Map<String, dynamic> data})> http(
    String method,
    String path, {
    Object? body,
    String? auth = token,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, server.uri.resolve(path));
      if (auth != null) request.headers.set('Authorization', 'Bearer $auth');
      request.headers.contentType = ContentType.json;
      if (body != null) request.write(jsonEncode(body));
      final response = await request.close();
      final json = jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>;
      return (status: response.statusCode, data: json);
    } finally {
      client.close(force: true);
    }
  }

  ModelConnection connection() => ModelConnection(
    id: 'remote',
    name: '远程执行',
    baseUrl: server.uri.toString(),
    model: 'writer',
    protocol: ModelProtocol.sillyDraftRunner,
  );

  test(
    'HTTP auth, immutable idempotency, progress and acknowledged cancellation',
    () async {
      expect((await http('GET', 'v1/models', auth: null)).status, 401);
      expect((await http('GET', 'v1/models', auth: 'wrong')).status, 401);
      final models = await http('GET', 'v1/models');
      expect(models.status, 200);
      expect(jsonEncode(models.data), isNot(contains(profile.baseUrl)));
      final gate = Completer<void>();
      script = (cancel) async* {
        yield const TextDelta('雨落');
        await gateOrCancel(gate, cancel);
        yield const TextDelta('在港口');
        yield const GenerationFinished('stop');
      };
      final payload = submission('stable-request');
      expect((await http('POST', 'v1/jobs', body: payload)).status, 202);
      await until(
        () async =>
            (await http('GET', 'v1/jobs/stable-request')).data['text'] == '雨落',
      );
      expect((await http('POST', 'v1/jobs', body: payload)).status, 200);
      expect(
        (await http(
          'POST',
          'v1/jobs',
          body: submission('stable-request', text: 'different'),
        )).status,
        409,
      );
      expect(calls, 1);
      expect(
        (await http(
          'POST',
          'v1/jobs',
          body: {...submission('bad-profile'), 'profile': 'unknown'},
        )).status,
        400,
      );
      expect(
        (await http('DELETE', 'v1/jobs/stable-request')).data['status'],
        'cancelled',
      );
      gate.complete();
      expect((await http('GET', 'v1/jobs/stable-request')).data['text'], '雨落');
      expect(
        (await http('POST', 'v1/jobs', body: payload)).data['status'],
        'cancelled',
      );
      expect(calls, 1);
    },
  );

  test(
    'server restart preserves partial output and never retries model billing',
    () async {
      final gate = Completer<void>();
      script = (cancel) async* {
        yield const TextDelta('保存的前半段');
        await gateOrCancel(gate, cancel);
        yield const GenerationFinished('stop');
      };
      final payload = submission('restart-request');
      await http('POST', 'v1/jobs', body: payload);
      await until(
        () async =>
            (await http('GET', 'v1/jobs/restart-request')).data['text'] ==
            '保存的前半段',
      );
      await server.close();
      server = await open();
      final recovered = await http('GET', 'v1/jobs/restart-request');
      expect(recovered.data['status'], 'interrupted');
      expect(recovered.data['text'], '保存的前半段');
      expect(
        (await http('POST', 'v1/jobs', body: payload)).data['status'],
        'interrupted',
      );
      expect(calls, 1);
      script = (_) async* {
        yield const TextDelta('明确的新请求');
        yield const GenerationFinished('stop');
      };
      await http('POST', 'v1/jobs', body: submission('explicit-new-request'));
      await until(
        () async =>
            (await http(
              'GET',
              'v1/jobs/explicit-new-request',
            )).data['status'] ==
            'completed',
      );
      expect(calls, 2);
    },
  );

  test('device disconnect preserves remote job and reconnect binds result to original revision', () async {
    final gate = Completer<void>();
    script = (cancel) async* {
      yield const TextDelta('候选');
      await gateOrCancel(gate, cancel);
      yield const TextDelta('完整正文');
      yield const GenerationFinished('stop');
    };
    final localPath = '${directory.path}/device.sqlite';
    var repository = StoryRepository.open(localPath);
    TaskRunner runnerFor(StoryRepository repo) => TaskRunner(
      repository: repo,
      providerFactory: (config) async => RemoteModelProvider(
        config: config,
        accessToken: token,
        pollInterval: const Duration(milliseconds: 10),
      ),
    );
    var runner = runnerFor(repository);
    final novel = await repository.createNovel(title: '断线重连测试');

    final chapter = await repository.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('原稿'),
    );
    final task = await WritingService(repository: repository, runner: runner)
        .generate(
          branchId: chapter.branchId,
          chapterId: chapter.id,
          connection: connection(),
          brief: '继续故事',
        );
    await until(
      () async => (await repository.getTask(task.id)).partialText == '候选',
    );
    await runner.close();
    expect((await repository.getTask(task.id)).status, TaskStatus.interrupted);
    expect((await http('GET', 'v1/jobs/${task.id}')).data['status'], 'running');
    await repository.close();
    repository = StoryRepository.open(localPath);
    runner = runnerFor(repository);
    addTearDown(() async {
      await runner.close();
      await repository.close();
    });
    final changed = await repository.saveChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('离线时作者补写'),
    );
    gate.complete();
    await until(
      () async =>
          (await http('GET', 'v1/jobs/${task.id}')).data['status'] ==
          'completed',
    );
    await runner.reconnectRemote(task.id);
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed);
    expect(calls, 1);
    final proposal = await repository.getProposal(
      done.result['proposalId'] as String,
    );
    expect(proposal.baseRevisionId, chapter.revisionId);
    expect(proposal.content.text, contains('候选完整正文'));
    await expectLater(
      repository.acceptProposal(proposal.id),
      throwsA(isA<RevisionConflict>()),
    );
    expect(
      (await repository.getChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      )).revisionId,
      changed.revisionId,
    );
    expect((await repository.listProposals(chapter.branchId)).length, 1);
  });

  test('detached remote cancellation requires acknowledgement before recording cancelled locally', () async {
    final gate = Completer<void>();
    script = (cancel) async* {
      yield const TextDelta('等待取消');
      await gateOrCancel(gate, cancel);
      yield const GenerationFinished('stop');
    };
    final repository = StoryRepository.memory();
    addTearDown(repository.close);
    TaskRunner runnerFor(String auth) => TaskRunner(
      repository: repository,
      providerFactory: (config) async => RemoteModelProvider(
        config: config,
        accessToken: auth,
        pollInterval: const Duration(milliseconds: 10),
      ),
    );
    final runner = runnerFor(token);
    final novel = await repository.createNovel(title: '取消托管任务');

    final chapter = await repository.createChapter(
      branchId: novel.activeBranchId,
    );
    final task = await WritingService(repository: repository, runner: runner)
        .generate(
          branchId: chapter.branchId,
          chapterId: chapter.id,
          connection: connection(),
          brief: '继续',
        );
    await until(
      () async => (await repository.getTask(task.id)).partialText == '等待取消',
    );
    await runner.close();
    final unauthenticated = runnerFor('wrong-token');
    addTearDown(unauthenticated.close);
    await expectLater(
      unauthenticated.cancel(task.id),
      throwsA(isA<ProviderException>()),
    );
    expect((await repository.getTask(task.id)).status, TaskStatus.interrupted);
    final control = runnerFor(token);
    addTearDown(control.close);
    await control.cancel(task.id);
    expect((await repository.getTask(task.id)).status, TaskStatus.cancelled);
    expect(
      (await http('GET', 'v1/jobs/${task.id}')).data['status'],
      'cancelled',
    );
    expect(await repository.listProposals(chapter.branchId), isEmpty);
    expect(calls, 1);
  });

  test('server rejects client endpoints, tools, output excess and unapproved image downloads', () async {
    expect(
      (await http(
        'POST',
        'v1/jobs',
        body: {
          ...submission('bad-endpoint'),
          'baseUrl': 'http://169.254.169.254',
        },
      )).status,
      400,
    );
    expect(
      (await http(
        'POST',
        'v1/jobs',
        body: {
          ...submission('too-many-tokens'),
          'request': ProviderRequest(
            messages: [
              {'role': 'user', 'content': 'hello'},
            ],
            parameters: {'max_tokens': 1000000},
          ).raw,
        },
      )).status,
      400,
    );
    expect(
      (await http(
        'POST',
        'v1/jobs',
        body: {
          ...submission('tools-not-local'),
          'request': ProviderRequest(
            messages: [
              {'role': 'user', 'content': 'hello'},
            ],
            tools: [
              {
                'type': 'function',
                'function': {'name': 'write_file'},
              },
            ],
          ).raw,
        },
      )).status,
      400,
    );
    expect(
      (await http(
        'POST',
        'v1/jobs',
        body: {
          'id': 'unsafe-download',
          'profile': 'writer',
          'kind': 'image',
          'request': ImageRequest(
            prompt: '画一封信',
            allowedDownloadHosts: ['169.254.169.254'],
          ).raw,
        },
      )).status,
      400,
    );
    expect(calls, 0);
  });

  test(
    'retrieving a missing remote task never creates a new upstream request',
    () async {
      final provider = RemoteModelProvider(
        config: connection(),
        accessToken: token,
      );
      addTearDown(provider.close);
      await expectLater(
        provider
            .generate(
              ProviderRequest(
                messages: [
                  {'role': 'user', 'content': '不可重复生成'},
                ],
                executionId: 'missing-job',
                retrieveOnly: true,
              ),
            )
            .toList(),
        throwsA(
          isA<ProviderException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
      expect(calls, 0);
    },
  );

  test('remote image recovery saves one asset against its original chapter revision', () async {
    await server.close();
    final bytes = await File('../test/fixtures/tiny-illustration.png')
        .readAsBytes();
    var imageCalls = 0;
    server = await RunnerServer.open(
      directory: directory,
      token: token,
      profiles: {'writer': profile},
      providerFactory: (c) async => ScriptModel(c, script),
      imageProviderFactory: (c) async => ScriptImage(c, (request, refs) async {
        imageCalls++;
        return GeneratedImage(bytes: bytes, revisedPrompt: '测试插画');
      }),
    );
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final assets = AssetLibrary(
      repository: repo,
      directory: Directory('${directory.path}/assets'),
    );
    final novel = await repo.createNovel(title: '远程插画恢复');

    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('下雨的夜晚'),
    );
    final config = connection();
    final imageRequest = ImageRequest(prompt: '雨夜');
    final task = await repo.createTask(
      branchId: chapter.branchId,
      kind: TaskKind.illustration,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      input: {
        'connection': config.raw,
        'imageRequest': imageRequest.raw,
        'name': '雨夜',
        'purpose': 'illustration',
        'references': [],
      },
    );
    final transport = RemoteImageProvider(
      config: config,
      accessToken: token,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(transport.close);
    await transport.generate(ImageRequest(prompt: '雨夜', executionId: task.id));
    await repo.recoverInterruptedTasks();
    final edited = await repo.saveChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('作者改成晴天'),
    );
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async =>
          RemoteModelProvider(config: c, accessToken: token),
      imageProviderFactory: (c) async => RemoteImageProvider(
        config: c,
        accessToken: token,
        pollInterval: const Duration(milliseconds: 10),
      ),
      assetLibrary: assets,
    );
    addTearDown(runner.close);
    await runner.reconnectRemote(task.id);
    final done = await runner.wait(task.id);
    expect(done.status, TaskStatus.completed);
    final asset = await repo.getAsset(done.result['assetId'] as String);
    expect(asset.sourceRevisionId, chapter.revisionId);
    expect(await repo.assetSourceCurrent(asset.id), isFalse);
    expect(await assets.read(asset.id), isNotEmpty);
    expect((await repo.listAssets(novel.id)).length, 1);
    expect(
      (await repo.getChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      )).revisionId,
      edited.revisionId,
    );
    expect(imageCalls, 1);
  });

  test('remote image returns authenticated binary output and retains its stable request identity', () async {
    final provider = RemoteImageProvider(
      config: connection(),
      accessToken: token,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(provider.close);
    final result = await provider.generate(
      ImageRequest(prompt: '画一封信', executionId: 'image-request'),
      references: [
        ImageReference(
          bytes: Uint8List.fromList([1, 2, 3]),
          mimeType: 'image/png',
        ),
      ],
    );
    expect(result.bytes, [4, 5, 6]);
    expect(result.revisedPrompt, '远程测试图片');
    expect(
      (await http('GET', 'v1/jobs/image-request')).data['status'],
      'completed',
    );
    final unauthenticated = await http(
      'GET',
      'v1/jobs/image-request/image',
      auth: null,
    );
    expect(unauthenticated.status, 401);
  });
}
