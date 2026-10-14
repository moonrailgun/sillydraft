import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('starting from a card selects one greeting and seeds sourced lore and persona', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final library = ResourceLibrary(
      repository: repo,
      keyProvider: () async => List.filled(32, 1),
    );
    final resource = await library.import(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v2',
            'data': {
              'name': '苏雾',
              'description': '灯塔守护人',
              'scenario': '雾港的渡口',
              'first_mes': '{{user}}听见钟声。',
              'alternate_greetings': [
                '{{setvar::route::sea}}{{char}}交给{{user}}一封信。',
              ],
              'character_book': {
                'entries': [
                  {
                    'id': 1,
                    'keys': ['灯塔'],
                    'content': '灯塔只在夜间出现',
                    'enabled': true,
                  },
                ],
              },
            },
          }),
        ),
      ),
      filename: 'card.json',
      kind: ResourceKind.character,
    );
    final novel = await repo.createNovelFromCard(
      resourceId: resource.id,
      title: '雾港',
      userName: '林舟',
      greetingIndex: 1,
    );
    final story = await repo.getStory(novel.activeBranchId);
    expect(story.text.trim(), '苏雾交给林舟一封信。');
    expect(story.text, isNot(contains('听见钟声')));
    final lore = await repo.listLore(novel.activeBranchId);
    expect(
      lore
          .where((e) => e.kind == LoreKind.character)
          .single
          .provenance['resourceId'],
      resource.id,
    );
    expect(lore.any((e) => e.data['worldBookOnly'] == true), isTrue);
    expect(
      (await repo.getSetting('writing/${novel.activeBranchId}'))?['userName'],
      '林舟',
    );
    final edited = await repo.createNovelFromCard(
      resourceId: resource.id,
      title: '修改开场',
      greetingIndex: 1,
      openingOverride: '自行修改后的开场',
    );
    expect(
      (await repo.getBranchVariables(edited.activeBranchId)).local['route'],
      'sea',
    );
    expect(
      (await repo.getStory(edited.activeBranchId)).text.trim(),
      '自行修改后的开场',
    );
  });
  test('resource versions preserve unknown fields and protect original credentials across restart', () async {
    final dir = Directory.systemTemp.createTempSync('sillydraft-library-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/library.sqlite';
    var repo = StoryRepository.open(path);
    final key = List<int>.generate(32, (i) => i);
    var library = ResourceLibrary(
      repository: repo,
      keyProvider: () async => key,
    );
    final raw = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'name': '预设',
          'temperature': .7,
          'api_key': 'sensitive-original-value',
          'extensions': {'unknown': 'retained'},
        }),
      ),
    );
    final imported = await library.import(
      raw,
      filename: 'preset.json',
      kind: ResourceKind.preset,
    );
    expect(imported.data['api_key'], isNull);
    expect(imported.data['extensions'], {'unknown': 'retained'});
    expect(await library.original(imported.id), orderedEquals(raw));
    final edited = await library.edit(imported.id, {
      ...imported.data,
      'temperature': .5,
    });
    expect(edited.parentId, imported.id);
    expect((await repo.getResource(imported.id)).data['temperature'], .7);
    await repo.close();
    final disk = File(path).readAsBytesSync();
    expect(latin1.decode(disk).contains('sensitive-original-value'), isFalse);
    repo = StoryRepository.open(path);
    addTearDown(repo.close);
    library = ResourceLibrary(repository: repo, keyProvider: () async => key);
    expect(await library.original(imported.id), orderedEquals(raw));
    expect((await repo.listResources()).length, 2);
    final wrong = ResourceLibrary(
      repository: repo,
      keyProvider: () async => List.filled(32, 9),
    );
    await expectLater(
      wrong.original(imported.id),
      throwsA(isA<FormatException>()),
    );
  });

  test('invalid imports leave the library unchanged and archived cards remain bound', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final library = ResourceLibrary(
      repository: repo,
      keyProvider: () async => List.filled(32, 1),
    );
    await expectLater(
      library.import(
        Uint8List.fromList(utf8.encode('{broken')),
        filename: 'bad.json',
        kind: ResourceKind.character,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(await repo.listResources(), isEmpty);
    final card = await library.import(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'name': '林舟',
            'first_mes': '{{user}}来到了渡口。',
            'alternate_greetings': ['灯亮了。'],
          }),
        ),
      ),
      filename: 'card.json',
      kind: ResourceKind.character,
    );
    await repo.archiveResource(card.id, archived: true);
    expect(await repo.listResources(), isEmpty);
    expect((await library.character(card.id)).name, '林舟');
  });

  test(
    'files without a name are named after the file, as in SillyTavern',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final library = ResourceLibrary(
        repository: repo,
        keyProvider: () async => List.filled(32, 1),
      );
      Uint8List json(Map<String, Object?> value) =>
          Uint8List.fromList(utf8.encode(jsonEncode(value)));
      // An exported chat completion preset: settings and prompts, no name.
      final preset = json({
        'temperature': 1.08,
        'prompts': [
          {'identifier': 'main', 'name': 'Main Prompt', 'content': '写作'},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
            ],
          },
        ],
      });
      final reborn = await library.import(
        preset,
        filename: 'Reborn2.3.json',
        kind: ResourceKind.preset,
      );
      expect(reborn.name, 'Reborn2.3');
      expect(
        library
            .inspect(
              preset,
              filename: 'presets/Mine.JSON',
              kind: ResourceKind.preset,
            )
            .name,
        'Mine',
      );
      final named = await library.import(
        json({
          ...jsonDecode(utf8.decode(preset)) as Map<String, Object?>,
          'name': '自带名字',
        }),
        filename: 'Reborn2.3.json',
        kind: ResourceKind.preset,
      );
      expect(named.name, '自带名字');
      final book = await library.import(
        json({'entries': <String, Object?>{}}),
        filename: '雾港世界书.json',
        kind: ResourceKind.worldBook,
      );
      expect(book.name, '雾港世界书');
    },
  );
}
