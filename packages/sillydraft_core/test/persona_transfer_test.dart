import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository source, target;
  setUp(() {
    source = StoryRepository.memory();
    target = StoryRepository.memory();
  });
  tearDown(() async {
    await source.close();
    await target.close();
  });

  test(
    'a bound persona travels as its text and restores to a local persona',
    () async {
      final linzhou = await source.savePersona(
        const Persona(id: '', name: '林舟', appearance: '短发'),
      );
      final novel = await source.createNovel(title: '雾港');
      final branch = novel.activeBranchId;
      await source.setSetting('writing/$branch', {'personaId': linzhou.id});

      final snapshot = await source.exportProject(novel.id);
      final row = snapshot.tables['app_settings']!.singleWhere(
        (r) => r['key'] == 'writing/$branch',
      );
      expect(jsonDecode(row['value_json'] as String), {
        'personaSnapshot': {
          'name': '林舟',
          'description': '',
          'appearance': '短发',
          'outfit': '',
        },
      });

      await target.restoreProject(snapshot, encryptedSources: {});
      final restored = await target.personaFor(
        (await target.getSetting('writing/$branch'))!,
      );
      expect((restored.name, restored.appearance), ('林舟', '短发'));
      expect(
        (await target.exportProject(novel.id)).fingerprint,
        snapshot.fingerprint,
      );

      await target.restoreProject(
        snapshot,
        encryptedSources: {},
        expectedFingerprint: snapshot.fingerprint,
      );
      expect(await target.listPersonas(), hasLength(2));
    },
  );

  test(
    '“我” travels as its fixed id, so each device keeps its own “我”',
    () async {
      final novel = await source.createNovel(title: '雾港');
      final branch = novel.activeBranchId;
      await source.setSetting('writing/$branch', {'personaId': Persona.meId});
      final before = await source.exportProject(novel.id);
      final row = before.tables['app_settings']!.singleWhere(
        (r) => r['key'] == 'writing/$branch',
      );
      expect(jsonDecode(row['value_json'] as String), {
        'personaId': Persona.meId,
      });

      // Editing “我” is not an edit to the novel.
      await source.savePersona(Persona.me.copyWith(appearance: '短发'));
      expect(
        (await source.exportProject(novel.id)).fingerprint,
        before.fingerprint,
      );

      await target.savePersona(Persona.me.copyWith(appearance: '长发'));
      await target.restoreProject(before, encryptedSources: {});
      final restored = await target.personaFor(
        (await target.getSetting('writing/$branch'))!,
      );
      expect((restored.id, restored.appearance), (Persona.meId, '长发'));
      expect(await target.listPersonas(), hasLength(1));
      expect(
        (await target.exportProject(novel.id)).fingerprint,
        before.fingerprint,
      );
    },
  );

  test('an export from before personas restores its free-text user', () async {
    final novel = await source.createNovel(title: '雾港');
    final branch = novel.activeBranchId;
    await source.setSetting('writing/$branch', {
      'userName': '林舟',
      'persona': '插画师',
    });
    await target.restoreProject(
      await source.exportProject(novel.id),
      encryptedSources: {},
    );
    final restored = await target.personaFor(
      (await target.getSetting('writing/$branch'))!,
    );
    expect((restored.name, restored.description), ('林舟', '插画师'));
    expect(await target.getSetting('writing/$branch'), {
      'personaId': restored.id,
    });
  });

  test(
    'a backup with a local persona id or a malformed snapshot is rejected',
    () async {
      final novel = await source.createNovel(title: '雾港');
      await source.setSetting('writing/${novel.activeBranchId}', {});
      final raw = (await source.exportProject(novel.id)).toJson();
      Future<void> restoreWith(Map<String, dynamic> value) async {
        final copy = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
        final rows = (copy['tables'] as Map)['app_settings'] as List;
        (rows.singleWhere((r) => (r['key'] as String).startsWith('writing/'))
            as Map)['value_json'] = jsonEncode(
          value,
        );
        final fresh = StoryRepository.memory();
        try {
          await fresh.restoreProject(
            ProjectSnapshot.fromJson(copy),
            encryptedSources: {},
          );
        } finally {
          await fresh.close();
        }
      }

      await expectLater(
        restoreWith({'personaId': 'local-persona'}),
        throwsFormatException,
      );
      await expectLater(
        restoreWith({'personaSnapshot': 'me'}),
        throwsFormatException,
      );
      await expectLater(
        restoreWith({
          'personaSnapshot': {'name': 3},
        }),
        throwsFormatException,
      );
    },
  );
}
