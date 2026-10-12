import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

void main() {
  test(
    'image generation and reference editing use distinct real HTTP contracts',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      server.listen((r) async {
        calls++;
        expect(r.headers.value('authorization'), 'Bearer image-test-key');
        if (calls == 1) {
          expect(r.uri.path, '/v1/images/generations');
          final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
          expect(body['prompt'], '雨中的渡口');
          expect(body['n'], 1);
          expect(body.containsKey('response_format'), false);
        } else {
          expect(r.uri.path, '/v1/images/edits');
          expect(r.headers.contentType?.mimeType, 'multipart/form-data');
          final body = latin1.decode(
            await r.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
          expect(body, contains('name="image[]"'));
          expect(body, contains('filename="reference-0.png"'));
        }
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'data': [
              {
                'b64_json': base64Encode(testPicture()),
                'revised_prompt': 'refined',
              },
            ],
            'usage': {'total_tokens': 25},
          }),
        );
        await r.response.close();
      });
      final provider = OpenAIImageProvider(
        config: ModelConnection(
          id: 'image',
          name: 'image',
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'configured-image-model',
        ),
        apiKey: 'image-test-key',
      );
      addTearDown(provider.close);
      final first = await provider.generate(ImageRequest(prompt: '雨中的渡口'));
      expect(first.bytes, testPicture());
      expect(first.revisedPrompt, 'refined');
      final edited = await provider.generate(
        ImageRequest(prompt: '移除雨水'),
        references: [
          ImageReference(bytes: testPicture(), mimeType: 'image/png'),
        ],
      );
      expect(edited.bytes, isNotEmpty);
      expect(calls, 2);
    },
  );
  test(
    'untrusted download origins cannot receive credentials or trigger requests',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        await r.drain<void>();
        r.response.headers.contentType = ContentType.json;
        r.response.write(
          jsonEncode({
            'data': [
              {'url': 'http://127.0.0.1:1/private'},
            ],
          }),
        );
        await r.response.close();
      });
      final provider = OpenAIImageProvider(
        config: ModelConnection(
          id: 'x',
          name: 'x',
          baseUrl: 'http://127.0.0.1:${server.port}',
          model: 'x',
        ),
        apiKey: 'private-key',
      );
      addTearDown(provider.close);
      await expectLater(
        provider.generate(ImageRequest(prompt: '一个港口')),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.code,
            'code',
            'image_download_origin',
          ),
        ),
      );
    },
  );
  test('same-origin image downloads omit authorization and cancellation aborts a pending response', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    var hold = false;
    server.listen((r) async {
      if (r.uri.path == '/image.png') {
        expect(r.headers.value('authorization'), isNull);
        r.response.add(testPicture());
        await r.response.close();
        return;
      }
      await r.drain<void>();
      if (hold) return;
      r.response.headers.contentType = ContentType.json;
      r.response.write(
        jsonEncode({
          'data': [
            {'url': '$origin/image.png'},
          ],
        }),
      );
      await r.response.close();
    });
    final provider = OpenAIImageProvider(
      config: ModelConnection(id: 'x', name: 'x', baseUrl: origin, model: 'x'),
      apiKey: 'secret',
    );
    addTearDown(provider.close);
    expect(
      (await provider.generate(ImageRequest(prompt: '港口'))).bytes,
      testPicture(),
    );
    hold = true;
    final cancel = GenerationCancellation();
    final response = provider.generate(
      ImageRequest(prompt: '取消'),
      cancellation: cancel,
    );
    final expectation = expectLater(
      response,
      throwsA(isA<GenerationCancelled>()),
    );
    cancel.cancel();
    await expectation;
  });
}
