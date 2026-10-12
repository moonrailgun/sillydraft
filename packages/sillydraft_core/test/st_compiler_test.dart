import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

ImportedPreset chat(
  List<Map<String, dynamic>> prompts, {
  List<Map<String, dynamic>>? order,
}) => PresetImporter().decode({
  'prompts': prompts,
  'prompt_order': [
    {
      'character_id': 100000,
      'order': [
        {'identifier': 'wrong', 'enabled': true},
      ],
    },
    {
      'character_id': 100001,
      'order':
          order ??
          [
            for (final p in prompts)
              {'identifier': p['identifier'], 'enabled': true},
          ],
    },
  ],
});
Map<String, dynamic> p(
  String id,
  String content, {
  String role = 'system',
  bool marker = false,
}) => {'identifier': id, 'content': content, 'role': role, 'marker': marker};
PresetInput input(
  ImportedPreset preset, {
  CharacterCard? card,
  List<ContextScene> history = const [],
  int position = 10,
  List<ScopedWorldBook> books = const [],
  Map<String, String> locals = const {},
  String type = 'normal',
}) => PresetInput(
  preset: preset,
  branchId: 'main',
  throughPosition: position,
  brief: 'brief',
  card: card,
  userName: '阿雨',
  history: history,
  worldBooks: books,
  localVariables: locals,
  clock: DateTime.utc(2026, 10, 13),
  randomSeed: 42,
  generationType: type,
);

