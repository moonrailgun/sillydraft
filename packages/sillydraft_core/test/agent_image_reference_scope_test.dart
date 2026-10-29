import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'asset_library_test.dart' show testPicture;
import 'support/image_scene.dart';
import 'task_runner_test.dart' show ScriptProvider;
import 'visual_reference_test.dart' show ReferencePainter;

void main() {
  for (final (mode, scope) in [
    ('subject', 'all'),
    ('asset', 'all'),
    ('manual', 'all'),
    ('subject', 'later'),
    ('asset', 'later'),
    ('subject', 'earlier'),
    ('asset', 'earlier'),
  ]) {
    test(
      'image references follow conversation scope: $mode / $scope',
      () async {
        final repo = StoryRepository.memory();
        addTearDown(repo.close);
        final dir = Directory.systemTemp.createTempSync(
          'image-reference-scope-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final novel = await repo.createNovel(title: '参考范围');
        final branch = novel.activeBranchId;
        final earlier = await repo.createChapter(
          branchId: branch,
          content: ManuscriptContent.plainText('她推门进屋。'),
        );
        final later = await repo.createChapter(branchId: branch);
        final library = AssetLibrary(repository: repo, directory: dir);
        final asset = await library.importImage(
          branchId: branch,
          name: '阿青参考图',
          bytes: testPicture(),
          metadata: {'referencePrompt': 'short black hair'},
        );
        final character = await repo.saveLoreEntry(
          branchId: branch,
          kind: LoreKind.character,
          name: '阿青',
          content: 'short black hair',
          atChapterId: later.id,
          data: {
            'images': [asset.id],
          },
        );
        final allowed = scope != 'earlier';
        final conversation = await repo.createConversation(
          branchId: branch,
          throughChapterId: switch (scope) {
            'later' => later.id,
            'earlier' => earlier.id,
            _ => null,
          },
        );
        final connection = ModelConnection(
          id: 'test',
          name: 'test',
          baseUrl: 'http://localhost:1',
          model: 'test',
        );
        final requests = <ImageRequest>[];
        final results = <Map>[];
        var rounds = 0;
        final runner = TaskRunner(
          repository: repo,
          assetLibrary: library,
          providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
            if (rounds++ == 0) {
              yield ToolCallReady('image', 'generate_image', {
                ...emptyImageContext,
                'name': '进屋',
                'prompt': 'A woman enters the room',
                if (mode == 'subject')
                  'subjects': [
                    {
                      'kind': 'character',
                      'name': character.name,
                      'prompt': 'short black hair',
                      'loreId': character.id,
                    },
                  ],
                if (mode == 'asset') 'references': [asset.id],
              });
              yield const GenerationFinished('tool_calls');
            } else {
              results.add(
                jsonDecode(request.messages.last['content'] as String) as Map,
              );
              yield const TextDelta('已处理');
              yield const GenerationFinished('stop');
            }
          }),
          imageProviderFactory: (c) async => ReferencePainter(c, requests, []),
        );
        addTearDown(runner.close);
        final task = await EditorAgent(repository: repo, runner: runner).send(
          conversationId: conversation,
          connection: connection,
          imageConnection: connection,
          message: '生成插图',
          // A conversation without a focused chapter must still enforce its cutoff.
          focusChapterId: allowed ? earlier.id : null,
          manualImage: mode == 'manual'
              ? {
                  'references': [asset.id],
                }
              : null,
        );
        GenerationTask pending = task;
        for (var i = 0; i < 300; i++) {
          pending = await repo.getTask(task.id);
          if (!pending.isActive ||
              pending.result['imageConfirmation'] != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(requests, isEmpty);
        expect(pending.input['loreSnapshot'], allowed ? hasLength(1) : isEmpty);
        if (!allowed) {
          expect(pending.result['imageConfirmation'], isNull);
          await runner.wait(task.id);
          expect(results.single['code'], 'invalid_arguments');
          expect(await repo.listAssets(novel.id), hasLength(1));
          return;
        }
        final confirmation = pending.result['imageConfirmation'];
        expect(confirmation, isA<Map>(), reason: '${pending.error} $results');
        expect(confirmation['references'], [asset.id]);
        expect(confirmation['newReferences'], isEmpty);
        expect(confirmation['visualReferences'].single['loreId'], character.id);
        await runner.respondToImageConfirmation(
          task.id,
          confirmation['id'] as String,
          approved: true,
        );
        final done = await runner.wait(task.id);
        expect(done.status, TaskStatus.completed, reason: done.error);
        expect(results.single['status'], 'completed', reason: '$results');
        expect(requests, hasLength(1));
        final generated = await repo.getAsset(
          results.single['assetId'] as String,
        );
        expect(generated.sourceChapterId, earlier.id);
        expect(generated.sourceRevisionId, earlier.revisionId);
        expect(generated.metadata['references'].single['id'], asset.id);
        // Saving the visual description must not backdate later lore into the focus.
        expect(
          await repo.listLore(branch, throughChapterId: earlier.id),
          isEmpty,
        );
        final saved = await repo.getLoreEntry(
          branchId: branch,
          id: character.id,
        );
        expect(saved.data['referencePrompt'], isNotEmpty);
      },
    );
  }
}
