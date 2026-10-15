import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

void main() {
  final payload = SharePayload(
    kind: ShareKind.skill,
    name: '技能',
    data: {'name': 'x'},
  );

  test('a ticket is taken once, and not after expiry or close', () async {
    final registry = ShareRegistry();
    final once = registry.open(payload);
    expect(registry.take(once.token)?.name, '技能');
    await once.received;
    expect(registry.take(once.token), isNull);
    final expired = registry.open(payload, lifetime: Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(registry.take(expired.token), isNull);
    final closed = registry.open(payload)..close();
    expect(registry.take(closed.token), isNull);
    expect(registry.isEmpty, isTrue);
  });

  test('a share-only host hands a payload to a pinned fetch, once', () async {
    final host = await RemoteHost.start(
      identity: testIdentity,
      name: '手机',
      appVersion: testVersion,
      address: InternetAddress.loopbackIPv4,
      port: 0,
    );
    addTearDown(host.close);
    final ticket = host.shares.open(payload);
    final link = ReceiveLink(
      host: '127.0.0.1',
      port: host.port,
      token: ticket.token,
      fingerprint: testIdentity.fingerprint,
    );
    expect((await fetchShare(link)).data, {'name': 'x'});
    await expectLater(
      fetchShare(link),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('已失效'),
        ),
      ),
    );
  });

  test('an unknown format version is refused', () {
    expect(
      () => SharePayload.fromJson({...payload.toJson(), 'format': 2}),
      throwsFormatException,
    );
  });

  test('a malformed payload is a FormatException, not a cast error', () async {
    expect(
      () => SharePayload.fromJson({
        'format': 1,
        'kind': 'skill',
        'data': <String, dynamic>{},
      }),
      throwsFormatException,
    );
    final repository = StoryRepository.memory();
    addTearDown(repository.close);
    final library = ResourceLibrary(
      repository: repository,
      keyProvider: () async => List.filled(32, 1),
    );
    await expectLater(
      receiveResource(
        library,
        SharePayload(
          kind: ShareKind.resource,
          name: 'x',
          data: {'kind': 'nonsense', 'versions': <Object>[]},
        ),
      ),
      throwsFormatException,
    );
  });

  test('a received local-CLI connection drops its command', () {
    final shared = SharePayload(
      kind: ShareKind.connection,
      name: 'cli',
      data: {
        'connection': ModelConnection(
          id: 'cli',
          name: 'cli',
          baseUrl: '',
          model: 'm',
          protocol: ModelProtocol.claudeCode,
          command: '/tmp/evil',
        ).raw,
        'apiKey': '',
      },
    );
    expect(shared.data['connection']['command'], '/tmp/evil');
    final received = receivedConnection(shared, {});
    expect(received.connection.protocol, ModelProtocol.claudeCode);
    expect(received.connection.command, isEmpty);
  });

  group('content', () {
    late StoryRepository repository;
    late ResourceLibrary resources;
    late Directory dir;
    late AssetLibrary assets;
    setUp(() async {
      repository = StoryRepository.memory();
      resources = ResourceLibrary(
        repository: repository,
        keyProvider: () async => List.filled(32, 1),
      );
      dir = await Directory.systemTemp.createTemp('sd-share');
      assets = AssetLibrary(repository: repository, directory: dir);
    });
    tearDown(() async {
      await repository.close();
      await dir.delete(recursive: true);
    });

    test('a resource arrives with the versions it was edited from', () async {
      final card = await resources.import(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'spec': 'chara_card_v2',
              'data': {'name': '苏雾', 'description': '灯塔守护人'},
            }),
          ),
        ),
        filename: '苏雾.json',
        kind: ResourceKind.character,
      );
      final edited = await resources.edit(card.id, {...card.data});
      final shared = await resourceShare(resources, edited.id);

      final other = StoryRepository.memory();
      addTearDown(other.close);
      final theirs = ResourceLibrary(
        repository: other,
        keyProvider: () async => List.filled(32, 2),
      );
      final received = await receiveResource(
        theirs,
        SharePayload.fromJson(
          jsonDecode(jsonEncode(shared.toJson())) as Map<String, dynamic>,
        ),
      );
      expect(received.parentId, isNotNull);
      expect(received.data, edited.data);
      expect(
        await theirs.original(received.parentId!),
        await resources.original(card.id),
      );
    });

    test('a persona arrives with its pictures', () async {
      final prepared = await assets.prepare(
        Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8))),
      );
      final persona = await repository.savePersona(
        Persona(
          id: '',
          name: '林岚',
          appearance: '短发',
          images: [PersonaImage.of(prepared)],
        ),
      );
      final shared = await personaShare(persona, assets);
      final received = await receivePersona(repository, assets, shared);
      expect(received.id, isNot(persona.id));
      expect(received.name, '林岚');
      expect(received.appearance, '短发');
      expect(received.images.single.hash, prepared.hash);
    });

    test('a skill and a connection with its key round-trip', () {
      final skill = AgentSkill(name: 'tone', description: '语气', body: '写得轻一点');
      expect(receivedSkill(skillShare(skill)).body, '写得轻一点');

      final connection = ModelConnection(
        id: 'writer',
        name: '写手',
        baseUrl: 'https://api.example/v1',
        model: 'm',
      );
      final shared = connectionShare(connection, 'sk-123');
      final fresh = receivedConnection(shared, {});
      expect(fresh.connection.id, 'writer');
      expect(fresh.apiKey, 'sk-123');
      final renamed = receivedConnection(shared, {'writer'});
      expect(renamed.connection.id, isNot('writer'));
      expect(renamed.connection.baseUrl, 'https://api.example/v1');
    });
  });
}
