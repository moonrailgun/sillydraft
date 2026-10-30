import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repo;
  setUp(() => repo = StoryRepository.memory());
  tearDown(() => repo.close());

  Future<void> preset(String id) => repo.storeResource(
    id: id,
    kind: ResourceKind.preset,
    name: id,
    filename: '$id.json',
    sourceHash: id,
    encryptedSource: [],
    data: {'name': id, 'temperature': 0.7, 'openai_max_tokens': 321},
  );

  Future<ImportedPreset?> boundPreset(Novel novel) async => repo.writingPreset(
    await repo.getSetting('writing/${novel.activeBranchId}') ?? {},
  );

  test(
    'default persists across restart and only affects future novels',
    () async {
      await repo.close();
      final dir = await Directory.systemTemp.createTemp('sillydraft-default-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/library.sqlite';
      repo = StoryRepository.open(path);
      final before = await repo.createNovel(title: '已有小说');
      await preset('first');
      await preset('second');
      await repo.setSetting('writingDefaults', {'presetId': 'first'});
      await repo.close();
      repo = StoryRepository.open(path);
      final first = await repo.createNovel(title: '使用默认预设');
      expect((await boundPreset(first))?.parameters['temperature'], 0.7);
      await repo.setSetting('writingDefaults', {'presetId': 'second'});
      final second = await repo.createNovel(title: '切换默认预设');
      await repo.setSetting('writingDefaults', {});
      final cleared = await repo.createNovel(title: '清除默认预设');
      expect(await boundPreset(before), isNull);
      expect((await boundPreset(first))?.name, 'first');
      expect((await boundPreset(second))?.name, 'second');
      expect(await boundPreset(cleared), isNull);
    },
  );

  test(
    'card and manuscript starts inherit the preset and card macros use it',
    () async {
      await preset('default');
      await repo.setSetting('writingDefaults', {'presetId': 'default'});
      await repo.storeResource(
        id: 'card',
        kind: ResourceKind.character,
        name: '苏雾',
        filename: 'card.json',
        sourceHash: 'card',
        encryptedSource: [],
        data: {
          'spec': 'chara_card_v2',
          'data': {'name': '苏雾', 'first_mes': '{{user}}：{{maxResponse}}'},
        },
      );
      final card = await repo.createNovelFromCard(
        resourceId: 'card',
        title: '角色卡',
      );
      expect((await repo.getStory(card.activeBranchId)).text.trim(), '我：321');
      expect(await repo.getSetting('writing/${card.activeBranchId}'), {
        'presetId': 'default',
        'cardId': 'card',
        'personaId': Persona.meId,
        'greetingIndex': 0,
      });
      final imported = await repo.createNovelFromManuscript(
        ManuscriptImporter.parse(
          Uint8List.fromList(utf8.encode('第一章 起雾\n海面起雾了。')),
          filename: '导入小说.txt',
        ),
      );
      expect((await boundPreset(imported))?.name, 'default');
      expect(
        (await repo.getStory(imported.activeBranchId)).text,
        contains('海面起雾了。'),
      );
    },
  );

  test(
    'default protects its resource from deletion and still works when archived',
    () async {
      await preset('default');
      await repo.setSetting('writingDefaults', {'presetId': 'default'});
      await expectLater(repo.deleteResource('default'), throwsFormatException);
      await repo.archiveResource('default', archived: true);
      final novel = await repo.createNovel(title: '已归档的默认预设');
      expect((await boundPreset(novel))?.name, 'default');
      await preset('unused');
      await repo.setSetting('writingDefaults', {'presetId': 'unused'});
      await repo.setSetting('writingDefaults', {});
      await repo.deleteResource('unused');
    },
  );

  test(
    'an unavailable default fails creation without leaving an empty novel',
    () async {
      await repo.setSetting('writingDefaults', {'presetId': 'missing'});
      await expectLater(repo.createNovel(title: '不可创建'), throwsFormatException);
      expect(await repo.listNovels(), isEmpty);
    },
  );
}
