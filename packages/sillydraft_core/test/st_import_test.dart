import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> cardJson({int version = 3}) {
  final data = <String, dynamic>{
    'name': '林舟',
    'description': '港口的信使',
    'personality': '谨慎',
    'scenario': '雨夜',
    'first_mes': '船靠岸了。',
    'mes_example': '例句',
    'alternate_greetings': ['旧信到了。'],
    'system_prompt': '{{original}}\n叙事',
    'post_history_instructions': '保持悬念',
    'extensions': {
      'future': [1, 2],
    },
    'character_book': {
      'entries': [
        {
          'id': 7,
          'keys': ['雾港'],
          'content': '海港',
          'enabled': true,
          'insertion_order': 50,
          'extensions': {'depth': 2},
        },
      ],
    },
  };
  return version == 1
      ? data
      : {
          'spec': 'chara_card_v$version',
          'spec_version': '$version.0',
          'data': data,
          'future_root': true,
        };
}

Uint8List jsonBytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Uint8List pngWithCards(Map<String, Object> cards) {
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    final body = [...ascii.encode(type), ...data];
    out.add(body);
    out.add((ByteData(4)..setUint32(0, getCrc32(body))).buffer.asUint8List());
  }

  chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  for (final entry in cards.entries) {
    chunk('tEXt', [
      ...ascii.encode(entry.key),
      0,
      ...ascii.encode(base64Encode(jsonBytes(entry.value))),
    ]);
  }
  chunk('IEND', []);
  return out.takeBytes();
}

