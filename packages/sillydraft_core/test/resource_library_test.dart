import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
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
}