void main() {
  test('selected 100001 order disables absent prompts and preserves requested order', () {
    final preset = chat(
      [
        p('b', 'second'),
        p('a', 'first'),
        p('off', 'never'),
        p('wrong', 'wrong'),
      ],
      order: [
        {'identifier': 'a', 'enabled': true},
        {'identifier': 'off', 'enabled': false},
        {'identifier': 'b', 'enabled': true},
      ],
    );
    final compiled = PromptCompiler().compile(input(preset));
    expect(compiled.messages.map((m) => m.content), ['first', 'second']);
    expect(compiled.trace.any((t) => t.contains('100001')), isTrue);
  });

  test(
    'injections match actual pinned ST output including final role reversal',
    () {
      final raw = jsonDecode(
        File('test/fixtures/st/injection-reference.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final prompts = <Map<String, dynamic>>[
        p('chatHistory', '', marker: true),
      ];
      for (final (i, value) in (raw['injections'] as List).indexed) {
        prompts.add({
          'identifier': 'injection-$i',
          'injection_position': 1,
          ...value as Map<String, dynamic>,
        });
      }
      final result = PromptCompiler().compile(
        input(
          chat(prompts),
          history: [
            const ContextScene(
              branchId: 'main',
              position: 0,
              sceneId: 's',
              revisionId: 'r',
              content: 'accepted scene',
            ),
          ],
        ),
      );
      expect(
        result.messages.map((m) => {'role': m.role, 'content': m.content}),
        (raw['expected'] as List).map(
          (e) => {'role': e['role'], 'content': e['content']},
        ),
      );
    },
  );

  test(
    'card overrides use original, respect forbid and generation triggers',
    () {
      final card = CardImporter().decode(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'name': '林舟',
              'system_prompt': '{{original}} + {{char}}',
              'post_history_instructions': 'card-end',
            }),
          ),
        ),
        'card.json',
      );
      final preset = chat([
        p('main', 'base'),
        {...p('jailbreak', 'preset-end'), 'forbid_overrides': true},
        {
          ...p('conditional', 'continuing'),
          'injection_trigger': ['continue'],
        },
      ]);
      final normal = PromptCompiler().compile(input(preset, card: card));
      expect(normal.messages.map((m) => m.content), [
        'base + 林舟',
        'preset-end',
      ]);
      final continuing = PromptCompiler().compile(
        input(preset, card: card, type: 'continue'),
      );
      expect(continuing.messages.last.content, 'continuing');
    },
  );

  test('nested and scoped macros keep side effects out of unselected branches', () {
    final preset = chat([
      p(
        'main',
        '{{setvar::n::2}}{{if .n}}{{incvar::n}}{{else}}{{setvar::n::99}}{{/if}}'
            '/{{setglobalvar::g::{{getvar::n}}}}{{getglobalvar::g}}/{{getvar::n}}',
      ),
    ]);
    final request = input(preset);
    final a = PromptCompiler().compile(request);
    final b = PromptCompiler().compile(request);
    expect(a.messages.single.content, '3/3/3');
    expect(a.localVariables, {'n': '3'});
    expect(a.globalVariables, {'g': '3'});
    expect(request.localVariables, isEmpty);
    expect(b.messages.single.content, a.messages.single.content);
    expect(b.localVariables, a.localVariables);
  });

  test('history excludes future, unaccepted and other-branch material', () {
    final result = PromptCompiler().compile(
      input(
        chat([p('chatHistory', '', marker: true)]),
        position: 2,
        history: [
          const ContextScene(
            branchId: 'main',
            position: 1,
            sceneId: 's1',
            revisionId: 'r1',
            content: 'known',
          ),
          const ContextScene(
            branchId: 'main',
            position: 3,
            sceneId: 's2',
            revisionId: 'r2',
            content: 'future',
          ),
          const ContextScene(
            branchId: 'other',
            position: 0,
            sceneId: 's3',
            revisionId: 'r3',
            content: 'other',
          ),
          const ContextScene(
            branchId: 'main',
            position: 0,
            sceneId: 's4',
            revisionId: 'r4',
            content: 'candidate',
            accepted: false,
          ),
        ],
      ),
    );
    expect(result.messages.map((m) => m.content), ['known', 'brief']);
  });

  test(
    'world books recurse within budget and filter branch and availability',
    () {
      WorldBook book(List<Map<String, dynamic>> entries) => WorldBook.fromJson({
        'entries': entries,
        'recursive_scanning': true,
        'token_budget': 50,
      });
      final books = [
        ScopedWorldBook(
          book([
            {
              'id': 1,
              'keys': ['brief'],
              'content': 'harbor',
              'insertion_order': 100,
            },
            {
              'id': 2,
              'keys': ['harbor'],
              'content': 'lighthouse',
              'insertion_order': 90,
            },
            {
              'id': 3,
              'constant': true,
              'content': List.filled(500, 'x').join(),
              'insertion_order': 1,
            },
          ]),
          branchId: 'main',
        ),
        ScopedWorldBook(
          book([
            {'constant': true, 'content': 'future lore'},
          ]),
          branchId: 'main',
          availableFromPosition: 9,
        ),
        ScopedWorldBook(
          book([
            {'constant': true, 'content': 'other lore'},
          ]),
          branchId: 'other',
        ),
      ];
      final result = PromptCompiler().compile(
        input(
          chat([p('worldInfoBefore', '', marker: true)]),
          position: 2,
          books: books,
        ),
      );
      expect(result.messages.single.content, 'lighthouse\nharbor');
      expect(
        result.diagnostics.map((d) => d.code),
        contains('world_book_budget'),
      );
    },
  );

  test('regex stage and scope order do not mutate source or display-only manuscript', () {
    Map<String, dynamic> rule(
      String find,
      String replace, {
      bool prompt = false,
      bool display = false,
    }) => {
      'findRegex': find,
      'replaceString': replace,
      'placement': [2],
      'promptOnly': prompt,
      'markdownOnly': display,
      'runOnEdit': false,
      'trimStrings': ['!'],
    };
    final pipeline = RegexPipeline(
      global: [rule('/(?<word>a)!/g', r'$<word>-$0')],
      preset: [rule('/a/g', 'b')],
      card: [
        rule('/b/g', 'c'),
        rule('/c/g', 'P', prompt: true),
        rule('/c/g', 'D', display: true),
      ],
    );
    final macros = MacroEngine(values: {}, clock: DateTime.utc(2026), seed: 1);
    expect(
      pipeline.apply(
        'a!',
        placement: 2,
        stage: RegexStage.general,
        macros: macros,
      ),
      'c-c',
    );
    expect(
      pipeline.apply(
        'c-c',
        placement: 2,
        stage: RegexStage.prompt,
        macros: macros,
      ),
      'P-P',
    );
    expect(
      pipeline.apply(
        'c-c',
        placement: 2,
        stage: RegexStage.display,
        macros: macros,
      ),
      'D-D',
    );
    expect(
      pipeline.apply(
        'a!',
        placement: 2,
        stage: RegexStage.general,
        macros: macros,
        isEdit: true,
      ),
      'a!',
    );
  });

  test(
    'Handlebars conditionals render before macros with no HTML escaping',
    () {
      final template = TemplateEngine();
      final result = template.render(
        '{{#if description}}{{description}}{{else}}none{{/if}}/{{unknown}}',
        {'description': '<林舟>'},
      );
      expect(result, '<林舟>/');
      expect(
        () => template.render('{{#custom description}}x{{/custom}}', {}),
        throwsA(isA<UnsupportedTemplate>()),
      );
    },
  );

  test(
    'text completion compiles actual default templates separately from chat',
    () {
      Map<String, dynamic> load(String p) =>
          jsonDecode(File('test/fixtures/st/$p').readAsStringSync())
              as Map<String, dynamic>;
      final preset = PresetImporter().decode({
        'context': load('context/Default.json'),
        'instruct': load('instruct/ChatML.json'),
        'sysprompt': {'content': 'Write a novel'},
        'preset': {'temp': 0.8},
      });
      final result = PromptCompiler().compile(input(preset));
      final reference = load('text-format-reference.json');
      expect(result.completionText, reference['expected']);
      expect(
        result.completionText,
        contains('<|im_start|>user\nbrief<|im_end|>\n'),
      );
      expect(result.completionText, endsWith('<|im_start|>assistant\n'));
      expect(result.stopStrings, containsAll(reference['stopStrings'] as List));
      expect(result.parameters['temperature'], 0.8);
      expect(result.messages, isEmpty);
    },
  );

  test('unsupported macros and template helpers prevent silent compatibility claims', () {
    final result = PromptCompiler().compile(
      input(chat([p('main', '{{extensionMagic::x}}')])),
    );
    expect(result.diagnostics.map((d) => d.code), contains('unknown_macro'));
    expect(result.canRun, isFalse);
    expect(result.messages.single.content, '{{extensionMagic::x}}');
  });

  test(
    'variable arithmetic follows ST concatenation and JSON-array behavior',
    () {
      final macro = MacroEngine(values: {}, clock: DateTime.utc(2026), seed: 1);
      expect(macro.render('{{setvar::s::text}}{{incvar::s}}'), 'text1');
      expect(
        macro.render('{{setvar::a::[1]}}{{addvar::a::x}}{{getvar::a}}'),
        '[1,"x"]',
      );
      expect(macro.render('{{setvar::n::}}{{addvar::n::2}}{{getvar::n}}'), '2');
    },
  );

  test('official chat markers honor formatting and new-chat delimiter', () {
    final raw = jsonDecode(
      File('test/fixtures/st/openai/Default.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    raw['personality_format'] = '性格：{{personality}}';
    final card = CardImporter().decode(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({'name': '林舟', 'personality': '谨慎', 'scenario': '渡口'}),
        ),
      ),
      'card.json',
    );
    final result = PromptCompiler().compile(
      input(PresetImporter().decode(raw), card: card),
    );
    expect(result.messages.map((m) => m.content), contains('性格：谨慎'));
    expect(
      result.messages.map((m) => m.content),
      contains('[Start a new Chat]'),
    );
  });
}
