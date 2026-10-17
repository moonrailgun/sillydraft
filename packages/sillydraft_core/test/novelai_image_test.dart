import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;

List<int> imageZip({String name = 'image_0.png', List<int>? bytes}) =>
    ZipEncoder().encode(
      Archive()..add(ArchiveFile.bytes(name, bytes ?? testPicture())),
    );

void main() {
  late HttpServer server;
  late NovelAIImageProvider provider;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = NovelAIImageProvider(
      config: ModelConnection(
        id: 'nai',
        name: 'NovelAI',
        baseUrl: 'http://127.0.0.1:${server.port}/',
        model: 'nai-diffusion-4-5-full',
        protocol: ModelProtocol.novelAI,
      ),
      apiKey: 'private-token',
    );
  });
  tearDown(() async {
    provider.close();
    await server.close(force: true);
  });

  test(
    'native request carries V4 captions and decodes the ZIP image',
    () async {
      server.listen((r) async {
        expect(r.uri.path, '/ai/generate-image');
        expect(r.headers.value('authorization'), 'Bearer private-token');
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(body['input'], 'a quiet harbor');
        expect(body['model'], 'nai-diffusion-4-5-full');
        expect(body['action'], 'generate');
        final p = body['parameters'] as Map;
        expect(p['width'], 832);
        expect(p['height'], 1216);
        expect(p['steps'], 20);
        expect(p['scale'], 6.0);
        expect(p['seed'], 42);
        expect(p['n_samples'], 1);
        expect(p['params_version'], 3);
        expect(p['negative_prompt'], 'blurry');
        expect(p['v4_prompt']['caption']['base_caption'], 'a quiet harbor');
        expect(p['v4_negative_prompt']['caption']['base_caption'], 'blurry');
        expect(p.containsKey('size'), false);
        r.response.add(imageZip());
        await r.response.close();
      });
      final result = await provider.generate(
        ImageRequest(
          prompt: 'a quiet harbor',
          parameters: {
            'size': '832x1216',
            'steps': 20,
            'scale': 6.0,
            'seed': 42,
            'negative_prompt': 'blurry',
          },
        ),
      );
      expect(result.bytes, testPicture());
      expect(provider.config.supportsText, false);
      expect(
        ModelConnection.fromJson(provider.config.raw).supportsImages,
        true,
      );
    },
  );

  test('default parameters generate one image with a random seed', () async {
    server.listen((r) async {
      final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
      final p = body['parameters'] as Map;
      expect(p['width'], 1024);
      expect(p['height'], 1024);
      expect(p['steps'], 28);
      expect(p['seed'], inInclusiveRange(0, 0xffffffff));
      expect(p['sampler'], isNotEmpty);
      expect(p['n_samples'], 1);
      r.response.add(imageZip());
      await r.response.close();
    });
    expect(
      (await provider.generate(
        ImageRequest(
          prompt: 'harbor',
          parameters: {'seed': -1, 'size': 'auto'},
        ),
      )).bytes,
      testPicture(),
    );
  });

  test(
    'unsupported and invalid parameters fail before making a request',
    () async {
      var calls = 0;
      server.listen((r) async {
        calls++;
        await r.response.close();
      });
      for (final parameters in <Map<String, dynamic>>[
        {'n_samples': 2},
        {'model': 'another'},
        {'image': 'hidden-reference'},
        {'quality': 'high'},
        {'size': 'broken'},
        {'width': 1000},
        {'height': 0},
        {'steps': 0},
        {'steps': 2.5},
        {'scale': '5'},
        {'seed': -2},
        {'negative_prompt': 1},
        {'sampler': ''},
      ]) {
        await expectLater(
          provider.generate(
            ImageRequest(prompt: 'harbor', parameters: parameters),
          ),
          throwsA(
            isA<ProviderException>().having(
              (e) => e.code,
              'code',
              'novelai_parameter',
            ),
          ),
        );
      }
      expect(calls, 0);
    },
  );

  test(
    'reference images are rejected rather than silently discarded',
    () async {
      await expectLater(
        provider.generate(
          ImageRequest(prompt: 'harbor'),
          references: [
            ImageReference(bytes: testPicture(), mimeType: 'image/png'),
          ],
        ),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.code,
            'code',
            'novelai_reference',
          ),
        ),
      );
    },
  );

  for (final status in [401, 402, 429, 500, 302]) {
    test('HTTP $status does not retry or leak the upstream response', () async {
      var calls = 0;
      server.listen((r) async {
        calls++;
        await r.drain<void>();
        r.response.statusCode = status;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/redirect',
        );
        r.response.write('private-token');
        await r.response.close();
      });
      await expectLater(
        provider.generate(ImageRequest(prompt: 'harbor')),
        throwsA(
          isA<ProviderException>()
              .having((e) => e.statusCode, 'status', status)
              .having(
                (e) => e.toString(),
                'message',
                isNot(contains('private-token')),
              ),
        ),
      );
      expect(calls, 1);
    });
  }

  test('invalid archives, unsafe paths and non-images are rejected', () async {
    final replies = [
      utf8.encode('{"error":"not a ZIP"}'),
      imageZip(name: '../image.png'),
      imageZip(name: 'note.txt'),
      imageZip(bytes: [1, 2, 3]),
      ZipEncoder().encode(
        Archive()
          ..add(ArchiveFile.bytes('a.png', testPicture()))
          ..add(ArchiveFile.bytes('b.png', testPicture())),
      ),
      imageZip(bytes: Uint8List(32 * 1024 * 1024 + 1)),
    ];
    var calls = 0;
    server.listen((r) async {
      await r.drain<void>();
      r.response.add(replies[calls++]);
      await r.response.close();
    });
    for (var i = 0; i < replies.length; i++) {
      await expectLater(
        provider.generate(ImageRequest(prompt: 'harbor')),
        throwsA(
          isA<ProviderException>().having(
            (e) => e.code,
            'code',
            'novelai_result',
          ),
        ),
      );
    }
  });

  test('cancellation aborts a pending request without retrying', () async {
    final started = Completer<void>();
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      started.complete();
    });
    final cancel = GenerationCancellation();
    final result = provider.generate(
      ImageRequest(prompt: 'harbor'),
      cancellation: cancel,
    );
    final assertion = expectLater(result, throwsA(isA<GenerationCancelled>()));
    await started.future;
    cancel.cancel();
    await assertion;
    expect(calls, 1);
  });

  test(
    'NovelAI task stores its picture and source metadata in the gallery',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sillydraft-nai-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final assets = AssetLibrary(repository: repo, directory: directory);
      final runner = TaskRunner(
        repository: repo,
        assetLibrary: assets,
        providerFactory: (_) async =>
            throw StateError('Image task used text provider'),
        imageProviderFactory: (_) async => provider,
      );
      addTearDown(runner.close);
      server.listen((r) async {
        await r.drain<void>();
        r.response.add(imageZip());
        await r.response.close();
      });
      final novel = await repo.createNovel(title: 'NovelAI');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('港口起雾了'),
      );
      final task = await IllustrationService(repository: repo, runner: runner)
          .generate(
            branchId: chapter.branchId,
            chapterId: chapter.id,
            connection: provider.config,
            name: '港口插画',
            request: ImageRequest(
              prompt: 'a quiet harbor',
              parameters: {'seed': 42},
            ),
          );
      final done = await runner.wait(task.id);
      expect(done.status, TaskStatus.completed, reason: done.error.toString());
      final asset = await repo.getAsset(done.result['assetId'] as String);
      expect(asset.sourceRevisionId, chapter.revisionId);
      expect(asset.metadata['prompt'], 'a quiet harbor');
      expect(asset.metadata['model'], 'nai-diffusion-4-5-full');
      expect(await assets.read(asset.id), isNotEmpty);
      expect(
        (await repo.getChapter(
          branchId: chapter.branchId,
          chapterId: chapter.id,
        )).revisionId,
        chapter.revisionId,
      );
    },
  );

  test('model choices match pinned ST in its order', () {
    final raw = jsonDecode(
      File('test/fixtures/st/novelai-models-reference.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(NovelAIImageProvider.models, [
      for (final m in raw['models'] as List) (m as Map)['value'],
    ]);
  });
}
