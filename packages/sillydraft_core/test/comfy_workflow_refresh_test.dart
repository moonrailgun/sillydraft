import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('new tasks freeze the latest named file while retries keep the snapshot', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final dir = await Directory.systemTemp.createTemp('comfy-refresh-');
    addTearDown(() => dir.delete(recursive: true));
    final novel = await repo.createNovel(title: 'test');
    Map<String, dynamic> graph(int steps) => {
      '1': {
        'class_type': 'CLIPTextEncode',
        'inputs': {'text': 'saved'},
      },
      '2': {
        'class_type': 'KSampler',
        'inputs': {'steps': steps},
      },
      '3': {
        'class_type': 'SaveImage',
        'inputs': {
          'images': ['2', 0],
        },
      },
    };
    var steps = 12, reads = 0;
    var missingBinding = false;
    final submitted = <int>[];
    server.listen((request) async {
      if (request.method == 'GET') {
        expect(request.uri.pathSegments.last, 'workflows/绘图.json');
        expect(request.headers.value('authorization'), 'Bearer private-token');
        reads++;
        final nodes = graph(steps);
        if (missingBinding) nodes.remove('1');
        request.response.write(jsonEncode(nodes));
      } else {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        submitted.add(body['prompt']['2']['inputs']['steps'] as int);
        request.response.statusCode = 400;
        request.response.write('{"error":"intentional test rejection"}');
      }
      await request.response.close();
    });
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (_) async => throw StateError('text not expected'),
      imageProviderFactory: (c) async =>
          ComfyUIProvider(config: c, apiKey: 'private-token'),
      assetLibrary: AssetLibrary(repository: repo, directory: dir),
    );
    addTearDown(runner.close);
    final service = IllustrationService(repository: repo, runner: runner);
    final connection = ModelConnection(
      id: 'comfy',
      name: 'comfy',
      baseUrl: 'http://127.0.0.1:${server.port}',
      protocol: ModelProtocol.comfyUI,
      model: 'workflow',
      comfyWorkflow: ComfyWorkflow(
        nodes: graph(4),
        promptInput: '1.text',
        outputNode: '3',
        filename: '绘图.json',
      ),
    );
    Future<GenerationTask> generate() => service.generate(
      branchId: novel.activeBranchId,
      connection: connection,
      name: 'test',
      request: ImageRequest(prompt: 'a harbour'),
    );
    final first = await generate();
    await runner.wait(first.id);
    expect(reads, 1);
    expect(submitted, [12]);
    expect(
      first
          .input['connection']['comfyWorkflow']['nodes']['2']['inputs']['steps'],
      12,
    );
    expect(connection.comfyWorkflow!.nodes['2']['inputs']['steps'], 4);
    steps = 20;
    final retry = await runner.resume(first.id);
    await runner.wait(retry.id);
    expect(reads, 1);
    expect(submitted, [12, 12]);
    final next = await generate();
    await runner.wait(next.id);
    expect(submitted, [12, 12, 20]);
    missingBinding = true;
    await expectLater(generate(), throwsA(isA<FormatException>()));
    expect(
      (await repo.listTasks(branchId: novel.activeBranchId)),
      hasLength(3),
    );
  });
}
