import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> _card({bool zod = false, bool initVar = true}) => {
  'spec': 'chara_card_v2',
  'spec_version': '2.0',
  'data': {
    'name': '道渊',
    'first_mes': "开场。\n_.set('主角.生命', 100, 90);//开局",
    if (initVar)
      'character_book': {
        'name': '道渊世界书',
        'entries': [
          {
            'id': 1,
            'keys': <String>[],
            'comment': '[initvar] 初始',
            'content': '主角:\n  生命: 100\n  境界: 凡人\n人物: {}\n',
          },
        ],
      },
    'extensions': {
      if (zod)
        'tavern_helper': {
          'scripts': [
            {'name': 'ZOD', 'enabled': true, 'content': 'registerMvuSchema(x)'},
          ],
        },
    },
  },
};

void main() {
  late StoryRepository repo;
  setUp(() => repo = StoryRepository.memory());
  tearDown(() => repo.close());

  Future<String> branchWith(Map<String, dynamic> card) async {
    await repo.storeResource(
      id: 'card',
      kind: ResourceKind.character,
      name: '道渊',
      filename: 'card.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: card,
    );
    return (await repo.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
    )).activeBranchId;
  }

  test('markup stripping covers the plural listing and any case', () {
    const text =
        '正文\n<status_current_variables>\n世界: x\n</status_current_variables>\n\n<statusplaceholderimpl/>\n';
    expect(hasMvuMarkup(text), isTrue);
    expect(stripMvuMarkup(text), '正文');
    expect(hasMvuMarkup('普通正文'), isFalse);
  });

  test(
    'the schema policy follows the profile switch for stored records',
    () async {
      final branchId = await branchWith(_card(zod: true));
      final service = MvuService(repo);
      final story = await repo.getStory(branchId);
      final sceneId = story.scenes.single.id;
      expect((await service.storedAt(branchId))!.schema, {'type': 'any'});
      await repo.setSetting('writing/$branchId', {
        ...?await repo.getSetting('writing/$branchId'),
        MvuService.schemaChecksKey: true,
      });
      final base = (await service.baseFor(branchId, sceneId))!;
      expect(base.schema['type'], 'object');
      expect(
        ((base.schema['properties'] as Map)['人物'] as Map)['extensible'],
        isFalse,
      );
      final result = MvuUpdater.apply("_.insert('人物', '新人', {});", base);
      expect(result.errors.single, contains('不可扩展'));
      await repo.setSetting('writing/$branchId', {
        ...?await repo.getSetting('writing/$branchId'),
        MvuService.schemaChecksKey: false,
      });
      expect((await service.baseFor(branchId, sceneId))!.schema, {
        'type': 'any',
      });
    },
  );

  test(
    'a scene keeps its record as base when nothing seeds variables any more',
    () async {
      final branchId = await branchWith(_card());
      final service = MvuService(repo);
      final story = await repo.getStory(branchId);
      final sceneId = story.scenes.single.id;
      final profile = await repo.getSetting('writing/$branchId') ?? {};
      await repo.setSetting(
        'writing/$branchId',
        {...profile}..remove('cardId'),
      );
      final base = await service.baseFor(branchId, sceneId, entries: const []);
      expect(base, isNotNull);
      expect(base!.statData['主角']['生命'], 90);
    },
  );

  test('reloadInitVar reports nothing to load and broken entries', () async {
    final branchId = await branchWith(_card(initVar: false));
    final service = MvuService(repo);
    expect(await service.reloadInitVar(branchId), isNull);
    await repo.storeResource(
      id: 'book',
      kind: ResourceKind.worldBook,
      name: '坏书',
      filename: 'book.json',
      sourceHash: 'fixture2',
      encryptedSource: [],
      data: {
        'name': '坏书',
        'entries': [
          {
            'id': 1,
            'keys': <String>[],
            'comment': '[InitVar]',
            'content': 'a: [x',
          },
        ],
      },
    );
    await repo.setSetting('writing/$branchId', {
      ...?await repo.getSetting('writing/$branchId'),
      'worldBookIds': ['book'],
    });
    expect(() => service.reloadInitVar(branchId), throwsFormatException);
  });

  test(
    'a page writing a partial table does not erase the MVU record',
    () async {
      final branchId = await branchWith(_card());
      final backend = BranchChatBackend(
        repository: repo,
        branchId: branchId,
        context: await repo.displayContext(branchId),
      );
      await backend.replaceVariables(
        {'seen': true},
        {'type': 'message', 'message_id': 0},
        messageId: 0,
      );
      final stored = await repo.getBranchVariables(branchId);
      expect(stored.local['seen'], 'true');
      expect(MvuData.fromStored(stored.local)!.statData['主角']['生命'], 90);
      // A table that carries the record replaces it as asked.
      await backend.replaceVariables(
        {
          'stat_data': {'x': 1},
          'schema': {'type': 'object', 'properties': <String, dynamic>{}},
        },
        {'type': 'message', 'message_id': 0},
        messageId: 0,
      );
      final replaced = await repo.getBranchVariables(branchId);
      expect(MvuData.fromStored(replaced.local)!.statData, {'x': 1});
      expect(replaced.local.containsKey('seen'), isFalse);
    },
  );
}