Map<String, dynamic> fixture(String path) =>
    jsonDecode(File('test/fixtures/st/$path').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  for (final version in [1, 2, 3]) {
    test(
      'V$version card retains original data and distinguishes greetings from facts',
      () {
        final raw = cardJson(version: version);
        final card = CardImporter().decode(jsonBytes(raw), 'character.json');
        expect(card.name, '林舟');
        expect(card.version, version);
        expect(card.greetings, ['船靠岸了。', '旧信到了。']);
        expect(card.worldBook!.entries.single.content, '海港');
        expect(card.worldBook!.entries.single.depth, 2);
        expect(card.exportJson(), raw);
        final copy = card.raw;
        copy.clear();
        expect(card.name, '林舟');
        expect(card.raw, raw);
      },
    );
  }

  test('PNG uses ccv3 over chara irrespective of chunk order', () {
    final older = cardJson(version: 2);
    (older['data'] as Map<String, dynamic>)['name'] = '旧名字';
    final bytes = pngWithCards({'ccv3': cardJson(), 'chara': older});
    final card = CardImporter().decode(bytes, 'card.png');
    expect(card.name, '林舟');
    expect(card.version, 3);
    expect(card.sourceBytes, bytes);
  });

  test('corrupt PNG and malformed or oversized JSON are rejected', () {
    final bytes = pngWithCards({'chara': cardJson()});
    bytes[40] ^= 1;
    expect(
      () => CardImporter().decode(bytes, 'bad.png'),
      throwsFormatException,
    );
    expect(
      () => CardImporter().decode(jsonBytes([]), 'bad.json'),
      throwsFormatException,
    );
    expect(
      () => CardImporter().decode(jsonBytes({'name': 3}), 'bad.json'),
      throwsFormatException,
    );
    expect(
      () =>
          CardImporter(maxBytes: 20)
              .decode(jsonBytes(cardJson()), 'large.json'),
      throwsFormatException,
    );
  });

  test('CHARX reads embedded assets without extracting or executing them', () {
    final raw = cardJson();
    (raw['data'] as Map<String, dynamic>)['assets'] = [
      {
        'type': 'icon',
        'uri': 'embeded://assets/icon.png',
        'name': 'main',
        'ext': 'png',
      },
    ];
    final archive = Archive()
      ..add(ArchiveFile.bytes('card.json', jsonBytes(raw)))
      ..add(ArchiveFile.bytes('assets/icon.png', [1, 2, 3]));
    final card = CardImporter().decode(
      Uint8List.fromList(ZipEncoder().encode(archive)),
      'card.charx',
    );
    expect(card.assets['assets/icon.png'], [1, 2, 3]);
    expect(card.exportJson(), raw);
  });

  test(
    'CHARX blocks unsafe paths and excessive expansion before reading content',
    () {
      for (final name in [
        '../escape',
        '/absolute',
        'C:/drive',
        'assets/../../escape',
        'a\\b',
      ]) {
        final archive = Archive()
          ..add(ArchiveFile.bytes('card.json', jsonBytes(cardJson())))
          ..add(ArchiveFile.bytes(name, [1]));
        final encoded = Uint8List.fromList(ZipEncoder().encode(archive));
        // ZipEncoder normalizes backslashes. Restore the hostile name in both
        // headers so this test actually exercises an unsafe imported archive.
        if (name == 'a\\b') {
          for (var i = 0; i < encoded.length - 2; i++) {
            if (encoded[i] == 97 &&
                encoded[i + 1] == 47 &&
                encoded[i + 2] == 98) {
              encoded[i + 1] = 92;
            }
          }
        }
        expect(
          () => CardImporter().decode(encoded, 'bad.charx'),
          throwsFormatException,
          reason: name,
        );
      }
      final archive = Archive()
        ..add(ArchiveFile.bytes('card.json', jsonBytes(cardJson())))
        ..add(ArchiveFile.bytes('large.txt', List.filled(100000, 0)));
      expect(
        () => CardImporter(
          maxExpandedBytes: 2048,
        ).decode(Uint8List.fromList(ZipEncoder().encode(archive)), 'big.charx'),
        throwsFormatException,
      );
    },
  );

  test(
    'official presets have distinct types and lossless structural round trips',
    () {
      final cases = {
        'openai/Default.json': PresetKind.chat,
        'textgen/Default.json': PresetKind.textCompletion,
        'context/Default.json': PresetKind.context,
        'instruct/ChatML.json': PresetKind.instruct,
        'sysprompt/Writer - Creative.json': PresetKind.systemPrompt,
        'reasoning/Think XML.json': PresetKind.reasoning,
      };
      for (final entry in cases.entries) {
        final raw = fixture(entry.key);
        final preset = PresetImporter().decode(raw);
        expect(preset.kind, entry.value, reason: entry.key);
        expect(preset.exportJson(), raw, reason: entry.key);
      }
      final chat = PresetImporter().decode(fixture('openai/Default.json'));
      expect(
        chat.orderGroups.map((g) => g.characterId),
        containsAll([100000, 100001]),
      );
    },
  );

  test(
    'independent prompt packs and combined templates are not full chat presets',
    () {
      final pack = PresetImporter().decode({
        'version': 1,
        'type': 'full',
        'data': {
          'prompts': [
            {'identifier': 'main', 'role': 'system', 'content': 'write'},
          ],
          'prompt_order': [
            {'identifier': 'main', 'enabled': true},
          ],
        },
      });
      expect(pack.kind, PresetKind.promptPack);
      expect(pack.orderGroups.single.items.single.identifier, 'main');
      final combined = PresetImporter().decode({
        'context': fixture('context/Story.json'),
        'instruct': fixture('instruct/Story.json'),
        'preset': fixture('textgen/Default.json'),
      });
      expect(combined.kind, PresetKind.bundle);
      expect(combined.parts['context']!.kind, PresetKind.context);
    },
  );

  test(
    'legacy chat fields migrate without deleting original or unknown fields',
    () {
      final raw = {
        'main_prompt': 'write',
        'nsfw_prompt': 'style',
        'jailbreak_prompt': 'end',
        'temperature': 0.7,
        'future': {'opaque': true},
      };
      final preset = PresetImporter().decode(raw);
      expect(preset.kind, PresetKind.chat);
      expect(
        preset.prompts.map((p) => p.identifier),
        containsAll(['main', 'nsfw', 'jailbreak']),
      );
      expect(preset.exportJson(), raw);
    },
  );

  test('duplicate identifiers and unresolved order groups are explicit diagnostics', () {
    final preset = PresetImporter().decode({
      'prompts': [
        {'identifier': 'x', 'content': 'one'},
        {'identifier': 'x', 'content': 'two'},
      ],
      'prompt_order': [
        {
          'character_id': 42,
          'order': [
            {'identifier': 'missing', 'enabled': true},
          ],
        },
      ],
    });
    expect(
      preset.diagnostics.map((d) => d.code),
      containsAll(['duplicate_prompt', 'unknown_prompt']),
    );
    expect(() => preset.selectOrder(), throwsA(isA<PresetSelectionRequired>()));
    expect(preset.selectOrder(characterId: 42).single.identifier, 'missing');
  });

  for (final setting in {
    'verbosity': ['high', 'auto'],
    'show_thoughts': [true, false],
    'enable_web_search': [true, false],
  }.entries) {
    test('unapplied ${setting.key} is retained with a field diagnostic', () {
      for (final value in setting.value) {
        final raw = {'main_prompt': 'write', setting.key: value};
        final preset = PresetImporter().decode(raw);
        expect(preset.exportJson(), raw);
        expect(preset.parameters, isNot(contains(setting.key)));
        final diagnostic = preset.diagnostics.single;
        expect(diagnostic.code, 'preset_setting_not_applied');
        expect(diagnostic.path, setting.key);
        expect(diagnostic.severity, DiagnosticSeverity.warning);
        expect(diagnostic.message, contains(setting.key));
      }
    });
  }

  test('sensitive connection fields never enter default export or normalized parameters', () {
    final preset = PresetImporter().decode({
      'main_prompt': 'hello',
      'reverse_proxy': 'https://elsewhere',
      'proxy_password': 'secret',
      'custom_headers': 'Authorization: token',
      'extensions': {'api_key': 'hidden', 'unrelated': 42},
    });
    expect(jsonEncode(preset.exportJson()), isNot(contains('secret')));
    expect(jsonEncode(preset.exportJson()), isNot(contains('token')));
    expect(jsonEncode(preset.exportJson()), isNot(contains('hidden')));
    expect(preset.raw['proxy_password'], 'secret');
    expect(preset.connectionFields['reverse_proxy'], 'https://elsewhere');
    expect(preset.parameters, isNot(contains('reverse_proxy')));
    expect(preset.exportJson()['extensions'], {'unrelated': 42});
  });

  test(
    'text completion presets keep every sampling setting pinned ST saves',
    () {
      // Model and status settings, and extensions, are not request parameters.
      const notParameters = {
        'custom_model',
        'generic_model',
        'bypass_status_check',
        'extensions',
      };
      final names =
          (fixture('textgen-settings-reference.json')['settingNames'] as List)
              .cast<String>();
      final preset = PresetImporter().decode({
        for (final name in names) name: 1,
      }, kindHint: PresetKind.textCompletion);
      expect(
        preset.parameters.keys.toSet(),
        names.toSet().difference(notParameters),
      );
    },
  );
}
