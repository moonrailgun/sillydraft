import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late ComfyUIProvider provider;
  late Future<void> Function(HttpRequest) handler;
  const nodes = {
    '6': {
      'class_type': 'CLIPTextEncode',
      'inputs': {'text': 'a harbour'},
    },
    '9': {
      'class_type': 'SaveImage',
      'inputs': {
        'images': ['6', 0],
      },
    },
  };
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    handler = (request) async {
      request.response.statusCode = 404;
      await request.response.close();
    };
    server.listen((request) => handler(request));
    provider = ComfyUIProvider(
      config: ModelConnection(
        id: 'comfy',
        name: 'ComfyUI',
        protocol: ModelProtocol.comfyUI,
        baseUrl: 'http://127.0.0.1:${server.port}/proxy',
        model: 'workflow',
      ),
      apiKey: 'test-token',
    );
  });
  tearDown(() async {
    provider.close();
    await server.close(force: true);
  });

  test(
    'lists workflow filenames and reads an encoded nested filename',
    () async {
      final requests = <Uri>[];
      handler = (request) async {
        requests.add(request.uri);
        expect(request.method, 'GET');
        expect(request.headers.value('authorization'), 'Bearer test-token');
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/proxy/userdata') {
          expect(request.uri.queryParameters, {
            'dir': 'workflows',
            'recurse': 'true',
            'split': 'false',
          });
          request.response.write(
            jsonEncode([
              'z.json',
              '图像/Qwen #1%.json',
              'a.JSON',
              'z.json',
              'readme.txt',
              '../secret.json',
              '%2e%2e/secret.json',
              '/absolute.json',
              'bad\\file.json',
              './bad.json',
            ]),
          );
        } else {
          expect(request.uri.pathSegments.last, 'workflows/图像/Qwen #1%.json');
          expect(request.uri.queryParameters, isEmpty);
          request.response.write(jsonEncode(nodes));
        }
        await request.response.close();
      };
      expect(await provider.listWorkflows(), [
        'a.JSON',
        'z.json',
        '图像/Qwen #1%.json',
      ]);
      expect(await provider.readWorkflow('图像/Qwen #1%.json'), nodes);
      expect(requests, hasLength(2));
    },
  );

  test('rejects unsafe filenames before making a request', () async {
    var requested = false;
    handler = (request) async {
      requested = true;
      await request.response.close();
    };
    for (final name in [
      '',
      '../secret.json',
      'a/../b.json',
      '/a.json',
      'a//b.json',
      './a.json',
      'a\\b.json',
      '%2e%2e/secret.json',
      'a%2fb.json',
      '%252e%252e/secret.json',
      'a\u0000.json',
      'a.txt',
    ]) {
      await expectLater(
        provider.readWorkflow(name),
        throwsA(isA<FormatException>()),
      );
    }
    expect(requested, isFalse);
  });

  test('reads a saved canvas using server widget definitions', () async {
    handler = (request) async {
      request.response.write(
        jsonEncode(
          request.uri.path.endsWith('/object_info')
              ? {
                  'CLIPTextEncode': {
                    'python_module': 'nodes',
                    'input': {
                      'required': {
                        'text': ['STRING', <String, dynamic>{}],
                      },
                    },
                  },
                  'Method': {
                    'python_module': 'comfy_extras.nodes_flux',
                    'input': {
                      'required': {
                        'method': [
                          'COMBO',
                          {
                            'options': ['index', 'offset'],
                          },
                        ],
                      },
                    },
                  },
                }
              : {
                  'nodes': [
                    {
                      'id': 1,
                      'type': 'CLIPTextEncode',
                      'widgets_values_named': {'text': '最新提示词'},
                    },
                    {
                      'id': 2,
                      'type': 'Method',
                      'widgets_values': ['index'],
                    },
                  ],
                  'links': <Object>[],
                },
        ),
      );
      await request.response.close();
    };
    final result = await provider.readWorkflow('canvas.json');
    expect(result['1']['inputs']['text'], '最新提示词');
    expect(result['2']['inputs']['method'], 'index');
  });

  test(
    'reports invalid lists, canvas files, secrets and missing files',
    () async {
      Object response = {'unexpected': <Object>[]};
      var status = 200;
      handler = (request) async {
        request.response.statusCode = status;
        request.response.write(jsonEncode(response));
        await request.response.close();
      };
      await expectLater(
        provider.listWorkflows(),
        throwsA(isA<ProviderException>()),
      );
      response = {'nodes': <Object>[], 'links': <Object>[]};
      await expectLater(
        provider.readWorkflow('canvas.json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('画布'),
          ),
        ),
      );
      response = {
        '6': {
          'class_type': 'CustomNode',
          'inputs': {'api_key': 'private-key'},
        },
      };
      await expectLater(
        provider.readWorkflow('secret.json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('密钥'),
          ),
        ),
      );
      status = 404;
      await expectLater(
        provider.readWorkflow('missing.json'),
        throwsA(
          isA<ProviderException>().having((e) => e.statusCode, 'status', 404),
        ),
      );
    },
  );

  test('bounds remote workflow size before parsing', () async {
    handler = (request) async {
      request.response.write(' ' * (2 * 1024 * 1024 + 1));
      await request.response.close();
    };
    await expectLater(
      provider.readWorkflow('large.json'),
      throwsA(
        isA<ProviderException>().having((e) => e.code, 'code', 'comfy_size'),
      ),
    );
  });
}
