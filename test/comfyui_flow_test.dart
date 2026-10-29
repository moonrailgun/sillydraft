import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

const workflow = {
  'nodes': {
    '4': {
      'class_type': 'CheckpointLoaderSimple',
      'inputs': {'ckpt_name': 'old.safetensors'},
    },
    '6': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'old positive'},
    },
    '7': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'keep negative'},
    },
    '3': {
      'class_type': 'KSampler',
      'inputs': {
        'seed': 12,
        'positive': ['6', 0],
      },
    },
    '9': {
      'class_type': 'SaveImage',
      'inputs': {
        'images': ['3', 0],
      },
    },
  },
  'promptInput': '6.text',
  'modelInput': '4.ckpt_name',
  'outputNode': '9',
};

void main() {
  late HttpServer server;
  late AppServices services;
  late Future<void> Function(HttpRequest) handler;
  late ModelConnection config;
  late Directory directory;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    directory = await Directory.systemTemp.createTemp('sillydraft-comfy-test-');
    services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: directory,
    );
    handler = (r) async {
      r.response.statusCode = 500;
      await r.response.close();
    };
    server.listen((r) => handler(r));
    config = ModelConnection.fromJson({
      'id': 'comfy',
      'name': 'ComfyUI',
      'protocol': 'comfyUI',
      'baseUrl': 'http://127.0.0.1:${server.port}/comfy',
      'model': 'new.safetensors',
      'models': ['old.safetensors', 'new.safetensors'],
      'comfyWorkflow': workflow,
    });
  });
  tearDown(() async {
    await services.close();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('ComfyUI submits the selected workflow once and downloads its chosen output', () async {
    var submitted = 0;
    final paths = <String>[];
    await services.saveConnection(config, apiKey: 'local-proxy-key');
    expect(await services.connectionFor('writing'), isNull);
    expect(await services.connectionFor('editor'), isNull);
    handler = (r) async {
      paths.add(r.uri.path);
      expect(r.headers.value('authorization'), 'Bearer local-proxy-key');
      r.response.headers.contentType = ContentType.json;
      switch (r.uri.path) {
        case '/comfy/prompt':
          submitted++;
          final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
          expect(body['prompt']['6']['inputs']['text'], '雨中的渡口');
          expect(body['prompt']['7']['inputs']['text'], 'keep negative');
          expect(body['prompt']['4']['inputs']['ckpt_name'], 'new.safetensors');
          expect(body['prompt']['3']['inputs']['seed'], 123);
          r.response.write(
            jsonEncode({
              'prompt_id': 'job-1',
              'number': 0,
              'node_errors': {
                'unused': {
                  'errors': [],
                  'dependent_outputs': ['other-output'],
                },
              },
            }),
          );
        case '/comfy/history/job-1':
          r.response.write(
            jsonEncode({
              'job-1': {
                'status': {
                  'status_str': 'success',
                  'completed': true,
                  'messages': [],
                },
                'outputs': {
                  'preview': {
                    'images': [
                      {
                        'filename': 'wrong.png',
                        'subfolder': '',
                        'type': 'temp',
                      },
                    ],
                  },
                  '9': {
                    'images': [
                      {
                        'filename': 'result.png',
                        'subfolder': 'drafts',
                        'type': 'output',
                      },
                    ],
                  },
                },
              },
            }),
          );
        case '/comfy/view':
          expect(r.uri.queryParameters, {
            'filename': 'result.png',
            'subfolder': 'drafts',
            'type': 'output',
          });
          r.response.add([137, 80, 78, 71]);
        default:
          fail('Unexpected request ${r.uri}');
      }
      await r.response.close();
    };
    final provider = await services.imageProvider(config);
    addTearDown(provider.close);
    final result = await provider.generate(
      ImageRequest(prompt: '雨中的渡口', parameters: {'seed': 123}),
    );
    expect(result.bytes, [137, 80, 78, 71]);
    expect(submitted, 1);
    expect(paths, ['/comfy/prompt', '/comfy/history/job-1', '/comfy/view']);
    expect(
      config.comfyWorkflow!.nodes,
      workflow['nodes'],
      reason: 'the saved workflow remains unchanged',
    );
  });

  test(
    'node execution failure surfaces without downloading or submitting again',
    () async {
      var submissions = 0;
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType.json;
        if (r.uri.path.endsWith('/prompt')) {
          submissions++;
          r.response.write('{"prompt_id":"failed","node_errors":{}}');
        } else {
          expect(r.uri.path, '/comfy/history/failed');
          r.response.write(
            jsonEncode({
              'failed': {
                'outputs': {},
                'status': {
                  'status_str': 'error',
                  'completed': false,
                  'messages': [
                    [
                      'execution_error',
                      {'node_id': '3'},
                    ],
                  ],
                },
              },
            }),
          );
        }
        await r.response.close();
      };
      final provider = await services.imageProvider(config);
      addTearDown(provider.close);
      await expectLater(
        provider.generate(ImageRequest(prompt: '港口')),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.code,
            'code',
            'comfy_execution',
          ),
        ),
      );
      expect(submissions, 1);
    },
  );

  test(
    'cancelling a queued job stops polling without interrupting other users',
    () async {
      final polling = Completer<void>();
      var submissions = 0;
      handler = (r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType.json;
        if (r.uri.path.endsWith('/prompt')) {
          submissions++;
          r.response.write('{"prompt_id":"queued","node_errors":{}}');
        } else {
          expect(r.uri.path, '/comfy/history/queued');
          if (!polling.isCompleted) polling.complete();
          r.response.write('{}');
        }
        await r.response.close();
      };
      final provider = await services.imageProvider(config);
      addTearDown(provider.close);
      final cancel = GenerationCancellation();
      final result = provider.generate(
        ImageRequest(prompt: '港口'),
        cancellation: cancel,
      );
      final assertion = expectLater(
        result,
        throwsA(isA<GenerationCancelled>()),
      );
      await polling.future;
      cancel.cancel();
      await assertion;
      expect(submissions, 1);
    },
  );

  test(
    'invalid workflow and unknown request parameters fail before network calls',
    () async {
      var calls = 0;
      handler = (r) async {
        calls++;
        await r.response.close();
      };
      expect(
        () => ModelConnection.fromJson({
          ...config.raw,
          'comfyWorkflow': {...workflow, 'promptInput': 'missing.text'},
        }),
        throwsFormatException,
      );
      final provider = await services.imageProvider(config);
      addTearDown(provider.close);
      await expectLater(
        provider.generate(
          ImageRequest(prompt: '港口', parameters: {'url': 'http://other'}),
        ),
        throwsA(isA<ProviderException>()),
      );
      await expectLater(
        provider.generate(ImageRequest(prompt: '港口', parameters: {'seed': -1})),
        throwsA(isA<ProviderException>()),
      );
      expect(calls, 0);
    },
  );

  test(
    'model discovery uses the bound loader rather than assuming checkpoints',
    () async {
      final custom = ModelConnection.fromJson({
        ...config.raw,
        'comfyWorkflow': {
          ...workflow,
          'nodes': <String, dynamic>{
            ...workflow['nodes'] as Map,
            '4': {
              'class_type': 'UNETLoader',
              'inputs': {'unet_name': 'flux.safetensors'},
            },
          },
          'modelInput': '4.unet_name',
        },
      });
      handler = (r) async {
        expect(r.uri.path, '/comfy/object_info/UNETLoader');
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'UNETLoader': {
              'input': {
                'required': {
                  'unet_name': [
                    ['flux-b.safetensors', 'flux-a.safetensors'],
                  ],
                },
              },
            },
          }),
        );
        await r.response.close();
      };
      final provider = ComfyUIProvider(config: custom);
      addTearDown(provider.close);
      expect(await provider.listModels(), [
        'flux-a.safetensors',
        'flux-b.safetensors',
      ]);
    },
  );

  test('reference upload is bound to the chosen image input and the result reaches the gallery', () async {
    final custom = ModelConnection.fromJson({
      ...config.raw,
      'comfyWorkflow': {
        ...workflow,
        'nodes': <String, dynamic>{
          ...workflow['nodes'] as Map,
          '10': {
            'class_type': 'LoadImage',
            'inputs': {'image': 'old.png'},
          },
        },
        'imageInput': '10.image',
      },
    });
    final picture = img.encodePng(
      img.Image(width: 16, height: 16)..setPixelRgba(0, 0, 30, 60, 90, 255),
    );
    final paths = <String>[];
    handler = (r) async {
      paths.add(r.uri.path);
      r.response.headers.contentType = ContentType.json;
      switch (r.uri.path) {
        case '/comfy/upload/image':
          expect(r.headers.contentType!.mimeType, 'multipart/form-data');
          final body = latin1.decode(
            await r.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
          expect(body, contains('name="image"; filename="sillydraft-'));
          r.response.write(
            '{"name":"reference.png","subfolder":"inputs","type":"input"}',
          );
        case '/comfy/prompt':
          final body = jsonDecode(await utf8.decoder.bind(r).join());
          expect(
            body['prompt']['10']['inputs']['image'],
            'inputs/reference.png',
          );
          expect(body['prompt']['6']['inputs']['text'], startsWith('参考港口'));
          expect(body['prompt']['6']['inputs']['text'], contains('石砌码头，红色灯塔'));
          r.response.write('{"prompt_id":"gallery","node_errors":{}}');
        case '/comfy/history/gallery':
          r.response.write(
            jsonEncode({
              'gallery': {
                'status': {
                  'status_str': 'success',
                  'completed': true,
                  'messages': [],
                },
                'outputs': {
                  '9': {
                    'images': [
                      {
                        'filename': 'result.png',
                        'subfolder': '',
                        'type': 'output',
                      },
                    ],
                  },
                },
              },
            }),
          );
        case '/comfy/view':
          r.response.add(picture);
        default:
          fail('Unexpected request ${r.uri}');
      }
      await r.response.close();
    };
    final novel = await services.repository.createNovel(title: 'ComfyUI 图库');
    final reference = await services.assets!.importImage(
      branchId: novel.activeBranchId,
      name: '参考',
      bytes: picture,
      purpose: AssetPurpose.reference,
    );
    await services.repository.setAssetReference(
      reference.id,
      kind: LoreKind.location,
      prompt: '石砌码头，红色灯塔',
    );
    final task = await services.illustrations.generate(
      branchId: novel.activeBranchId,
      connection: custom,
      name: '港口插画',
      request: ImageRequest(prompt: '参考港口'),
      referenceAssetIds: [reference.id],
    );
    final done = await services.runner.wait(task.id);
    expect(done.status, TaskStatus.completed, reason: done.error.toString());
    final asset = await services.repository.getAsset(
      done.result['assetId'] as String,
    );
    expect(asset.name, '港口插画');
    expect(asset.metadata['model'], 'new.safetensors');
    expect(asset.metadata['prompt'], startsWith('参考港口'));
    expect(asset.metadata['prompt'], contains('石砌码头，红色灯塔'));
    expect(await services.assets!.read(asset.id), isNotEmpty);
    expect(paths, [
      '/comfy/upload/image',
      '/comfy/prompt',
      '/comfy/history/gallery',
      '/comfy/view',
    ]);
  });

  test('a workflow without a model input sends no model', () {
    expect(config.sentModel, 'new.safetensors');
    final unbound = ModelConnection.fromJson({
      ...config.raw,
      'model': 'workflow',
      'models': ['workflow'],
      'comfyWorkflow': {...workflow}..remove('modelInput'),
    });
    expect(unbound.sentModel, isNull);
  });

  test('redirects cannot receive the ComfyUI credential', () async {
    final other = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => other.close(force: true));
    var leaked = false;
    other.listen((r) async {
      leaked = true;
      await r.response.close();
    });
    handler = (r) async {
      await r.drain<void>();
      r.response.statusCode = 302;
      r.response.headers.set(
        'location',
        'http://127.0.0.1:${other.port}/private',
      );
      await r.response.close();
    };
    await services.saveConnection(config, apiKey: 'private');
    final provider = await services.imageProvider(config);
    addTearDown(provider.close);
    await expectLater(
      provider.generate(ImageRequest(prompt: '港口')),
      throwsA(
        isA<ProviderException>().having((e) => e.statusCode, 'status', 302),
      ),
    );
    expect(leaked, isFalse);
  });

  test('canvas workflows, ambiguous bindings and embedded credentials are rejected', () {
    expect(
      () => ComfyWorkflow.parseNodes({'nodes': [], 'links': []}),
      throwsFormatException,
    );
    expect(
      () => ComfyWorkflow.fromJson({...workflow, 'modelInput': '6.text'}),
      throwsFormatException,
    );
    expect(
      () => ComfyWorkflow.parseNodes({
        '1': {
          'class_type': 'ApiNode',
          'inputs': {'api_key': 'private'},
        },
      }),
      throwsFormatException,
    );
  });
}
