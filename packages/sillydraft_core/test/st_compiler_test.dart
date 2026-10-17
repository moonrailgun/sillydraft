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
  List<ContextChapter> history = const [],
  int position = 10,
  List<ScopedWorldBook> books = const [],
  Map<String, String> locals = const {},
  String type = 'normal',
  int? contextWindow,
  int? maxOutputTokens,
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
  contextWindow: contextWindow,
  maxOutputTokens: maxOutputTokens,
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
            const ContextChapter(
              branchId: 'main',
              position: 0,
              chapterId: 's',
              revisionId: 'r',
              content: 'accepted chapter',
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
          const ContextChapter(
            branchId: 'main',
            position: 1,
            chapterId: 's1',
            revisionId: 'r1',
            content: 'known',
          ),
          const ContextChapter(
            branchId: 'main',
            position: 3,
            chapterId: 's2',
            revisionId: 'r2',
            content: 'future',
          ),
          const ContextChapter(
            branchId: 'other',
            position: 0,
            chapterId: 's3',
            revisionId: 'r3',
            content: 'other',
          ),
          const ContextChapter(
            branchId: 'main',
            position: 0,
            chapterId: 's4',
            revisionId: 'r4',
            content: 'candidate',
            accepted: false,
          ),
        ],
      ),
    );
    expect(result.messages.map((m) => m.content), ['known', 'brief']);
  });

  test('the card\'s book and the work\'s books are scanned together within a quarter of the prompt size', () {
    // ST scans every message as "name: text", recurses across all books
    // and ignores a book's own `token_budget` and `recursive_scanning`.
    final card = CardImporter().decode(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'name': '苏雾',
            'character_book': {
              'token_budget': 1,
              'entries': [
                {
                  'id': 1,
                  'keys': ['阿雨'],
                  'content': 'harbor',
                  'insertion_order': 100,
                  'enabled': true,
                  'position': 'before_char',
                },
                {
                  'id': 2,
                  'keys': ['lighthouse'],
                  'content': '灯塔',
                  'insertion_order': 50,
                  'enabled': true,
                  'position': 'before_char',
                },
              ],
            },
          }),
        ),
      ),
      'card.json',
    );
    ScopedWorldBook book(
      Map<String, dynamic> entries, {
      String branchId = 'main',
      int from = 0,
    }) => ScopedWorldBook(
      WorldBook.fromJson({
        'entries': entries,
        'recursive_scanning': false,
        'token_budget': 1,
      }),
      branchId: branchId,
      availableFromPosition: from,
    );
    final books = [
      book({
        '1': {
          'uid': 1,
          'key': ['harbor'],
          'content': 'lighthouse',
          'order': 90,
          'position': 0,
        },
        '2': {
          'uid': 2,
          'constant': true,
          'content': List.filled(500, 'x').join(),
          'order': 1,
          'position': 0,
        },
      }),
      book({
        '1': {'uid': 1, 'constant': true, 'content': 'future lore'},
      }, from: 9),
      book({
        '1': {'uid': 1, 'constant': true, 'content': 'other lore'},
      }, branchId: 'other'),
    ];
    CompiledPrompt compile(int contextWindow) => PromptCompiler().compile(
      input(
        chat([p('worldInfoBefore', '', marker: true)]),
        card: card,
        position: 2,
        history: const [
          ContextChapter(
            branchId: 'main',
            position: 1,
            chapterId: 's1',
            revisionId: 'r1',
            content: 'known',
          ),
        ],
        books: books,
        contextWindow: contextWindow,
        maxOutputTokens: 2000,
      ),
    );
    final roomy = compile(4000);
    expect(
      roomy.messages.single.content,
      '${List.filled(500, 'x').join()}\n灯塔\nlighthouse\nharbor',
    );
    expect(
      roomy.diagnostics.where((d) => d.code.startsWith('world_book')),
      isEmpty,
    );
    // 25% of 400: the long entry overflows, which ends recursion too.
    final tight = compile(2400);
    expect(tight.messages.single.content, 'harbor');
    expect(
      tight.diagnostics
          .where((d) => d.code == 'world_book_budget')
          .map((d) => d.message),
      ['世界书条目 2 超出所有世界书共用的预算（100 token，即提示词上限的 25%），未放入'],
    );
  });

  group('world info budget', () {
    WorldBookResult activate(
      List<WorldBook> books, {
      required int? budget,
      MacroEngine? macros,
      WorldBook? characterBook,
    }) => WorldBookEngine().activate(
      [for (final book in books) ScopedWorldBook(book)],
      characterBook: characterBook,
      branchId: 'main',
      throughPosition: 0,
      messages: const ['开场'],
      macros:
          macros ?? MacroEngine(values: {}, clock: DateTime.utc(2026), seed: 1),
      seed: 1,
      budget: budget,
    );

    test('one budget for all books stops at the first overflow', () {
      final macros = MacroEngine(
        values: {},
        clock: DateTime.utc(2026),
        seed: 1,
      );
      final result = activate(
        [
          WorldBook.fromJson({
            'token_budget': 1,
            'recursive_scanning': true,
            'entries': [
              // Running count (CJK 1.5, newline 0.34, rounded up) after the
              // card's 丁: 6; the next book's 戊 (order 100) makes it 8.
              {'uid': 1, 'constant': true, 'content': '甲甲', 'order': 100},
              {
                'uid': 2,
                'constant': true,
                'content': '忽略',
                'order': 90,
                'ignoreBudget': true,
              },
              // 15.2 → 16, not under 12: overflows, its macros still ran.
              {
                'uid': 3,
                'constant': true,
                'content': '{{setvar::x::1}}乙乙乙',
                'order': 80,
              },
              // Would fit, but ST stops at the first overflow.
              {'uid': 4, 'constant': true, 'content': '丙', 'order': 70},
              // Recursion stops at an overflow.
              {
                'uid': 6,
                'key': ['甲甲'],
                'content': '递归',
                'order': 10,
                'ignoreBudget': true,
              },
            ],
          }),
          WorldBook.fromJson({
            'entries': [
              {'uid': 11, 'constant': true, 'content': '戊', 'order': 100},
              {
                'uid': 12,
                'constant': true,
                'content': '己',
                'order': 50,
                'ignoreBudget': true,
              },
            ],
          }),
        ],
        budget: 12,
        macros: macros,
        // A card's book: `extensions.ignore_budget`. Scanned first, then the
        // other books' entries together by order.
        characterBook: WorldBook.fromJson({
          'entries': [
            {
              'id': 5,
              'keys': <String>[],
              'constant': true,
              'enabled': true,
              'content': '丁',
              'insertion_order': 60,
              'extensions': {'ignore_budget': true},
            },
          ],
        }),
      );
      expect(result.before, '己\n忽略\n戊\n甲甲');
      expect(result.after, '丁');
      expect(result.diagnostics.map((d) => (d.code, d.message)), [
        for (final id in ['3', '4'])
          (
            'world_book_budget',
            '世界书条目 $id 超出所有世界书共用的预算（12 token，即提示词上限的 25%），未放入',
          ),
      ]);
      expect(macros.local, {'x': '1'});
      // No request size: no budget.
      expect(
        activate([
          WorldBook.fromJson({
            'token_budget': 1,
            'entries': [
              {'uid': 1, 'constant': true, 'content': '甲甲'},
            ],
          }),
        ], budget: null).before,
        '甲甲',
      );
    });

    test('equal orders keep the book order and land as ST places them', () {
      const names = '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥金木水火土日月星天地玄黄宇宙洪荒风云雷';
      final result = activate(
        [
          WorldBook.fromJson({
            'entries': [
              for (final (i, name) in names.split('').indexed)
                {'uid': i, 'constant': true, 'content': name},
            ],
          }),
        ],
        // Ten entries of 1.84 each fit under 20, the eleventh does not.
        budget: 20,
      );
      // world-info.js L5202-5217: sorted by order (stably), each put at the
      // start of its position, so equal orders end up reversed.
      expect(
        result.before,
        names.split('').take(10).toList().reversed.join('\n'),
      );
      expect(
        result.diagnostics.where((d) => d.code == 'world_book_budget').length,
        names.length - 10,
      );
    });
  });

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

  group('text completion prompts are what ST Generate builds', () {
    // Expected texts come from the pinned ST 1.19.0 script.js `Generate`,
    // its text completion path run verbatim, for the same chat: two
    // chapters as the character's messages, then the brief as the user's.
    Map<String, dynamic> load(String p) =>
        jsonDecode(File('test/fixtures/st/$p').readAsStringSync())
            as Map<String, dynamic>;
    final chatml = load('instruct/ChatML.json');
    final context = load('context/Default.json');
    const system = {'content': '写{{char}}', 'post_history': '后{{user}}'};
    PresetInput text(
      Map<String, dynamic> bundle, {
      bool chapters = true,
    }) => PresetInput(
      preset: PresetImporter().decode({
        'preset': {'temp': 1},
        ...bundle,
      }),
      branchId: 'main',
      throughPosition: 10,
      brief: '写第三章',
      userName: '阿雨',
      card: CardImporter().decode(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'name': '道渊',
              'description': '描述',
              'personality': '冷静',
              'scenario': '山中',
              'mes_example':
                  '<START>\n{{user}}: 你好\n{{char}}: 嗯。\n<START>\n{{char}}: 走吧',
            }),
          ),
        ),
        'card.json',
      ),
      history: [
        if (chapters)
          for (final (i, content) in ['第一章\n山路', '第二章'].indexed)
            ContextChapter(
              branchId: 'main',
              position: i,
              chapterId: 'c$i',
              revisionId: 'r$i',
              content: content,
            ),
      ],
      clock: DateTime.utc(2026, 10, 13),
      randomSeed: 42,
    );
    String prompt(Map<String, dynamic> bundle, {bool chapters = true}) =>
        PromptCompiler()
            .compile(text(bundle, chapters: chapters))
            .completionText!;

    test('card examples follow the story string as {{mesExamples}}', () {
      // script.js L4616-4661, L5021: parseMesExamples blocks, under the
      // example separator, or formatInstructModeExamples in instruct mode
      // (the user's name with `force`); `skip_examples` keeps the blocks
      // unformatted instead of dropping them.
      expect(
        prompt({}),
        contains('山中\n***\n阿雨: 你好\n道渊: 嗯。\n***\n道渊: 走吧\n***\n道渊: 第一章'),
      );
      expect(
        prompt({'instruct': chatml, 'context': context}),
        contains(
          '<|im_end|>\n***\n<|im_start|>user\n阿雨: 你好<|im_end|>\n'
          '<|im_start|>assistant\n嗯。<|im_end|>\n***\n'
          '<|im_start|>assistant\n走吧<|im_end|>\n***\n'
          '<|im_start|>assistant\n第一章',
        ),
      );
      expect(
        prompt({
          'instruct': {...chatml, 'skip_examples': true},
          'context': context,
        }),
        contains(
          '<|im_end|>\n***\n阿雨: 你好\n道渊: 嗯。\n***\n道渊: 走吧\n***\n'
          '<|im_start|>assistant\n第一章',
        ),
      );
    });

    test('a normal generation ends as Generate\'s last prompt line', () {
      // L4994-5011, `modifyLastPromptLine` L5028-5091: the last message
      // loses its line break, then the character's name follows
      // (`always_force_name2`, on unless the context template turns it
      // off) or, in instruct mode, `formatInstructModePrompt`. The
      // post-history instructions are an unnamed user message (L4748-4765).
      expect(prompt({}), endsWith('道渊: 第二章\n阿雨: 写第三章\n道渊:'));
      expect(prompt({'sysprompt': system}), endsWith('阿雨: 写第三章\n后阿雨\n道渊:'));
      expect(
        prompt({
          'context': {...context, 'always_force_name2': false},
        }),
        endsWith('道渊: 第二章\n阿雨: 写第三章'),
      );
      // The first message takes the first sequence, the last user message
      // the last one; the user alignment message opens a chat that does
      // not start with the user (L4767-4827, L4929-4936).
      final sequences = {
        ...chatml,
        'first_input_sequence': '<fi {{name}}>',
        'last_input_sequence': '<li {{name}}>',
        'first_output_sequence': '<fo {{name}}>',
        'last_output_sequence': '<lo {{name}}>',
        'user_alignment_message': '开始吧{{char}}',
      };
      expect(
        prompt({
          'instruct': sequences,
          'context': context,
          'sysprompt': system,
        }),
        endsWith(
          '***\n<fi 阿雨>\n开始吧道渊<|im_end|>\n<fo 道渊>\n第一章\n山路<|im_end|>\n'
          '<|im_start|>assistant\n第二章<|im_end|>\n'
          '<|im_start|>user\n写第三章<|im_end|>\n'
          '<li System>\n后阿雨<|im_end|>\n<lo 道渊>\n',
        ),
      );
      expect(
        prompt({
          'instruct': sequences,
          'context': context,
          'sysprompt': system,
        }, chapters: false),
        endsWith(
          '***\n<fi 阿雨>\n写第三章<|im_end|>\n'
          '<li System>\n后阿雨<|im_end|>\n<lo 道渊>\n',
        ),
      );
      // Names with `always`, after the space the output sequence ends with
      // (Mistral's).
      expect(
        prompt({
          'instruct': {
            ...chatml,
            'input_sequence': '[INST] ',
            'output_sequence': '[/INST] ',
            'last_output_sequence': '[/INST]',
            'input_suffix': '',
            'output_suffix': '</s>',
            'wrap': false,
            'names_behavior': 'always',
          },
          'context': context,
        }),
        endsWith('</s>[INST] 阿雨: 写第三章[/INST] 道渊:'),
      );
    });

    test('a partial instruct template keeps a fresh install\'s values', () {
      // instruct-mode.js L826-857: a field the template and its migration
      // lack keeps the previous template's, the fresh install's Alpaca
      // (default/content/settings.json).
      final partial = text({
        'instruct': {'input_sequence': '<in>', 'output_suffix': '</out>'},
        'context': context,
      });
      expect(partial.env.instruct, containsPair('wrap', true));
      expect(partial.env.instruct, containsPair('macro', true));
      expect(
        partial.env.instruct,
        containsPair('output_sequence', '### Response:'),
      );
      expect(
        PromptCompiler().compile(partial).completionText,
        '描述\n冷静\n山中\n***\n<in>\n阿雨: 你好\n### Response:\n嗯。</out>***\n'
        '### Response:\n走吧</out>***\n### Response:\n第一章\n山路</out>'
        '### Response:\n第二章</out><in>\n写第三章\n### Response:\n',
      );
    });
  });

  test('text completion presets read the response length from genamt', () {
    // ST 1.19.0 preset-manager.js L744-747 saves the response length as
    // `genamt` and the context size as `max_length`; script.js
    // `setGenerationParamsFromPreset` L8121-8135 reads them back. NovelAI's
    // own presets (no `genamt`) keep it in `max_length`, the context in
    // `max_context` (nai-settings.js `loadNovelPreset` L177-183).
    PresetInput text(Map<String, dynamic> parameters) => PresetInput(
      preset: PresetImporter().decode({
        'context': {'story_string': '{{system}}'},
        'sysprompt': {'content': '{{maxResponse}}|{{maxContext}}'},
        'preset': {'temp': 0.8, ...parameters},
      }),
      branchId: 'main',
      throughPosition: 10,
      brief: 'brief',
      clock: DateTime.utc(2026, 10, 13),
      randomSeed: 42,
      contextWindow: 16000,
      maxOutputTokens: 2048,
    );
    final saved = PromptCompiler().compile(
      text({'genamt': 350, 'max_length': 8192}),
    );
    expect(saved.parameters['max_tokens'], 350);
    expect(saved.completionText, startsWith('350|16000'));
    // The context size is the connection's, as for `openai_max_context`.
    expect(
      PromptCompiler().compile(text({'max_length': 8192})).parameters,
      isNot(contains('max_tokens')),
    );
    expect(text({'max_length': 8192}).env.maxResponse, 2048);
    final novel = text({'max_length': 150, 'max_context': 7800});
    expect(novel.env.maxResponse, 150);
    expect(PromptCompiler().compile(novel).parameters['max_tokens'], 150);
  });

  test('unknown macros stay as written and warn without blocking', () {
    final result = PromptCompiler().compile(
      input(chat([p('main', '{{extensionMagic::x}}')])),
    );
    final diagnostic = result.diagnostics.singleWhere(
      (d) => d.code == 'unknown_macro',
    );
    expect(diagnostic.severity, DiagnosticSeverity.warning);
    expect(result.canRun, isTrue);
    expect(result.messages.single.content, '{{extensionMagic::x}}');
  });

  test('unclosed macros stay as written and warn without blocking', () {
    final result = PromptCompiler().compile(
      input(chat([p('main', '{{char 的状态 {{user}}')])),
    );
    final diagnostic = result.diagnostics.singleWhere(
      (d) => d.code == 'unclosed_macro',
    );
    expect(diagnostic.severity, DiagnosticSeverity.warning);
    expect(result.canRun, isTrue);
    expect(result.messages.single.content, '{{char 的状态 阿雨');
  });

  test('malformed setvar warns without blocking prompt compilation', () {
    final result = PromptCompiler().compile(
      input(
        chat([
          p('main', '{{setvar::体型差:}}{{setvar::next::ok}}{{getvar::next}}'),
        ]),
        locals: {'体型差': 'unchanged'},
      ),
    );
    expect(result.canRun, isTrue);
    expect(result.messages.single.content, '{{setvar::体型差:}}ok');
    expect(result.localVariables, {'体型差': 'unchanged', 'next': 'ok'});
    final diagnostic = result.diagnostics.singleWhere(
      (d) => d.code == 'invalid_macro_arguments',
    );
    expect(diagnostic.severity, DiagnosticSeverity.warning);
    expect(diagnostic.message, contains('{{setvar::体型差:}}'));
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
