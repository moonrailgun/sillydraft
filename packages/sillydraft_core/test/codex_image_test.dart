@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';

Map<String, dynamic> _image({
  String result = _png,
  String status = 'completed',
}) => {
  'method': 'item/completed',
  'params': {
    'item': {
      'type': 'imageGeneration',
      'status': status,
      'result': result,
      'revisedPrompt': '雾中的灯塔',
    },
  },
};

Map<String, dynamic> _done([String status = 'completed']) => {
  'method': 'turn/completed',
  'params': {
    'turn': {
      'status': status,
      'error': {'message': 'quota exceeded'},
    },
  },
};

Future<File> _server(Directory dir, List<Object> events) async {
  String emit(Object value) =>
      "printf '%s\\n' '${jsonEncode(value).replaceAll("'", "'\\''")}'";
  final script = File('${dir.path}/codex');
  await script.writeAsString('''#!/bin/sh
printf '%s\\n' "\$@" > '${dir.path}/args'
while IFS= read -r line; do
  printf '%s\\n' "\$line" >> '${dir.path}/input'
  case "\$line" in
    *'"method":"initialize"'*) ${emit({'id': 1, 'result': <String, dynamic>{}})} ;;
    *'"method":"config/read"'*) ${emit({
    'id': 2,
    'result': {
      'config': {
        'mcp_servers': {
          'personal': {'command': 'must-not-run'},
        },
      },
    },
  })} ;;
    *'"method":"thread/start"'*) ${emit({
    'id': 3,
    'result': {
      'thread': {'id': 'thread-1'},
    },
  })} ;;
    *'"method":"turn/start"'*)
      ${emit({
    'id': 4,
    'result': {
      'turn': {'id': 'turn-1'},
    },
  })}
      ${events.map((e) => e is Duration ? 'exec sleep ${e.inSeconds}' : emit(e)).join('\n      ')}
      exit 0 ;;
  esac
done
''');
  await Process.run('chmod', ['+x', script.path]);
  return script;
}

CodexImageProvider _provider(File command, {String model = 'default'}) =>
    CodexImageProvider(
      config: ModelConnection(
        id: 'codex',
        name: 'Codex',
        baseUrl: '',
        model: model,
        protocol: ModelProtocol.codexCli,
        command: command.path,
      ),
    );

void main() {
  late Directory dir;
  setUp(
    () async => dir = await Directory.systemTemp.createTemp('codex-image-'),
  );
  tearDown(() => dir.delete(recursive: true));

  test(
    'subscription images carry references and isolate the image turn',
    () async {
      final provider = _provider(
        await _server(dir, [
          _image(),
          {
            'method': 'thread/tokenUsage/updated',
            'params': {
              'tokenUsage': {
                'last': {'inputTokens': 10, 'outputTokens': 20},
              },
            },
          },
          _done(),
        ]),
        model: 'gpt-5.4',
      );
      addTearDown(provider.close);
      final result = await provider.generate(
        ImageRequest(
          prompt: '画灯塔',
          parameters: {
            'size': '1024x1536',
            'quality': 'high',
            'negative_prompt': '文字',
          },
        ),
        references: [
          ImageReference(bytes: base64Decode(_png), mimeType: 'image/png'),
        ],
      );
      expect(result.bytes, base64Decode(_png));
      expect(result.revisedPrompt, '雾中的灯塔');
      expect(result.usage, {'input_tokens': 10, 'output_tokens': 20});
      final lines = (await File(
        '${dir.path}/input',
      ).readAsLines()).map((s) => jsonDecode(s) as Map).toList();
      final thread =
          lines.singleWhere((m) => m['method'] == 'thread/start')['params']
              as Map;
      expect(thread['ephemeral'], isTrue);
      expect(thread['sandbox'], 'read-only');
      expect(thread['approvalPolicy'], 'never');
      expect(thread['model'], 'gpt-5.4');
      expect(thread['modelProvider'], 'openai');
      expect(thread['config']['mcp_servers']['personal']['enabled'], isFalse);
      expect(await Directory(thread['cwd'] as String).exists(), isFalse);
      final input =
          lines.singleWhere(
                (m) => m['method'] == 'turn/start',
              )['params']['input']
              as List;
      expect(input.first['text'], contains('1024x1536'));
      expect(input.first['text'], contains('文字'));
      expect(input.last, {
        'type': 'image',
        'url': 'data:image/png;base64,$_png',
      });
      final args = await File('${dir.path}/args').readAsLines();
      expect(args.take(2), ['app-server', '--stdio']);
      expect(args, contains('features.shell_tool=false'));
      expect(args, contains('features.image_generation=true'));
      expect(args.join(), isNot(contains('画灯塔')));
    },
  );

  test(
    'default uses Codex model selection and upgrades old text-only settings',
    () async {
      final provider = _provider(await _server(dir, [_image(), _done()]));
      addTearDown(provider.close);
      await provider.generate(ImageRequest(prompt: '灯塔'));
      final input = (await File(
        '${dir.path}/input',
      ).readAsLines()).map(jsonDecode);
      final thread = input.singleWhere((m) => m['method'] == 'thread/start');
      expect((thread['params'] as Map).containsKey('model'), isFalse);
      final old = ModelConnection.fromJson({
        ...provider.config.raw,
        'kind': 'text',
      });
      expect(old.supportsText, isTrue);
      expect(old.supportsImages, isTrue);
    },
  );

  for (final (name, events) in <(String, List<Object>)>[
    ('no image', [_done()]),
    ('failed image', [_image(status: 'failed'), _done()]),
    ('invalid base64', [_image(result: '%%%'), _done()]),
    ('empty image', [_image(result: ''), _done()]),
    ('failed turn after image', [_image(), _done('failed')]),
    (
      'RPC error',
      [
        {
          'id': 4,
          'error': {'message': 'unsupported image tool'},
        },
      ],
    ),
    ('early exit', []),
    ('multiple images', [_image(), _image(), _done()]),
  ]) {
    test('reports $name instead of a successful generation', () async {
      final provider = _provider(await _server(dir, events));
      addTearDown(provider.close);
      await expectLater(
        provider.generate(ImageRequest(prompt: '灯塔')),
        throwsA(isA<ProviderException>()),
      );
    });
  }

  test(
    'rejects unsupported parameters and reference types before invoking Codex',
    () async {
      final provider = _provider(File('${dir.path}/missing'));
      addTearDown(provider.close);
      await expectLater(
        provider.generate(ImageRequest(prompt: '灯塔', parameters: {'seed': 42})),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.code,
            'code',
            'image_parameter',
          ),
        ),
      );
      await expectLater(
        provider.generate(
          ImageRequest(prompt: '灯塔'),
          references: [
            ImageReference(bytes: base64Decode(_png), mimeType: 'text/plain'),
          ],
        ),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.code,
            'code',
            'image_reference',
          ),
        ),
      );
    },
  );

  test('cancel and close stop waiting for the CLI', () async {
    for (final close in [false, true]) {
      final provider = _provider(
        await _server(dir, [const Duration(seconds: 30)]),
      );
      final cancel = GenerationCancellation();
      final result = provider.generate(
        ImageRequest(prompt: '灯塔'),
        cancellation: cancel,
      );
      final check = expectLater(result, throwsA(isA<GenerationCancelled>()));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (close) {
        provider.close();
      } else {
        cancel.cancel();
      }
      await check.timeout(const Duration(seconds: 3));
      provider.close();
    }
  });
}
