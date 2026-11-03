import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'remote_support.dart';
import 'support/image_scene.dart';

class _Images implements ImageProvider {
  _Images(this.config, this.draw);
  @override
  final ModelConnection config;
  final void Function() draw;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    draw();
    return GeneratedImage(bytes: testPicture());
  }

  @override
  void close() {}
}

void main() {
  final connection = ModelConnection(
    id: 'engine',
    name: '引擎',
    baseUrl: 'http://localhost:1',
    model: 'model',
  );

  test('legacy hello does not advertise image policy enforcement', () {
    for (final version in [null, 0, 1, '1', 2]) {
      final hello = RemoteHello({
        'name': '桌面',
        'appVersion': testVersion,
        'resourceKey': base64Encode(List.filled(32, 7)),
        'imageContentPolicy': ?version,
      });
      expect(hello.imageContentPolicy, version == 1);
    }
  });

  for (final (adult, fromPhone) in [
    (true, true),
    (false, true),
    (false, false),
  ]) {
    test(
      'restricted remote assistant preserves policy through preparation: adult=$adult phone=$fromPhone',
      () async {
        var draws = 0;
        final desktop = await Desktop.start(
          connections: [connection],
          imageProviderFactory: (c) async => _Images(c, () => draws++),
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            if (request.executionId?.startsWith('image-prompt-') == true) {
              yield TextDelta(
                (request.messages.first['content'] as String).contains('内容分类器')
                    ? '$adult'
                    : 'ordinary scene',
              );
              yield const GenerationFinished('stop');
            } else {
              yield ToolCallReady('image', 'generate_image', {
                ...emptyImageContext,
                'name': '图片',
                'prompt': 'scene',
              });
              yield const GenerationFinished('tool_calls');
            }
          }),
        );
        addTearDown(desktop.close);
        final phone = await desktop.phone();
        addTearDown(phone.close);
        final tasks = RemoteTaskControl(
          phone,
          allowNsfwImages: false,
          providerFactory: (_) async =>
              throw StateError('Only desktop calls models'),
        );
        final novel = await desktop.repository.createNovel(title: '远程限制');
        final conversation = await desktop.repository.createConversation(
          branchId: novel.activeBranchId,
        );
        final task =
            await EditorAgent(
              repository: phone.repository,
              runner: fromPhone ? tasks : desktop.runner,
            ).send(
              conversationId: conversation,
              connection: connection,
              message: '画一张插图',
              imageConnection: connection,
              imagePromptConnection: connection,
              nsfwImageConnection: connection,
              illustrationOnly: true,
            );
        GenerationTask pending = task;
        for (var i = 0; i < 400; i++) {
          pending = await phone.repository.getTask(task.id);
          if (!pending.isActive ||
              pending.result['imageConfirmation'] != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(draws, 0);
        expect(pending.input['allowNsfwImages'], fromPhone ? false : isNull);
        if (!adult) {
          final confirmation = pending.result['imageConfirmation'] as Map;
          expect(
            await tasks.respondToImageConfirmation(
              task.id,
              confirmation['id'] as String,
              approved: true,
            ),
            isTrue,
          );
        }
        final done = await tasks
            .wait(task.id)
            .timeout(const Duration(seconds: 10));
        expect(
          done.status,
          adult ? TaskStatus.failed : TaskStatus.completed,
          reason: done.error,
        );
        expect(draws, adult ? 0 : 1);
      },
    );
  }

  test(
    'restricted phone blocks old image retries and unsafe confirmations',
    () async {
      var draws = 0;
      final desktop = await Desktop.start(
        connections: [connection],
        imageProviderFactory: (c) async => _Images(c, () => draws++),
      );
      addTearDown(desktop.close);
      final phone = await desktop.phone();
      addTearDown(phone.close);
      final tasks = RemoteTaskControl(
        phone,
        allowNsfwImages: false,
        providerFactory: (_) async => throw StateError('No text call expected'),
      );
      final novel = await desktop.repository.createNovel(title: '旧任务');
      for (final classification in [true, null]) {
        final old = await desktop.repository.createTask(
          branchId: novel.activeBranchId,
          kind: TaskKind.illustration,
          input: {
            'connection': connection.raw,
            'nsfw': ?classification,
            'imageRequest': ImageRequest(prompt: 'scene').raw,
            'name': '图片',
            'purpose': 'illustration',
            'references': <Object>[],
          },
        );
        await desktop.repository.updateTask(old.id, status: TaskStatus.failed);
        final retried = await tasks.resume(old.id);
        final done = await tasks
            .wait(retried.id)
            .timeout(const Duration(seconds: 10));
        expect(done.input['allowNsfwImages'], false);
        expect(done.status, TaskStatus.failed);
        expect(done.error, contains('NSFW'));
        expect(draws, 0);
        await expectLater(tasks.reconnectRemote(old.id), throwsFormatException);
      }
      final confirmationTask = await desktop.repository.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.agent,
        input: {'connection': connection.raw, 'allowNsfwImages': false},
      );
      await desktop.repository.updateTask(
        confirmationTask.id,
        status: TaskStatus.running,
        result: {
          'imageConfirmation': {
            'id': 'pending',
            'images': [
              {'nsfw': false},
            ],
            'newReferences': [
              {'nsfw': true},
            ],
          },
        },
      );
      await expectLater(
        tasks.respondToImageConfirmation(
          confirmationTask.id,
          'pending',
          approved: true,
        ),
        throwsFormatException,
      );
      expect(
        await tasks.respondToImageConfirmation(
          confirmationTask.id,
          'pending',
          approved: false,
        ),
        isFalse,
      );
      expect(draws, 0);
    },
  );
}
