import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repo;
  setUp(() => repo = StoryRepository.memory());
  tearDown(() => repo.close());

  Future<String> branch() async =>
      (await repo.createNovel(title: '雾港')).activeBranchId;

  test(
    'prompt joins description, appearance and outfit, skipping empty parts',
    () {
      expect(
        const Persona(
          id: 'a',
          name: '林舟',
          description: ' 插画师 ',
          outfit: '卫衣',
        ).prompt,
        '插画师\n服饰：卫衣',
      );
      expect(
        const Persona(id: 'a', name: '林舟', appearance: '短发').prompt,
        '外貌：短发',
      );
      expect(Persona.me.prompt, '');
    },
  );

  test(
    'the built-in persona comes first, before and after it is edited',
    () async {
      expect((await repo.listPersonas()).map((p) => p.id), [Persona.meId]);
      final other = await repo.savePersona(const Persona(id: '', name: '林舟'));
      expect(other.id, isNotEmpty);
      await repo.savePersona(Persona.me.copyWith(appearance: '短发'));
      final all = await repo.listPersonas();
      expect(all.map((p) => p.id), [Persona.meId, other.id]);
      expect(all.first.appearance, '短发');
    },
  );

  test('saving rejects an empty name or too many images', () async {
    await expectLater(
      repo.savePersona(const Persona(id: '', name: '  ')),
      throwsFormatException,
    );
    const image = PersonaImage(
      hash: 'a',
      thumbnailHash: 'b',
      width: 1,
      height: 1,
    );
    await expectLater(
      repo.savePersona(
        Persona(id: '', name: '林舟', images: List.filled(9, image)),
      ),
      throwsFormatException,
    );
  });

  test('a profile resolves to its persona, else to the built-in one', () async {
    final linzhou = await repo.savePersona(const Persona(id: '', name: '林舟'));
    expect((await repo.personaFor({'personaId': linzhou.id})).name, '林舟');
    expect((await repo.personaFor({'personaId': 'gone'})).id, Persona.meId);
    expect((await repo.personaFor({})).id, Persona.meId);
  });

  test('a persona in use cannot be deleted until its novel is', () async {
    final linzhou = await repo.savePersona(const Persona(id: '', name: '林舟'));
    final novel = await repo.createNovel(title: '雾港');
    await repo.setSetting('writing/${novel.activeBranchId}', {
      'personaId': linzhou.id,
    });
    await expectLater(repo.deletePersona(Persona.meId), throwsFormatException);
    await expectLater(
      repo.deletePersona(linzhou.id),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('1 部作品'),
        ),
      ),
    );
    await repo.deleteNovel(novel.id);
    await repo.deletePersona(linzhou.id);
    expect((await repo.listPersonas()).map((p) => p.id), [Persona.meId]);
  });

  group('legacy profiles', () {
    test('the old default becomes the built-in persona', () async {
      final b = await branch();
      await repo.setSetting('writing/$b', {
        'cardId': 'card',
        'userName': '主角',
        'persona': '',
      });
      await repo.migrateLegacyPersonas();
      expect(await repo.getSetting('writing/$b'), {
        'cardId': 'card',
        'personaId': Persona.meId,
      });
      expect(await repo.listPersonas(), hasLength(1));
    });

    test('a custom name or description becomes a shared persona', () async {
      final a = await branch(), b = await branch(), c = await branch();
      for (final key in [a, b]) {
        await repo.setSetting('writing/$key', {
          'userName': '林舟',
          'persona': '插画师',
        });
      }
      await repo.setSetting('writing/$c', {'userName': '', 'persona': '旅人'});
      await repo.migrateLegacyPersonas();
      // Branch ids are random, so personas are created in no fixed order.
      final personas = await repo.listPersonas();
      expect(
        personas.map((p) => (p.name, p.description)),
        unorderedEquals([('我', ''), ('林舟', '插画师'), ('我', '旅人')]),
      );
      final linzhou = personas.singleWhere((p) => p.name == '林舟'),
          traveler = personas.singleWhere((p) => p.description == '旅人');
      expect((await repo.getSetting('writing/$a'))!['personaId'], linzhou.id);
      expect((await repo.getSetting('writing/$b'))!['personaId'], linzhou.id);
      expect((await repo.getSetting('writing/$c'))!['personaId'], traveler.id);
    });

    test(
      'running again, or over an existing binding, changes nothing',
      () async {
        final a = await branch(), b = await branch();
        await repo.setSetting('writing/$a', {'userName': '林舟'});
        await repo.setSetting('writing/$b', {
          'personaId': Persona.meId,
          'userName': '旧名',
        });
        Future<List<Object?>> state() async => [
          for (final p in await repo.listPersonas()) p.toJson(),
          await repo.getSetting('writing/$a'),
          await repo.getSetting('writing/$b'),
        ];
        await repo.migrateLegacyPersonas();
        final once = await state();
        await repo.migrateLegacyPersonas();
        expect(await state(), once);
        expect(once, hasLength(4));
        expect(await repo.getSetting('writing/$b'), {
          'personaId': Persona.meId,
        });
      },
    );

    test(
      'migration keeps a synced novel in sync, not a locally edited one',
      () async {
        final synced = await repo.createNovel(title: '甲'),
            edited = await repo.createNovel(title: '乙');
        for (final n in [synced, edited]) {
          await repo.setSetting('writing/${n.activeBranchId}', {
            'userName': '林舟',
          });
        }
        Future<String> print(String id) async =>
            (await repo.exportProject(id)).fingerprint;
        await repo.setSetting('syncState/${synced.id}', {
          'remoteEtag': 'e1',
          'localFingerprint': await print(synced.id),
        });
        await repo.setSetting('syncState/${edited.id}', {
          'remoteEtag': 'e2',
          'localFingerprint': 'stale',
        });
        await repo.migrateLegacyPersonas();
        expect(await repo.getSetting('syncState/${synced.id}'), {
          'remoteEtag': 'e1',
          'localFingerprint': await print(synced.id),
        });
        expect(
          (await repo.getSetting(
            'syncState/${edited.id}',
          ))!['localFingerprint'],
          'stale',
        );
      },
    );

    test('an imported snapshot binds an equal persona or a new one', () async {
      final a = await branch(), b = await branch();
      await repo.savePersona(Persona.me.copyWith(appearance: '短发'));
      Map<String, String> snapshot(String appearance) => {
        'name': '我',
        'description': '',
        'appearance': appearance,
        'outfit': '',
      };
      await repo.setSetting('writing/$a', {'personaSnapshot': snapshot('短发')});
      await repo.setSetting('writing/$b', {'personaSnapshot': snapshot('长发')});
      await repo.migrateLegacyPersonas();
      final personas = await repo.listPersonas();
      expect(personas, hasLength(2));
      expect(await repo.getSetting('writing/$a'), {'personaId': Persona.meId});
      expect(
        (await repo.getSetting('writing/$b'))!['personaId'],
        personas[1].id,
      );
      expect(personas[1].appearance, '长发');
    });
  });

  test('asset pruning keeps persona images', () async {
    final dir = await Directory.systemTemp.createTemp('persona');
    addTearDown(() => dir.delete(recursive: true));
    final library = AssetLibrary(repository: repo, directory: dir);
    final prepared = await library.prepare(
      Uint8List.fromList(img.encodePng(img.Image(width: 2, height: 2))),
    );
    await repo.savePersona(
      Persona.me.copyWith(images: [PersonaImage.of(prepared)]),
    );
    expect(
      await repo.assetFileNames(),
      containsAll(['${prepared.hash}.png', '${prepared.thumbnailHash}.jpg']),
    );
    expect(
      await library.readHash(prepared.thumbnailHash, thumbnail: true),
      isNotEmpty,
    );
  });
}
