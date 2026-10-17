import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

// Expected outputs were checked against the pinned ST 1.19.0 macro engine
// (06bde939fb1e9c4c8d8641d810f0a916b5bce127, chevrotain 11.2.0) with `user`
// as a zero-argument macro.

MacroEngine _engine() => MacroEngine(
  env: const MacroEnv(user: '阿雨', char: '道渊'),
  clock: DateTime.utc(2026),
  seed: 1,
  local: const {'mood': '平静', 'x-y': '7'},
  global: const {'theme': 'dark'},
);

/// Renders [source] and returns the output with the diagnostic codes.
(String, String) _run(String source) {
  final engine = _engine();
  final text = engine.render(source);
  return (text, engine.diagnostics.map((d) => d.code).join(','));
}

/// [_run] with each macro result wrapped in brackets by `transform`.
(String, String) _wrapped(String source) {
  final engine = _engine();
  final text = engine.render(source, transform: (x) => '[$x]');
  return (text, engine.diagnostics.map((d) => d.code).join(','));
}

void main() {
  group('identifier grammar', () {
    test('braces without a macro head are plain text', () {
      for (final source in [
        '{{角色的境界}}',
        '{{当前生命值，0-100的数字}}',
        '{{ 123 }}',
        '{{}}',
        '{{ }}',
        '{{_abc}}',
        '{{.角色}}',
        '{{.1}}',
        '{{.mood:x}}',
        '{{!角色}}',
        '{{/角色}}',
        '{{角色',
        'a {{ 1',
      ]) {
        expect(_run(source), (source, ''), reason: source);
      }
    });

    test('macros nested in plain braces still resolve', () {
      expect(_run('{{角色 {{user}}}}'), ('{{角色 阿雨}}', ''));
      expect(_run('{{ {{char}} }}'), ('{{ 道渊 }}', ''));
      // A `{` before `{{` is plain text (ST Plaintext.OpenBrace).
      expect(_run('{{{user}}}'), ('{阿雨}', ''));
      expect(_run('{{{{user}}}}'), ('{{阿雨}}', ''));
      // Inside arguments an invalid `{{` does not nest, so the first `}}`
      // closes the macro.
      expect(_run('{{reverse::{{角色}}}}'), ('色角{{}}', ''));
    });

    test('names are case-insensitive and may be padded', () {
      expect(_run('{{USER}}/{{ char }}/{{Space::2}}|'), ('阿雨/道渊/  |', ''));
    });

    test('text after the name up to whitespace, `:` or `|` is dropped', () {
      final (text, codes) = _run('{{user的}}');
      expect(text, '阿雨');
      expect(codes, 'macro_syntax');
    });

    test('comments and variable shorthand reads', () {
      expect(_run('[{{// note}}{{//x}}{{comment a::b}}]'), ('[]', ''));
      expect(
        _run(
          r'{{.mood}}/{{ . mood }}/{{.x-y}}/{{$theme}}/[{{.missing}}][{{.}}]',
        ),
        // `{{.}}` reads an inserted empty name, with ST's syntax warning.
        ('平静/平静/7/dark/[][]', 'macro_syntax'),
      );
      expect(_run('{{.mood-}}'), ('{{.mood-}}', ''));
    });

    test('an unclosed macro stays as written with a warning', () {
      final engine = _engine();
      expect(engine.render('a {{user b'), 'a {{user b');
      final diagnostic = engine.diagnostics.single;
      expect(diagnostic.code, 'unclosed_macro');
      expect(diagnostic.severity, DiagnosticSeverity.warning);
      expect(diagnostic.message, '宏缺少结束的 }}；保留原文：{{user b');
      final long = _engine()..render('{{user ${'长' * 50}');
      expect(
        long.diagnostics.single.message,
        '宏缺少结束的 }}；保留原文：{{user ${'长' * 33}…',
      );
    });

    test('closed macros inside an unclosed one still resolve', () {
      // MacroCstWalker `#flattenIncompleteMacro`: the unclosed macro runs to
      // the end and is text; the closed macros in it are evaluated in its
      // place, pairing as scoped macros at that level.
      for (final (source, text) in [
        ('{{user', '{{user'),
        ('{{user::a', '{{user::a'),
        ('{{', '{{'),
        ('{{user}} {{char', '阿雨 {{char'),
        ('{{char {{user}}', '{{char 阿雨'),
        ('{{user}} x {{a {{user}} y {{char}}', '阿雨 x {{a 阿雨 y 道渊'),
        ('{{reverse::{{user}}', '{{reverse::阿雨'),
        ('{{a::{{b {{user}}', '{{a::{{b 阿雨'),
        ('{{.x = {{user}}', '{{.x = 阿雨'),
        ('{{// {{user}}', '{{// 阿雨'),
        ('{{user {{.n++}}{{.n++}}', '{{user 12'),
        ('{{a {{if 1}}x{{/if}} y', '{{a x y'),
        ('{{a {{user}} {{/a}}', '{{a 阿雨 {{/a}}'),
        ('{{if 1}}a{{b {{/if}} c', 'a{{b c'),
        ('{{reverse}}ab{{c {{/reverse}}', 'c{{ba'),
        ('{{a}} {{b {{/a}}', '{{a}}{{b}}'),
        // `splitOnTopLevelElse` sees only top-level macros.
        ('{{if 1}}a{{b {{else}}c{{/if}}', 'a{{b c'),
        ('{{if 0}}a{{b {{else}}c{{/if}}', ''),
        ('{{if 1}}a{{else {{/if}}', 'a{{else'),
        ('{{if 1}}x{{/if', '{{if 1}}x{{/if'),
        // Characters the lexer skips after a name never open a macro.
        ('{{a{{user}} b', '{{a{{user}} b'),
        ('{{user{{char}}}}', '阿雨}}'),
      ]) {
        expect(_run(source).$1, text, reason: source);
      }
    });
  });

  group('registry arity', () {
    test('wrong argument counts keep the text and warn', () {
      for (final source in [
        '{{user::x}}',
        '{{user x}}',
        '{{user:}}',
        '{{user|upper}}',
        '{{noop::x}}',
        '{{reverse}}',
        '{{reverse::a::b}}',
        '{{roll}}',
        '{{//}}',
        '{{comment}}',
        '{{date::x}}',
        '{{getvar}}',
        '{{setvar::x}}',
        '{{space::2::3}}',
        '{{if}}',
        '{{get_message_variable}}',
      ]) {
        expect(_run(source), (
          source,
          'invalid_macro_arguments',
        ), reason: source);
      }
    });

    test('kept text has nested macros resolved', () {
      expect(_run('{{reverse::{{user}}::x}}'), (
        '{{reverse::阿雨::x}}',
        'invalid_macro_arguments',
      ));
      expect(_run('{{ mystery :: {{user}} }}'), (
        '{{ mystery :: 阿雨 }}',
        'unknown_macro',
      ));
    });

    test('an unknown macro stays as written with a warning', () {
      // ST keeps it silently; SillyDraft warns without blocking.
      final engine = _engine();
      expect(engine.render('{{NPC::{{user}}}}'), '{{NPC::阿雨}}');
      final diagnostic = engine.diagnostics.single;
      expect(diagnostic.code, 'unknown_macro');
      expect(diagnostic.severity, DiagnosticSeverity.warning);
      expect(diagnostic.message, '未支持的宏 NPC；保留原文：{{NPC::阿雨}}');
    });

    test('space and newline take an optional integer count', () {
      expect(_run('[{{space}}][{{space::3}}][{{newline:: 2 }}]'), (
        '[ ][   ][\n\n]',
        '',
      ));
      for (final source in [
        '{{space::abc}}',
        '{{newline::1.5}}',
        '{{space::-1}}',
      ]) {
        expect(_run(source), (
          source,
          'invalid_macro_arguments',
        ), reason: source);
      }
    });

    test('list and zero-argument core macros', () {
      expect(_run('[{{random}}][{{random::}}][{{else}}][{{noop}}]'), (
        '[][][][]',
        '',
      ));
    });

    test('variable macros answer to ST names and aliases only', () {
      expect(
        _run(
          '{{hasvar::mood}}{{varexists::none}}{{globalvarexists::theme}}'
          '{{flushglobalvar::theme}}{{hasglobalvar::theme}}',
        ),
        ('truefalsetruefalse', ''),
      );
      expect(_run('{{getvarglobal::theme}}'), (
        '{{getvarglobal::theme}}',
        'unknown_macro',
      ));
    });

    test('酒馆助手 variable macros take the whole path', () {
      final engine = MacroEngine(
        values: const {},
        clock: DateTime.utc(2026),
        seed: 1,
        local: encodeVariables({
          'a::b': '冒号',
          'stat': {'hp': 3},
        }),
      );
      expect(engine.render('{{get_message_variable::a::b}}'), '冒号');
      expect(engine.render('{{GET_CHAT_VARIABLE::stat.hp}}'), '3');
      expect(engine.diagnostics, isEmpty);
    });
  });

  group('if', () {
    test('takes a condition and content, inline or scoped', () {
      expect(_run('{{if::mood::yes}}|{{if::0::yes}}'), ('yes|', ''));
      expect(_run('{{if::0::a{{else}}b}}'), ('b', ''));
      expect(_run('{{if mood}} a {{else}} b {{/if}}'), ('a', ''));
      expect(_run('{{if 1}}{{if 0}}x{{else}}y{{/if}}{{else}}z{{/if}}'), (
        'y',
        '',
      ));
      expect(_run('{{IF 1}}A{{/IF}}'), ('A', ''));
      // Only a lower-case `else` splits; `ELSE` renders as nothing.
      expect(_run('{{if 1}}A{{ELSE}}B{{/if}}'), ('AB', ''));
    });

    test('an else argument or a missing closing tag keeps the text', () {
      for (final source in [
        '{{if::1::a::b}}',
        '{{if::0::a::b}}',
        '{{if mood}}',
        '{{if mood::a}}',
      ]) {
        expect(_run(source), (
          source,
          'invalid_macro_arguments',
        ), reason: source);
      }
    });

    test('inline ifs do not take a closing tag', () {
      expect(_run('{{if 1}}x{{if::1::c}}y{{/if}}'), ('xcy', ''));
    });

    test('scoped trim', () {
      expect(_run('a\n{{trim}}\nb|{{trim}} x {{/trim}}|[{{trim::x}}]'), (
        'ab|x|[]',
        '',
      ));
    });

    test('a registered macro without required arguments is resolved', () {
      for (final (source, expected) in [
        ('{{if user}}y{{else}}n{{/if}}', 'y'),
        ('{{if USER}}y{{/if}}', 'y'),
        ('{{if !user}}y{{else}}n{{/if}}', 'n'),
        // These resolve to nothing; `random` takes a list of none.
        ('{{if noop}}y{{else}}n{{/if}}', 'n'),
        ('{{if trim}}y{{else}}n{{/if}}', 'n'),
        ('{{if else}}y{{else}}n{{/if}}', 'n'),
        ('{{if random}}y{{else}}n{{/if}}', 'n'),
        ('{{setvar::c::trim}}{{if {{getvar::c}}}}y{{else}}n{{/if}}', 'n'),
        ('{{setvar::c::  user  }}{{if {{getvar::c}}}}y{{else}}n{{/if}}', 'y'),
        // Macros that need arguments, and other names, are plain values.
        ('{{if roll}}y{{else}}n{{/if}}', 'y'),
        ('{{if comment}}y{{else}}n{{/if}}', 'y'),
        ('{{if //}}y{{else}}n{{/if}}', 'y'),
        ('{{if mood}}y{{else}}n{{/if}}', 'y'),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
      expect(_run('{{if !authorsNote}}y{{else}}n{{/if}}'), ('y', ''));
      // Card fields are env macros: empty without a card.
      expect(_run('{{if charVersion}}y{{else}}n{{/if}}'), ('n', ''));
      expect(_run('{{if !description}}y{{else}}n{{/if}}'), ('y', ''));
    });

    test('only empty, off, false and 0 are false', () {
      for (final (source, expected) in [
        ('{{if no}}y{{else}}n{{/if}}', 'y'),
        ('{{if off}}y{{else}}n{{/if}}', 'n'),
        ('{{if FALSE}}y{{else}}n{{/if}}', 'n'),
        ('{{if 0}}y{{else}}n{{/if}}', 'n'),
        ('{{if ! 0}}y{{else}}n{{/if}}', 'y'),
        ('{{if !}}y{{else}}n{{/if}}', 'y'),
        ('{{if !!0}}y{{else}}n{{/if}}', 'n'),
        ('{{if {{space}}}}y{{else}}n{{/if}}', 'y'),
        ('{{setvar::c::  false }}{{if {{getvar::c}}}}y{{else}}n{{/if}}', 'n'),
        (r'{{if \{}}y{{else}}n{{/if}}', 'y'),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
    });

    test('a resolved .name or \$name reads the variable', () {
      for (final (source, expected) in [
        ('{{if .mood}}y{{else}}n{{/if}}', 'y'),
        ('{{if .none}}y{{else}}n{{/if}}', 'n'),
        (r'{{if $theme}}y{{else}}n{{/if}}', 'y'),
        (r'{{if $none}}y{{else}}n{{/if}}', 'n'),
        ('{{if !.none}}y{{else}}n{{/if}}', 'y'),
        ('{{setvar::c::.mood}}{{if {{getvar::c}}}}y{{else}}n{{/if}}', 'y'),
        // Not a shorthand, so a non-empty value.
        ('{{if . none}}y{{else}}n{{/if}}', 'y'),
        ('{{if .x-}}y{{else}}n{{/if}}', 'y'),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
    });

    test('the chosen branch is trimmed and dedented unless #', () {
      expect(_run('{{if 1}}\n  a\n    b\n{{/if}}'), ('a\n  b', ''));
      expect(_run('{{if 0}}{{else}}  \n  a\n    b{{/if}}'), ('a\n  b', ''));
      expect(_run('{{#if 1}} x {{/if}}|{{#IF 0}} x {{else}} y {{/IF}}'), (
        ' x | y ',
        '',
      ));
      expect(_run('{{#if::1:: a {{else}} b}}|{{if 1}} a {{#/if}}'), (
        'a |a',
        '',
      ));
    });
  });

  group('flags', () {
    test('! ? ~ > and # do not change how a macro resolves', () {
      expect(
        _run('{{!user}}{{?user}}{{~user}}{{>user}}{{#user}}{{ ! ? user }}'),
        ('阿雨阿雨阿雨阿雨阿雨阿雨', ''),
      );
      expect(_run(r'{{!.mood}}{{/.mood}}{{#$theme}}'), ('平静平静dark', ''));
      expect(_run('{{?setvar::a::1}}{{~getvar::a}}'), ('1', ''));
      expect(_run('{{!if 1}}a{{/if}}'), ('a', ''));
      expect(_run('{{!foo}}'), ('{{!foo}}', 'unknown_macro'));
      expect(_run('{{>user|upper}}'), (
        '{{>user|upper}}',
        'invalid_macro_arguments',
      ));
    });
  });

  group('scoped macros', () {
    test('content becomes the last argument of any macro', () {
      for (final (source, expected) in [
        ('{{setvar::x}}multi\nline{{/setvar}}[{{getvar::x}}]', '[multi\nline]'),
        ('{{setvar::x}}a{{/SETVAR}}[{{getvar::x}}]', '[a]'),
        ('{{setvar::x}}{{/setvar}}[{{getvar::x}}]', '[]'),
        ('{{getvar}}mood{{/getvar}}', '平静'),
        ('{{reverse}}{{user}}{{/reverse}}', '雨阿'),
        ('{{newline}}2{{/newline}}|', '\n\n|'),
        ('{{trim}}a{{trim}}b{{/trim}}c{{/trim}}', 'abc'),
        ('{{if 1}}{{trim}} x {{/trim}}{{/if}}', 'x'),
        ('{{reverse::{{trim}} ab {{/trim}}}}', 'ba'),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
    });

    test('content is trimmed and dedented unless #', () {
      for (final (source, expected) in [
        (
          '{{setvar::x}}\n    a\n      b\n    c\n{{/setvar}}[{{getvar::x}}]',
          '[a\n  b\nc]',
        ),
        ('{{#setvar::x}}  a  {{/setvar}}[{{getvar::x}}]', '[  a  ]'),
        ('{{trim}}\n\n   a\n  b\n    c\n\n{{/trim}}', 'a\nb\n c'),
        ('{{trim}}   \n  a\n b{{/trim}}', 'a\nb'),
        ('{{trim}}\r\n  a\r\n  b\r\n{{/trim}}', 'a\r\nb'),
        ('{{trim}}\n\t a\n\t  b{{/trim}}', 'a\n b'),
        ('{{#trim}} x {{/trim}}', ' x '),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
    });

    test('an opener that cannot take content keeps both tags', () {
      for (final source in [
        '{{trim::x}}a{{/trim}}',
        '{{trim::{{user}}}}a{{/trim}}',
        '{{user}}x{{/user}}',
        '{{random}}a{{/random}}',
        '{{noop}}x{{/noop}}',
        '{{if::1::c}}y{{/if}}',
        '{{if}}x{{/if}}',
        // The opener is not evaluated.
        '{{reverse::{{setvar::a::1}}}}x{{/reverse}}[{{getvar::a}}]',
      ]) {
        expect(_run(source).$1, source.replaceAll('{{getvar::a}}', ''));
        expect(_run(source).$2, '', reason: source);
      }
      // A closing tag paired that way is not used again.
      expect(_run('{{trim::x}}{{trim::y}}a{{/trim}}'), (
        '{{trim::x}}a{{/trim}}',
        '',
      ));
    });

    test('closing tags pair by name and nesting; stray ones stay text', () {
      for (final (source, expected) in [
        ('{{/if}}|a{{/IF}}b|{{#/if}}', '{{/if}}|a{{/IF}}b|{{#/if}}'),
        ('{{if 1}}a{{/if}}{{/if}}', 'a{{/if}}'),
        ('{{/trim}}{{trim}}x{{/trim}}', '{{/trim}}x'),
        ('{{if 1}}a{{!/if}}|{{if 1}}b{{/ if}}|{{if 1}}c{{/if::x}}', 'a|b|c'),
        ('{{if 1}}a{{if 0}}b{{/if}}c{{/if}}', 'ac'),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
      // The inner `if` pairs; the outer one lacks its content.
      expect(_run('{{if 1}}{{if 1}}x{{/if}}'), (
        '{{if 1}}x',
        'invalid_macro_arguments',
      ));
    });

    test('{{//}} blocks are comments', () {
      for (final (source, expected) in [
        ('a{{//}}comment{{///}}b', 'ab'),
        ('a{{//}}x{{///y}}b|{{//}}x{{// /}}', 'ab|'),
        ('{{//}}a{{//}}b{{///}}c{{///}}d', 'd'),
        ('{{comment}}a{{/comment}}', ''),
        // ST evaluates the content before dropping it.
        ('{{//}}{{setvar::a::1}}{{///}}[{{getvar::a}}]', '[1]'),
        // `{{///}}` and `{{// /…}}` are closing tags.
        (
          '{{///}}|{{//::/x}}|{{// {{user}}/}}',
          '{{///}}|{{//::/x}}|{{// {{user}}/}}',
        ),
        ('a{{// note}}x{{///}}b', 'a{{// note}}x{{///}}b'),
      ]) {
        expect(_run(source), (expected, ''), reason: source);
      }
    });

    test('a kept scoped macro reads as ST rawInner', () {
      expect(_run('{{foo}}x{{/foo}}'), ('{{foo}}x}}', 'unknown_macro'));
      expect(_run('{{!foo}}{{user}}{{/foo}}'), (
        '{{!foo}}阿雨}}',
        'unknown_macro',
      ));
      expect(_run('{{foo}}{{/foo}}'), ('{{foo}}', 'unknown_macro'));
      expect(_run('{{space}}x{{/space}}'), (
        '{{space}}x}}',
        'invalid_macro_arguments',
      ));
    });
  });

  group('pre- and post-processors', () {
    test('{{time_UTC±N}} is the time macro with an offset', () {
      expect(
        _run('{{time_UTC+8}}|{{TIME_utc-10}}|{{{time_UTC+8}}}'),
        _run('{{time::UTC+8}}|{{time::utc-10}}|{{{time::UTC+8}}}'),
      );
      expect(_run('{{time_UTC+8}}').$2, '');
      // Only the exact form is rewritten.
      for (final source in ['{{time_UTC+8 }}', '{{time_UTC8}}']) {
        expect(_run(source).$1, source);
      }
    });

    test('legacy markers become macros before parsing', () {
      expect(_run('<user>/<Bot>/<CHAR>/< USER>/<USERS>'), (
        '阿雨/道渊/道渊/< USER>/<USERS>',
        '',
      ));
      expect(_run('{{setvar::<BOT>::1}}{{getvar::{{char}}}}'), ('1', ''));
      // A chat has one character, so the group is that character.
      expect(_run('<GROUP>/<charIfNotGroup>'), ('道渊/道渊', ''));
    });

    test('escaped braces are unescaped after evaluation', () {
      expect(_run(r'\{\{user\}\}|\{\{user}}|\{{user}}|\\{|a\b'), (
        r'{{user}}|{{user}}|\阿雨|\{|a\b',
        '',
      ));
      expect(_run(r'{{setvar::a::\{}}{{getvar::a}}'), ('{', ''));
      // The first `}}` closes the macro, so `\` and `{x` reach reverse.
      expect(_run(r'{{reverse::\{x\}}}'), (r'\x{}', ''));
    });

    test('legacy trim takes the line breaks around it', () {
      expect(
        _run('a\r\n{{trim}}\r\nb|a\r{{trim}}\rb|a\n\r\n{{TRIM}}b|{{trim}}\\{'),
        ('ab|a\r\rb|ab|{', ''),
      );
    });

    test('an if resolves its condition and branch like a new evaluation', () {
      expect(_run(r'{{if 1}}\\{{{/if}}'), ('{', ''));
      expect(_run('{{if 1}}x{{trim}}{{/if}}\n\ny'), ('x\n\ny', ''));
      expect(_run('{{if 1}}\\{{trim}}{{/if}}\nb'), ('\nb', ''));
      expect(
        _run(
          '{{setvar::t::{{trim}}}}[{{if {{getvar::t}}}}y{{/if}}]'
          '[{{if .t}}y{{else}}n{{/if}}]',
        ),
        ('[][n]', ''),
      );
    });

    test('a stray else is a marker until post-processing', () {
      expect(_run('[{{else}}]|{{trim}} x {{else}}{{/trim}}|'), ('[]|x |', ''));
      expect(_run('{{setvar::a}} x {{else}} {{/setvar}}[{{getvar::a}}]'), (
        '[x ]',
        '',
      ));
      expect(_run('{{setvar::a::{{else}}}}{{if .a}}y{{else}}n{{/if}}'), (
        'n',
        '',
      ));
      // Reversed, it is no longer the marker.
      expect(_run('{{reverse:: a{{else}} }}'), (
        '\u0000\u001FESLE\u001F\u0000a',
        '',
      ));
    });
  });

  group('transform', () {
    test('runs on every macro result, nested ones included', () {
      for (final (source, expected) in [
        ('{{user}}', '[阿雨]'),
        ('{{reverse::a{{user}}b}}', '[b]雨阿[a]'),
        ('{{setvar::k::{{user}}}}{{getvar::k}}', '[][[阿雨]]'),
        ('{{reverse::{{newline}}}}', '[]\n[]'),
        ('{{// note}}|<USER>', '[]|[阿雨]'),
        ('{{reverse}}{{user}}{{/reverse}}', '[]雨阿[]'),
        ('{{trim}}  {{user}}  {{/trim}}', '[[阿雨]]'),
        ('{{#trim}} {{user}} {{/trim}}', '[ [阿雨] ]'),
      ]) {
        expect(_wrapped(source), (expected, ''), reason: source);
      }
    });

    test('an if transforms its condition, branch and result', () {
      for (final (source, expected) in [
        ('{{if 1}}{{user}}{{/if}}', '[[阿雨]]'),
        ('{{if 0}}a{{else}}{{char}}{{/if}}', '[[道渊]]'),
        ('{{if 1}}{{if 1}}{{user}}{{/if}}{{/if}}', '[[[阿雨]]]'),
        ('{{if::1::{{user}}}}', '[[阿雨]]'),
        // An empty condition result is `[]` once transformed, so true.
        ('{{if {{getvar::nope}}}}y{{else}}n{{/if}}', '[y]'),
        ('{{if noop}}y{{else}}n{{/if}}', '[y]'),
        ('{{if .nope}}y{{else}}n{{/if}}', '[y]'),
        ('{{if !.mood}}y{{else}}n{{/if}}', '[n]'),
      ]) {
        expect(_wrapped(source), (expected, ''), reason: source);
      }
    });

    test('skips text kept raw and variable shorthands', () {
      for (final (source, expected, codes) in [
        (r'{{.mood}}|{{$theme}}|{{.nope}}', '平静|dark|', ''),
        ('{{reverse::{{.mood}}}}', '[静平]', ''),
        ('{{foo::{{user}}}}', '{{foo::[阿雨]}}', 'unknown_macro'),
        ('{{foo}}{{user}}{{/foo}}', '{{foo}}[阿雨]}}', 'unknown_macro'),
        (
          '{{reverse::{{user}}::b}}',
          '{{reverse::[阿雨]::b}}',
          'invalid_macro_arguments',
        ),
        ('{{newline::-1}}', '{{newline::-1}}', 'invalid_macro_arguments'),
        (
          '{{reverse::{{reverse}}}}',
          '[}}esrever{{]',
          'invalid_macro_arguments',
        ),
        ('{{user}}x{{/user}}', '{{user}}x{{/user}}', ''),
        ('{{noop}}{{user}}{{/noop}}', '{{noop}}[阿雨]{{/noop}}', ''),
        ('{{/if}}|{{if}}x{{/if}}', '{{/if}}|{{if}}x{{/if}}', ''),
      ]) {
        expect(_wrapped(source), (expected, codes), reason: source);
      }
    });

    test('pre- and post-processors run around transformed results', () {
      for (final (source, expected) in [
        (r'\{\{user\}\}|\{{user}}', r'{{user}}|\[阿雨]'),
        (r'{{setvar::a::\{}}{{getvar::a}}', '[][{]'),
        // `[{{trim}}]` keeps the line breaks outside the brackets.
        ('a\n{{trim}}\nb|{{trim}}', 'a\n[]\nb|[]'),
        ('{{reverse::{{trim}}}}', '[]}}mirt{{[]'),
        ('[{{else}}]|{{trim}} x {{else}}{{/trim}}|', '[[]]|[x []]|'),
      ]) {
        expect(_wrapped(source), (expected, ''), reason: source);
      }
    });

    test('regex find mode 2 escapes each macro result like ST', () {
      String apply(String find, int mode, String text) {
        final pipeline = RegexPipeline(
          card: [
            {
              'findRegex': find,
              'replaceString': '<{{match}}>',
              'placement': [2],
              'substituteRegex': mode,
            },
          ],
        );
        final output = pipeline.apply(
          text,
          placement: 2,
          stage: RegexStage.general,
          macros: MacroEngine(
            values: const {'user': 'a.b', 'path': 'x/y'},
            clock: DateTime.utc(2026),
            seed: 1,
          ),
        );
        expect(pipeline.diagnostics, isEmpty);
        return output;
      }

      expect(apply('/{{user}}/g', 2, 'a.b axb'), '<a.b> axb');
      expect(apply('/{{user}}/g', 1, 'a.b axb'), '<a.b> <axb>');
      expect(apply('/{{path}}/g', 2, 'x/y'), '<x/y>');
      // `{{user}}` is escaped to `a\.b`, reversed, then escaped again.
      expect(apply('/{{reverse::{{user}}}}/g', 2, r'b.a b.\a'), r'b.a <b.\a>');
      // regex/engine.js `sanitizeRegexMacro` writes a line break as `\n`,
      // so escaped twice it matches a backslash and `n`.
      expect(apply('/{{reverse::{{newline}}}}/g', 2, 'n\\ \n'), '<n\\> \n');
    });
  });

  // Checked with ST 1.19.0 variables.js `get`/`set`/`add`/`has` verbatim.
  group('variable shorthands', () {
    void check(List<(String, String, String)> rows) {
      for (final (source, expected, codes) in rows) {
        expect(_run(source), (expected, codes), reason: source);
      }
    }

    test('a read gives numbers as JS writes them', () {
      final engine = MacroEngine(
        values: const {},
        clock: DateTime.utc(2026),
        seed: 1,
        local: const {
          'n007': '007',
          'hex': '0x10',
          'dec': '1.50',
          'sp': ' 12 ',
          'ws': '  ',
          'nan': 'NaN',
          'big': '1e21',
          'obj': '{"a":1}',
          'neg0': '-0',
        },
      );
      expect(
        engine.render(
          '{{.n007}}|{{.hex}}|{{.dec}}|{{.sp}}|[{{.ws}}]|{{.nan}}|{{.big}}|'
          '{{.obj}}|{{.neg0}}|{{getvar::n007}}|{{.ws++}}',
        ),
        '7|16|1.5|12|[  ]|NaN|1e+21|{"a":1}|0|7|1',
      );
      expect(engine.diagnostics, isEmpty);
      check([
        (
          r'{{.mood}}|{{ . mood }}|{{.x-y}}|{{$theme}}|[{{.missing}}][{{$mood}}]',
          '平静|平静|7|dark|[][]',
          '',
        ),
        ('{{setvar::n::007}}{{getvar::n}}|{{incvar::n}}', '7|8', ''),
        (
          '{{.x = 1e21}}{{.x}}|{{.x = Infinity}}{{.x++}}|{{.x = 0x1F}}{{.x}}',
          '1e+21|Infinity|31',
          '',
        ),
      ]);
    });

    test('++ and -- give the new value; =, += and -= give nothing', () {
      check([
        (
          r'{{.n++}}{{.n++}}{{.n--}}|{{.s = abc}}{{.s++}}|{{.e = }}{{.e--}}|{{$theme++}}',
          '121|abc1|-1|dark1',
          '',
        ),
        (
          '{{.x=1}}{{.x += 2}}{{.x}}|{{.x -= 0.5}}{{.x}}|{{.x += a}}{{.x}}|'
              '{{.x -= a}}{{.x}}',
          '3|2.5|2.5a|2.5a',
          'invalid_macro_arguments',
        ),
        (
          '{{.y = 0}}{{.y += a}}{{.y}}|{{.z = 0.1}}{{.z += 0.2}}{{.z}}|'
              '{{.w = 007}}{{.w += x}}{{.w}}',
          'a|0.30000000000000004|7x',
          '',
        ),
        (
          '{{.a = [1, 2.0]}}{{.a++}}|{{.a += x}}{{.a}}|{{.a -= 3}}{{.a}}',
          '[1,2,1]|[1,2,1,"x"]|[1,2,1,"x",-3]',
          '',
        ),
        ('{{.x = {"a":1} }}{{.x += 1}}{{.x}}', '{"a":1}1', ''),
        (r'{{$g = 1}}{{$g += 2}}{{$g}}', '3', ''),
      ]);
      final engine = _engine();
      engine.render(r'{{.x = [1]}}{{.x += a}}{{$g = 1}}{{$g++}}');
      expect(engine.local['x'], '[1,"a"]');
      expect(engine.global['g'], '2');
    });

    test('||, ??, ||= and ??= fall back on falsy or missing variables', () {
      check([
        (
          '{{.mood || d}}|{{.none || d}}|{{.zero = 0.0}}{{.zero || d}}|'
              '{{.off = OFF}}{{.off || d}}|{{.no = no}}{{.no || d}}',
          '平静|d|d|d|no',
          '',
        ),
        (
          '{{.e = }}{{.e ?? d}}|{{.none ?? d}}|{{.none ??= v}}{{.none}}|'
              '{{.e ||= w}}{{.e}}|{{.mood ||= w}}',
          '|d|vv|ww|平静',
          '',
        ),
      ]);
    });

    test('== and != compare text, the others JS numbers', () {
      check([
        (
          '{{.n = 007}}{{.n == 7}}{{.n == 007}}{{.n != 7}}|{{.none == }}|'
              '{{.n > 5}}{{.n >= 7}}{{.n < 0x10}}{{.n <= 6}}|{{.none > -1}}',
          'truefalsefalse|true|truetruetruefalse|true',
          '',
        ),
        ('{{.mood > 1}}', 'false', 'invalid_macro_arguments'),
      ]);
    });

    test('the value is trimmed and resolved once, only when needed', () {
      check([
        (
          '{{.x  =   a  b  }}[{{.x}}]|{{.x = {{user}} {{char}} }}[{{.x}}]|'
              '{{.x = a::b:c="d"}}{{.x}}|{{.x = a}b}}{{.x}}',
          '[a  b]|[阿雨 道渊]|a::b:c="d"|a}b',
          '',
        ),
        (
          '{{.mood || {{.a = 1}}}}|{{.a ?? unset}}|'
              '{{.none ??= {{.k++}}}}{{.none}}{{.k}}',
          '平静|unset|111',
          '',
        ),
        // The variable is read before the value is resolved.
        ('{{.y = 1}}{{.y > {{.y = 5}}3}}{{.y}}', 'false5', ''),
      ]);
    });

    test('macros in the value resolve one by one, without scoped pairs', () {
      check([
        (
          '{{.x = {{if 1}}a{{/if}}}}{{.x}}',
          '{{if 1}}a{{/if}}',
          'invalid_macro_arguments,invalid_macro_arguments',
        ),
        (
          '{{.x = {{/user}}}}{{.x}}|{{.x = {{if 1::a}}}}{{.x}}',
          '阿雨|{{if 1::a}}',
          'invalid_macro_arguments',
        ),
      ]);
    });

    test('names, whitespace and malformed shorthands', () {
      check([
        (
          '{{.x=1}}{{.x ++}}{{ .x-- }}{{.x}}|{{.my-var++}}{{.my-var--}}',
          '211|10',
          '',
        ),
        for (final source in [
          '{{.x-}}',
          '{{.x---}}',
          '{{.x + 1}}',
          '{{.x::a}}',
          '{{.x y z}}',
          '{{.x ++ = 1}}',
          '{{.x.y}}',
          '{{.1}}',
        ])
          (source, source, ''),
        // Chevrotain drops one stray token before `}}`.
        ('{{.mood y}}', '平静', 'macro_syntax'),
        ('{{.x++ ++}}{{.x}}', '11', 'macro_syntax'),
        ('{{.mood !}}', '平静', 'macro_syntax'),
        ('{{.x++ =}}{{.x}}', '11', 'macro_syntax'),
        ('[{{.}}]', '[]', 'macro_syntax'),
      ]);
    });

    test('flags do nothing and results are not transformed', () {
      check([(r'{{!.mood}}{{/.mood}}{{#$theme}}', '平静平静dark', '')]);
      expect(_wrapped('{{.x = {{user}}}}{{.x}}|{{.mood == 平静}}|{{.n++}}'), (
        '[阿雨]|true|1',
        '',
      ));
    });

    test('if conditions read shorthands', () {
      check([
        (
          '{{.n = 0.0}}{{if .n}}y{{else}}n{{/if}}|'
              '{{if {{.mood == 平静}}}}y{{/if}}',
          'n|y',
          '',
        ),
      ]);
    });
  });

  group('keyed variables', () {
    void check(List<(String, String, String)> rows) {
      for (final (source, expected, codes) in rows) {
        expect(_run(source), (expected, codes), reason: source);
      }
    }

    test('a missing variable becomes an array or an object by its key', () {
      check([
        (
          '{{setvarkey::a::2::x}}{{getvar::a}}|{{getvarkey::a::2}}|'
              '{{getvarkey::a::0}}|{{getvarkey::a::length}}',
          '[null,null,"x"]|x|null|3',
          '',
        ),
        (
          '{{setvarkey::o::k::v}}{{setvarkey::o::01::one}}{{getvar::o}}|'
              '{{getvarkey::o::1.0}}|{{.o}}',
          '{"1":"one","k":"v"}|one|{"1":"one","k":"v"}',
          '',
        ),
        (
          '{{setvarindex::a::::x}}{{getvarindex::a::-0}}|'
              r'{{setglobalvarkey::g::0::y}}{{getglobalvarindex::g::0}}{{$g}}|'
              '{{setglobalvarindex::theme::0::z}}{{getglobalvar::theme}}',
          'x|y["y"]|dark',
          '',
        ),
        (
          '{{setvarkey::a::0}}  007  {{/setvarkey}}{{getvar::a}}|'
              '{{getvarkey::a::0}}',
          '["007"]|7',
          '',
        ),
      ]);
    });

    test('a read parses JSON and goes through Number()', () {
      final engine = MacroEngine(
        values: const {},
        clock: DateTime.utc(2026),
        seed: 1,
        local: const {
          'arr': '[1, "a", null, true, {"b":[2]}, " 007 ", " ", 1e400]',
          'obj': '{"1":"one","01":"zero-one","a":{"c":"x"},"f":false}',
          'str': '"平静😀"',
          'nul': 'null',
          'num': '5',
          'text': '平静',
          'bad': '[1,]',
        },
      );
      expect(
        engine.render(
          '{{getvarkey::arr::0}}|{{getvarkey::arr::1}}|{{getvarkey::arr::2}}|'
          '{{getvarkey::arr::3}}|{{getvarkey::arr::4}}|{{getvarkey::arr::5}}|'
          '[{{getvarkey::arr::6}}]|{{getvarkey::arr::7}}|'
          '[{{getvarkey::arr::8}}]|{{getvarkey::arr::length}}|'
          '[{{getvarkey::arr::-1}}]|{{getvarkey::arr::}}',
        ),
        '1|a|null|1|{"b":[2]}|7|[ ]|Infinity|[]|8|[]|1',
      );
      expect(
        engine.render(
          '{{getvarkey::obj::01}}|{{getvarkey::obj::0x1}}|'
          '{{getvarkey::obj::a}}|{{getvarkey::obj::f}}|'
          '[{{getvarkey::obj::length}}]',
        ),
        'one|one|{"c":"x"}|0|[]',
      );
      expect(
        engine.render(
          '{{getvarkey::str::0}}|{{getvarkey::str::length}}|'
          '{{getvarkey::nul::k}}|[{{getvarkey::num::0}}]|'
          '{{getvarkey::text::0}}|{{getvarkey::bad::0}}|[{{getvarkey::none::0}}]',
        ),
        '平|4|0|[]|平静|[1,]|[]',
      );
      expect(engine.diagnostics, isEmpty);
    });

    test('a write keeps text that is not a JSON object or array', () {
      final engine = MacroEngine(
        values: const {},
        clock: DateTime.utc(2026),
        seed: 1,
        local: const {
          'arr': '[1, 2.0]',
          'str': '"abc"',
          'num': '5',
          'text': '平静',
          'nul': 'null',
          'empty': '',
        },
      );
      engine.render(
        '{{setvarkey::arr::k::x}}{{setvarkey::str::0::x}}'
        '{{setvarkey::num::0::x}}{{setvarkey::text::k::x}}'
        '{{setvarkey::nul::k::x}}{{setvarkey::empty::k::x}}',
      );
      expect(engine.local, {
        'arr': '[1,2]',
        'str': '"abc"',
        'num': '5',
        'text': '平静',
        'nul': '{"k":"x"}',
        'empty': '',
      });
      check([
        (
          '{{setvarkey::a::0::x}}{{setvarkey::a::length::3}}{{getvar::a}}|'
              '{{setvarkey::a::length::1}}{{getvar::a}}|'
              '{{setvarkey::a::length::x}}{{getvar::a}}|'
              '{{setvarkey::a::-1::y}}{{setvarkey::a::1.5::y}}{{getvar::a}}',
          '["x",null,null]|["x"]|["x"]|["x"]',
          '',
        ),
      ]);
    });

    test('values from other variable macros', () {
      check([
        (
          '{{incvar::c}}{{setvarkey::c::0::x}}{{getvar::c}}|'
              '[{{getvarkey::c::0}}]',
          '11|[]',
          '',
        ),
        (
          '{{.a = [1, 2]}}{{setvarkey::a::1::x}}{{.a}}|'
              '{{addvar::a::y}}{{getvarkey::a::2}}|'
              '{{setvarkey::o::k::1}}{{.o}}',
          '[1,"x"]|y|{"k":"1"}',
          '',
        ),
        (
          '{{setvarkey::o::{{user}}::{{char}}}}{{getvarkey::o::阿雨}}|'
              '{{if {{getvarkey::o::none}}}}y{{else}}n{{/if}}',
          '道渊|n',
          '',
        ),
      ]);
    });

    test('argument counts and empty names keep the macro text', () {
      check([
        for (final source in [
          '{{setvarkey::a::0}}',
          '{{getvarkey::a}}',
          '{{getvarkey::a::0::1}}',
          '{{setvarkey::::0::x}}',
          '{{setglobalvarkey::::k::x}}',
          '{{setvar::::x}}',
          '{{addvar::::1}}',
          '{{incvar::}}',
          '{{decglobalvar::}}',
        ])
          (source, source, 'invalid_macro_arguments'),
        ('[{{getvarkey::::0}}][{{getvar::}}]', '[][]', ''),
      ]);
      final engine = _engine();
      engine.render('{{setvar::::x}}{{incvar::}}');
      expect(engine.local.containsKey(''), isFalse);
    });

    test('an index past 2 MiB elements aborts like oversized output', () {
      for (final source in [
        '{{setvarkey::a::3000000::x}}',
        '{{setvarkey::a::0::x}}{{setvarkey::a::length::3000000}}',
      ]) {
        expect(() => _engine().render(source), throwsFormatException);
      }
      // Not an array index in JS: an ignored property, as in ST.
      expect(_run('{{setvarkey::a::4294967295::x}}{{getvar::a}}'), ('[]', ''));
    });
  });

  group('time macros', () {
    // 2026-10-15T05:30:00.123Z; expectations are ST's with moment 2.30.1
    // at that instant in a UTC+8 time zone.
    final now = DateTime.utc(2026, 10, 15, 5, 30, 0, 123);
    (String, String) time(
      String source, {
      Duration offset = const Duration(hours: 8),
      DateTime? idleSince,
    }) {
      final engine = MacroEngine(
        values: const {},
        clock: now,
        utcOffset: offset,
        idleSince: idleSince,
        seed: 1,
      );
      final text = engine.render(source);
      return (text, engine.diagnostics.map((d) => d.code).join(','));
    }

    test('local time in moment en formats', () {
      expect(time('{{time}}|{{date}}|{{weekday}}|{{isotime}}|{{isodate}}'), (
        '1:30 PM|October 15, 2026|Thursday|13:30|2026-10-15',
        '',
      ));
      expect(
        time(
          '{{time}} {{datetimeformat::Z ZZ}}',
          offset: const Duration(hours: -2, minutes: -30),
        ),
        ('3:00 AM -02:30 -0230', ''),
      );
      // The clock's own offset by default: UTC here.
      final utc = MacroEngine(values: const {}, clock: now, seed: 1);
      expect(utc.render('{{isotime}} {{datetimeformat::Z}}'), '05:30 +00:00');
    });

    test('time takes a case-sensitive UTC±N offset', () {
      expect(
        time(
          '{{time::UTC-5}}|{{time::UTC+16}}|{{time::utc+1}}|{{time_UTC+530}}'
          '|{{time:: UTC-0 }}',
        ),
        // Below 16 the offset is hours, from 16 on minutes (moment).
        ('12:30 AM|5:46 AM|1:30 PM|2:20 PM|5:30 AM', ''),
      );
      expect(time('{{time::UTC+9999999999999999999999}}'), (
        'Invalid date',
        '',
      ));
      expect(time('{{time::UTC+1::x}}'), (
        '{{time::UTC+1::x}}',
        'invalid_macro_arguments',
      ));
    });

    test('datetimeformat takes any moment format', () {
      expect(time('{{datetimeformat::LLLL [x] Z}}'), (
        'Thursday, October 15, 2026 1:30 PM x +08:00',
        '',
      ));
      expect(time('{{datetimeformat::}}'), ('2026-10-15T13:30:00+08:00', ''));
      expect(
        time(
          r'{{datetimeformat::llll|L|l|LTS|Do MMM YY|wo Wo gggg GGGG|DDDD Qo'
          r'|hmmss Hmm|X x|[LT] \LT}}',
        ),
        (
          'Thu, Oct 15, 2026 1:30 PM|10/15/2026|10/15/2026|1:30:00 PM'
              '|15th Oct 26|42nd 42nd 2026 2026|288 4th|13000 1330'
              '|1792042200 1792042200123|LT LT',
          '',
        ),
      );
      expect(
        time(
          '{{datetimeformat::w| W| [a[b]c] [] NNNN y yo e E k kk z zz '
          'S SS SSS SSSS SSSSSSSSS ZZ}}',
        ),
        (
          'w| W| [pmb]c  Anno Domini 2026 2026th 4 4 13 13   '
              '1 12 123 1230 123000000 +0800',
          '',
        ),
      );
      // moment drops line breaks, and throws on a format of nothing else.
      expect(time('{{datetimeformat::a{{newline}}b}}'), ('pmb', ''));
      expect(time('{{datetimeformat::{{newline}}}}'), (
        '{{datetimeformat::\n}}',
        'invalid_macro_arguments',
      ));
    });

    test('idleDuration humanizes the time since idleSince', () {
      expect(time('{{idleDuration}}|{{idle_duration}}'), (
        'just now|just now',
        '',
      ));
      expect(
        time('{{idleDuration}}', idleSince: DateTime.utc(2026, 10, 15, 3, 20)),
        ('2 hours', ''),
      );
      expect(
        time(
          '{{idleDuration}}',
          idleSince: DateTime.utc(2026, 10, 15, 5, 29, 15, 123),
        ),
        ('a minute', ''),
      );
    });

    test('idleDuration in a chat counts from the user message before the '
        'latest one', () {
      String idle(List<PromptMessage> conversation) => PromptCompiler()
          .compile(
            PresetInput(
              preset: PresetImporter().decode({
                'prompts': [
                  {
                    'identifier': 'main',
                    'role': 'system',
                    'content': '{{idleDuration}}',
                  },
                ],
                'prompt_order': [
                  {
                    'character_id': 100001,
                    'order': [
                      {'identifier': 'main', 'enabled': true},
                    ],
                  },
                ],
              }),
              branchId: 'main',
              throughPosition: 0,
              brief: '',
              clock: now,
              randomSeed: 1,
              conversation: conversation,
            ),
          )
          .messages
          .first
          .content;
      DateTime at(int hour, int minute) =>
          DateTime.utc(2026, 10, 15, hour, minute);
      expect(
        idle([
          PromptMessage('assistant', 'a', sentAt: at(1, 0)),
          PromptMessage('user', 'b', sentAt: at(3, 20)),
          PromptMessage('assistant', 'c', sentAt: at(3, 21)),
          PromptMessage('system', 'd', sentAt: at(5, 0)),
          PromptMessage('user', 'e', sentAt: at(5, 30)),
        ]),
        '2 hours',
      );
      expect(
        idle([
          PromptMessage('user', 'b', sentAt: DateTime.utc(2026, 10, 14, 3)),
          PromptMessage('assistant', 'c', sentAt: at(5, 29)),
        ]),
        'a day',
      );
      expect(idle([PromptMessage('user', 'e', sentAt: at(5, 30))]), 'just now');
    });

    test('timeDiff humanizes a minus b with a suffix', () {
      for (final (source, expected) in [
        (
          '{{timeDiff::2023-01-01 12:00:00::2023-01-01 15:00:00}}',
          '3 hours ago',
        ),
        (
          '{{ timeDiff :: 2023-01-01T15:00:00Z :: 2023-01-01 12:00:00 }}',
          'in 11 hours',
        ),
        ('{{timeDiff::2024-02-30::2024-01-01}}', 'Invalid date'),
        (
          '{{timeDiff::Mon, 25 Dec 1995 13:30:00 +0430::1995-12-25T09:00Z}}',
          'a few seconds ago',
        ),
        ('{{timeDiff::/Date(0)/::1970-01-02}}', '16 hours ago'),
        ('{{timeDiff::2020-W53-7::2021-01-03T12:00}}', '12 hours ago'),
        ('{{timeDiff::2023-01-01T24:00::2023-01-02}}', 'a few seconds ago'),
        ('{{timeDiff::::2023-01-01}}', 'Invalid date'),
        ('{{timeDiff::abc::2023-02-30}}', 'Invalid date'),
      ]) {
        expect(time(source), (expected, ''), reason: source);
      }
    });

    test('a stored task renders the local time it was made at', () {
      String shown(Map<String, dynamic> input) =>
          ManuscriptPresentation.fromTask(
            ManuscriptContent.plainText('T'),
            GenerationTask(
              id: 'task',
              branchId: 'branch',
              kind: TaskKind.writing,
              status: TaskStatus.completed,
              partialText: 'T',
              reasoning: '',
              error: '',
              createdAt: now,
              updatedAt: now,
              input: {
                'clock': '2026-10-15T05:30:00.123Z',
                'seed': 1,
                'outputRegex': [
                  {
                    'findRegex': '/T/g',
                    'replaceString': '{{isotime}}',
                    'placement': [2],
                    'markdownOnly': true,
                  },
                ],
                ...input,
              },
            ),
          ).content.text.trim();
      expect(shown({'utcOffset': 480}), '13:30');
      // Tasks from before the offset was kept rendered UTC.
      expect(shown({}), '05:30');
    });

    test('timeDiff keeps text moment leaves to the browser', () {
      // moment hands `October 15, 2026` to `new Date()`, whose reading
      // differs between browsers (Chrome: `in a day`).
      expect(time('{{timeDiff::October 15, 2026::2026-10-14}}'), (
        '{{timeDiff::October 15, 2026::2026-10-14}}',
        'unsupported_time_format',
      ));
    });
  });

  group('env macros', () {
    // Expectations are ST's: the pinned substituteParams, MacroEnvBuilder
    // and env-macros.js with this card as `characters[this_chid]`.
    const card = {
      'spec': 'chara_card_v2',
      'data': {
        'name': '道渊',
        'description':
            ' 我是{{char}}，{{user}}的师父{{personality}}{{original}}\r\n ',
        'personality': ' 冷静{{random::甲,乙,丙,丁,戊,己}} ',
        'scenario': '{{user}}拜入山门{{setvar::sc::1}}',
        'system_prompt': '{{original}}\n系统：{{char}}',
        'post_history_instructions': ' 结尾 ',
        'mes_example': '<START>\n{{user}}: 你好\n{{char}}: 嗯\n<start>\n道渊: 再会',
        'creator_notes': ' 作者{{user}} ',
        'character_version': ' 1.0 ',
        'first_mes': ' 开场{{user}} ',
        'alternate_greetings': [' 备一{{setvar::g::1}} ', '备二{{getvar::g}}'],
        'extensions': {
          'depth_prompt': {'prompt': ' 深度{{char}} ', 'depth': 4},
        },
      },
    };
    MacroEnv cardEnv({ImportedPreset? preset}) => MacroEnv.of(
      card: card,
      user: '阿雨',
      persona: ' 人设：{{user}}{{description}} ',
      preset: preset,
      model: 'gpt-x',
      isMobile: true,
    );
    (String, String) env(String source, {MacroEnv? env, String? original}) {
      final engine = MacroEngine(
        env: env ?? cardEnv(),
        clock: DateTime.utc(2026),
        seed: 1,
      );
      final text = engine.render(source, original: original);
      return (text, engine.diagnostics.map((d) => d.code).join(','));
    }

    test('a one-character chat is its own group', () {
      expect(
        env(
          '{{user}}/{{char}}/{{group}}/{{charIfNotGroup}}/{{groupNotMuted}}/'
          '{{notChar}}/<GROUP>/<CHARIFNOTGROUP>',
        ),
        ('阿雨/道渊/道渊/道渊/道渊/阿雨/道渊/道渊', ''),
      );
    });

    test('card fields are trimmed and resolved without card fields', () {
      for (final (source, expected) in [
        // `{{personality}}` in a field is empty; `{{original}}` waits for a
        // prompt override (ST logs an error and keeps it).
        ('{{charDescription}}', '我是道渊，阿雨的师父{{original}}'),
        ('{{DESCRIPTION}}', '我是道渊，阿雨的师父{{original}}'),
        ('{{persona}}', '人设：阿雨'),
        ('{{charScenario}}/{{scenario}}', '阿雨拜入山门/阿雨拜入山门'),
        ('{{charPrompt}}|{{charInstruction}}', '{{original}}\n系统：道渊|结尾'),
        ('{{mesExamplesRaw}}', '<START>\n阿雨: 你好\n道渊: 嗯\n<start>\n道渊: 再会'),
        ('{{charDepthPrompt}}', '深度道渊'),
        ('{{charCreatorNotes}}/{{creatorNotes}}', '作者阿雨/作者阿雨'),
        // The version is read as is.
        ('{{charVersion}}/{{version}}/{{char_version}}', ' 1.0 / 1.0 / 1.0 '),
        ('{{model}}/{{isMobile}}', 'gpt-x/true'),
        ('{{if description}}y{{else}}n{{/if}}', 'y'),
      ]) {
        expect(env(source), (expected, ''), reason: source);
      }
      expect(env('{{description::x}}'), (
        '{{description::x}}',
        'invalid_macro_arguments',
      ));
    });

    test('a field resolves once per render, side effects included', () {
      final engine = MacroEngine(
        env: cardEnv(),
        clock: DateTime.utc(2026),
        seed: 1,
      );
      final [a, b] = engine
          .render('{{personality}}/{{personality}}')
          .split('/');
      expect(a, b);
      expect(engine.render('{{charScenario}}{{getvar::sc}}'), '阿雨拜入山门1');
    });

    test('greetings by index; alternates resolve together', () {
      for (final (source, expected) in [
        (
          '{{charFirstMessage}}/{{greeting::0}}/{{greeting::-0}}',
          '开场阿雨/开场阿雨/开场阿雨',
        ),
        ('{{greeting::1}}{{getvar::g}}', '备一1'),
        ('{{greeting::2}}', '备二1'),
        ('{{greeting::-1}}{{getvar::g}}', '1'),
        (
          '{{greeting::3}}/{{greeting::007}}/{{greeting::99999999999999999999999}}',
          '//',
        ),
      ]) {
        expect(env(source), (expected, ''), reason: source);
      }
      for (final source in [
        '{{greeting::x}}',
        '{{greeting::+1}}',
        '{{greeting::1::2}}',
      ]) {
        expect(env(source), (
          source,
          'invalid_macro_arguments',
        ), reason: source);
      }
    });

    test('original is one-shot and only set for a prompt override', () {
      expect(env('{{original}}|{{original}}', original: '原文'), ('原文|', ''));
      expect(env('{{original}}'), ('{{original}}', 'invalid_macro_arguments'));
      // Each render is a new env; card fields never see it.
      expect(env('{{charPrompt}}', original: '原文'), (
        '{{original}}\n系统：道渊',
        '',
      ));
    });

    test('mesExamples are formatted for the prompt API', () {
      ImportedPreset text(
        Map<String, dynamic> context, [
        Map<String, dynamic>? instruct,
      ]) => PresetImporter().decode({
        'preset': {'temp': 1},
        'context': context,
        'instruct': ?instruct,
      });
      String examples(ImportedPreset? preset) =>
          env('{{mesExamples}}', env: cardEnv(preset: preset)).$1;
      // Chat completion: `<START>` heads each block.
      expect(examples(null), '<START>\n阿雨: 你好\n道渊: 嗯\n<START>\n道渊: 再会\n');
      // Text completion: the context's example separator does.
      expect(
        examples(
          text({'example_separator': '*** {{char}}', 'story_string': ''}),
        ),
        '*** 道渊\n阿雨: 你好\n道渊: 嗯\n*** 道渊\n道渊: 再会\n',
      );
      // Instruct mode: every example in its sequences.
      expect(
        examples(
          text(
            {'example_separator': '***', 'story_string': ''},
            {
              'input_sequence': '<|user|>',
              'output_sequence': '<|char {{name}}|>',
              'input_suffix': '',
              'output_suffix': '</s>',
              'wrap': true,
              'macro': true,
              'names_behavior': 'force',
            },
          ),
        ),
        '***\n<|user|>\n阿雨: 你好\n<|char 道渊|>\n嗯</s>***\n<|char 道渊|>\n再会</s>',
      );
      expect(
        examples(
          text(
            {'example_separator': '***', 'story_string': ''},
            {
              'input_sequence': '<|user|>',
              'output_sequence': '<|char|>',
              'names_behavior': 'always',
            },
          ),
        ),
        // `wrap`, `macro` and the output suffix the template lacks are a
        // fresh install's (on, on, two line breaks).
        '***\n<|user|>\n阿雨: 你好\n<|char|>\n道渊: 嗯\n\n'
        '***\n<|char|>\n道渊: 再会\n\n',
      );
      expect(
        examples(
          text(
            {'example_separator': '***', 'story_string': ''},
            {'input_sequence': '<|user|>', 'skip_examples': true},
          ),
        ),
        '***\n阿雨: 你好\n道渊: 嗯\n***\n道渊: 再会\n',
      );
    });

    test('the env is read from V1 and V2 cards and survives a task', () {
      final v1 = MacroEnv.of(
        card: {'name': '林舟', 'description': '描述', 'character_version': 2},
        user: '我',
      );
      expect(v1.char, '林舟');
      expect(v1.card['description'], '描述');
      expect(v1.card['version'], '2');
      expect(MacroEnv.of(user: '我').char, '旁白');
      final stored = MacroEnv.fromJson(
        jsonDecode(jsonEncode(cardEnv().toJson())) as Map<String, dynamic>,
      );
      expect(stored.toJson(), cardEnv().toJson());
      expect(stored.alternateGreetings, [
        ' 备一{{setvar::g::1}} ',
        '备二{{getvar::g}}',
      ]);
    });

    test('prompt overrides resolve the card text with original', () {
      final preset = PresetImporter().decode({
        'prompts': [
          {
            'identifier': 'main',
            'role': 'system',
            'content': '主{{setvar::m::1}}',
          },
          {'identifier': 'jailbreak', 'role': 'system', 'content': '后'},
          {
            'identifier': 'custom',
            'role': 'system',
            'content': '{{description}}|{{getvar::m}}',
          },
          {'identifier': 'charDescription', 'marker': true},
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              for (final id in [
                'main',
                'jailbreak',
                'custom',
                'charDescription',
              ])
                {'identifier': id, 'enabled': true},
            ],
          },
        ],
      });
      final result = PromptCompiler().compile(
        PresetInput(
          preset: preset,
          branchId: 'main',
          throughPosition: 1,
          brief: 'brief',
          clock: DateTime.utc(2026),
          randomSeed: 1,
          card: CardImporter().decode(
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  ...card,
                  'data': {
                    ...card['data']! as Map,
                    'post_history_instructions': '{{original}}+{{original}}',
                  },
                }),
              ),
            ),
            'card.json',
          ),
          userName: '阿雨',
        ),
      );
      expect(result.messages.map((m) => m.content), [
        // The main prompt is resolved first; the override gets it once.
        '主\n系统：道渊',
        '后+',
        '我是道渊，阿雨的师父{{original}}|1',
        '我是道渊，阿雨的师父{{original}}',
      ]);
    });
  });

  test('text completion system prompts follow ST Generate', () {
    final preset = PresetImporter().decode({
      'preset': {'temp': 1},
      'context': {
        'story_string': '{{#if system}}{{system}}\n{{/if}}',
        'chat_start': '',
      },
      'sysprompt': {
        'content': '模板{{char}}{{description}}',
        'post_history': '后{{personality}}',
      },
    });
    String compile(Map<String, dynamic> data) => PromptCompiler()
        .compile(
          PresetInput(
            preset: preset,
            branchId: 'main',
            throughPosition: 1,
            brief: 'x',
            clock: DateTime.utc(2026),
            randomSeed: 1,
            userName: '阿雨',
            card: CardImporter().decode(
              Uint8List.fromList(
                utf8.encode(
                  jsonEncode({
                    'name': '道渊',
                    'description': '描述',
                    'personality': '性格',
                    ...data,
                  }),
                ),
              ),
              'card.json',
            ),
          ),
        )
        .completionText!;
    // Without card overrides the template text is resolved without card
    // fields (script.js `baseChatReplace`).
    // The post-history instructions follow the brief as an unnamed user
    // message (L4748-4765).
    expect(compile({}), '模板道渊\n阿雨: x\n后\n道渊:');
    // The card's text gets the template's as `original`, once and as
    // written; the story string resolves what it brought in.
    expect(
      compile({
        'system_prompt': '{{original}}|{{original}}',
        'post_history_instructions': '{{original}}+',
      }),
      '模板道渊描述|\n阿雨: x\n后{{personality}}+\n道渊:',
    );
  });

  test('the compiler offers only macros ST 1.19.0 registers', () {
    final preset = PresetImporter().decode({
      'prompts': [
        {
          'identifier': 'main',
          'role': 'system',
          'content': '{{char}}{{charJailbreak}}{{charName}}',
        },
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
    final result = PromptCompiler().compile(
      PresetInput(
        preset: preset,
        branchId: 'main',
        throughPosition: 1,
        brief: 'brief',
        clock: DateTime.utc(2026),
        randomSeed: 1,
      ),
    );
    expect(result.messages.single.content, '旁白{{charJailbreak}}{{charName}}');
    expect(
      result.diagnostics.where((d) => d.code == 'unknown_macro'),
      hasLength(2),
    );
  });

  group('chat macros', () {
    // ST 1.19.0 chat-macros.js and state-macros.js over the request's chat:
    // the chapters through the target, then the brief once sent.
    const line =
        '{{lastMessageId}}|{{lastMessage}}|{{lastUserMessage}}|'
        '{{lastCharMessage}}|{{allChatRange}}|{{lastSwipeId}}|'
        '{{currentSwipeId}}|{{firstIncludedMessageId}}|'
        '{{firstDisplayedMessageId}}|{{lastGenerationType}}';
    CompiledPrompt compile({
      List<String> chapters = const ['第一章', '第二章'],
      String brief = '写下一章',
      String type = 'normal',
      List<PromptMessage>? conversation,
      List<Map<String, dynamic>> globalRegex = const [],
      bool history = true,
    }) => PromptCompiler().compile(
      PresetInput(
        preset: PresetImporter().decode({
          'prompts': [
            {'identifier': 'main', 'role': 'system', 'content': line},
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                {'identifier': 'main', 'enabled': true},
                {'identifier': 'chatHistory', 'enabled': history},
              ],
            },
          ],
        }),
        branchId: 'b',
        throughPosition: chapters.length - 1,
        brief: brief,
        clock: DateTime.utc(2026),
        randomSeed: 1,
        generationType: type,
        conversation: conversation,
        globalRegex: globalRegex,
        history: [
          for (final (i, text) in chapters.indexed)
            ContextChapter(
              branchId: 'b',
              position: i,
              chapterId: 'c$i',
              revisionId: 'r$i',
              content: text,
            ),
        ],
      ),
    );

    test('a writing chat is the chapters, then the brief', () {
      final result = compile();
      // The brief is the last message, a user one without swipes; what the
      // previous request put in context is not kept between requests.
      expect(result.messages.first.content, '2|写下一章|写下一章|第二章|0-2||||0|normal');
      // Once the prompt is built (script.js `setInContextMessages`), as the
      // output stage reads it.
      expect(result.chatValues, {
        'lastmessageid': '2',
        'lastmessage': '写下一章',
        'lastusermessage': '写下一章',
        'lastcharmessage': '第二章',
        'allchatrange': '0-2',
        'lastswipeid': '',
        'currentswipeid': '',
        'firstincludedmessageid': '0',
        'firstdisplayedmessageid': '0',
        'lastgenerationtype': 'normal',
      });
    });

    test('the brief joins the chat after its user input regex', () {
      // script.js `sendMessageAsUser`: the regex runs on the input before it
      // is added, and the chat keeps the result.
      final result = compile(
        globalRegex: [
          {
            'findRegex': '/写/',
            'replaceString': '[{{lastMessageId}}{{lastUserMessage}}]',
            'placement': [1],
          },
        ],
      );
      expect(
        result.messages.first.content,
        '2|[1]下一章|[1]下一章|第二章|0-2||||0|normal',
      );
      expect(result.messages.last.content, '[1]下一章');
    });

    test('continuing without a brief ends the chat on the chapter', () {
      final result = compile(brief: '', type: 'continue');
      // A reply has one swipe (script.js `saveReply`).
      expect(result.messages.first.content, '1|第二章||第二章|0-1|1|1||0|continue');
      expect(result.chatValues['firstincludedmessageid'], '0');
      expect(
        compile(
          chapters: [],
          brief: '',
          type: 'continue',
        ).messages.first.content,
        '|||||||||continue',
      );
    });

    test('an editing chat is its conversation, the input as typed', () {
      final result = compile(
        brief: '改一下',
        conversation: const [
          PromptMessage('user', '你好'),
          PromptMessage('assistant', '请说'),
          PromptMessage('user', '<chapter title="一">\n正文\n</chapter>\n\n改一下'),
        ],
      );
      expect(result.messages.first.content, '2|改一下|改一下|请说|0-2||||0|normal');
    });

    test('messages the prompt leaves out move the first included id', () {
      // openai.js `openai_messages_count`: user and assistant messages only.
      expect(compile(history: false).chatValues['firstincludedmessageid'], '3');
    });

    test('a stage without a chat keeps them and reports it', () {
      expect(_run('{{lastMessageId}}'), (
        '{{lastMessageId}}',
        'chat_state_unavailable',
      ));
      expect(_run('{{allChatRange}}'), (
        '{{allChatRange}}',
        'chat_state_unavailable',
      ));
      // No generation has started (state-macros.js), no extension exists.
      expect(_run('{{lastGenerationType}}'), ('', ''));
      expect(_run('{{hasExtension::regex}}'), ('false', 'extension_check'));
      expect(_run('{{hasExtension}}'), (
        '{{hasExtension}}',
        'invalid_macro_arguments',
      ));
    });
  });

  group('core misc macros', () {
    // ST 1.19.0 core-macros.js `input`, `maxPrompt`, `maxContext`,
    // `maxResponse`, `banned` and `outlet`.
    CompiledPrompt compile(
      String main, {
      Map<String, dynamic> parameters = const {},
      List<ScopedWorldBook> books = const [],
    }) => PromptCompiler().compile(
      PresetInput(
        preset: PresetImporter().decode({
          ...parameters,
          'prompts': [
            {'identifier': 'main', 'role': 'system', 'content': main},
            {'identifier': 'worldInfoAfter', 'marker': true},
            {'identifier': 'chatHistory', 'marker': true},
          ],
          'prompt_order': [
            {
              'character_id': 100001,
              'order': [
                for (final id in ['main', 'worldInfoAfter', 'chatHistory'])
                  {'identifier': id, 'enabled': true},
              ],
            },
          ],
        }),
        branchId: 'b',
        throughPosition: 0,
        brief: '写下一章',
        clock: DateTime.utc(2026),
        randomSeed: 1,
        contextWindow: 16000,
        maxOutputTokens: 2048,
        worldBooks: books,
      ),
    );

    test('token limits are the request\'s context and response length', () {
      // script.js `getMaxContextTokens`, `getMaxResponseTokens` and
      // `getMaxPromptTokens` (context minus response): the connection's
      // context window, the response length the request asks for.
      const line =
          '{{maxPrompt}}|{{maxPromptTokens}}|{{maxContext}}|'
          '{{maxContextTokens}}|{{maxResponse}}|{{MaxResponseTokens}}';
      expect(
        compile(line).messages.first.content,
        '13952|13952|16000|16000|2048|2048',
      );
      expect(
        compile(
          line,
          parameters: {'openai_max_tokens': 500},
        ).messages.first.content,
        '15500|15500|16000|16000|500|500',
      );
      final engine = MacroEngine(
        env: const MacroEnv(maxContext: 4096, maxResponse: 5000),
        clock: DateTime.utc(2026),
        seed: 1,
      );
      expect(
        engine.render(
          '{{maxPrompt}}|{{if maxResponse}}y{{/if}}|{{maxContext::1}}',
        ),
        '-904|y|{{maxContext::1}}',
      );
      expect(engine.diagnostics.single.code, 'invalid_macro_arguments');
    });

    test('a stage without a request keeps token limits and reports it', () {
      expect(_run('{{maxContext}}'), ('{{maxContext}}', 'request_unavailable'));
      expect(_run('{{maxPromptTokens}}'), (
        '{{maxPromptTokens}}',
        'request_unavailable',
      ));
    });

    test('input is the send box Generate has emptied', () {
      // script.js `Generate` clears `#send_textarea` before it builds the
      // prompt; SillyDraft's frontends never leave text in it.
      expect(compile('[{{input}}]').messages.first.content, '[]');
      expect(_run('[{{input}}]'), ('[]', ''));
    });

    test('banned words render nothing; text completion bans are a gap', () {
      expect(_run('[{{banned "delve"}}{{banned::x}}]'), ('[]', ''));
      expect(_run('{{banned}}'), ('{{banned}}', 'invalid_macro_arguments'));
      final engine = MacroEngine(
        env: const MacroEnv(textCompletion: true),
        clock: DateTime.utc(2026),
        seed: 1,
      );
      expect(engine.render('[{{banned "delve"}}]'), '[]');
      expect(engine.diagnostics.single.code, 'banned_word_unsupported');
      expect(engine.diagnostics.single.message, contains('“delve”'));
    });

    test('outlets read what the request put in them', () {
      final engine = MacroEngine(
        outlets: {'成就': 'A\nB'},
        clock: DateTime.utc(2026),
        seed: 1,
      );
      expect(
        engine.render(
          '{{outlet::成就}}|{{outlet::无}}|{{outlet::}}|{{outlet 成就}}',
        ),
        'A\nB|||A\nB',
      );
      expect(engine.diagnostics, isEmpty);
      expect(_run('{{outlet}}'), ('{{outlet}}', 'invalid_macro_arguments'));
    });

    test('world info outlet entries fill outlets once scanned', () {
      final book = WorldBook.fromJson({
        'entries': [
          {
            'uid': 1,
            'constant': true,
            'content': '甲[{{outlet::成就}}]',
            'position': 7,
            'outletName': '成就',
            'order': 10,
          },
          {
            'uid': 2,
            'constant': true,
            'content': '乙',
            'position': 7,
            'outletName': '成就',
            'order': 20,
          },
          // A card's book, as ST `convertCharacterBook` reads it.
          {
            'id': 3,
            'constant': true,
            'content': '丙',
            'position': 'after_char',
            'insertion_order': 5,
            'extensions': {'position': 7, 'outlet_name': '物品'},
          },
          // No outlet name: placed nowhere.
          {'uid': 4, 'constant': true, 'content': '丁', 'position': 7},
          {'uid': 5, 'constant': true, 'content': '后', 'position': 1},
        ],
      });
      final result = compile(
        '{{outlet::成就}}|{{outlet::物品}}',
        books: [ScopedWorldBook(book)],
      );
      // Highest order first; an entry's own content is resolved during the
      // scan, before any outlet is set.
      expect(result.messages.first.content, '乙\n甲[]|丙');
      expect(result.messages[1].content, '后');
      expect(result.outlets, {'成就': '乙\n甲[]', '物品': '丙'});
      expect(
        result.diagnostics.where((d) => d.code.startsWith('world_book')),
        isEmpty,
      );
    });
  });

  group('instruct macros', () {
    // ST 1.19.0 instruct-macros.js reads power_user.instruct, .sysprompt
    // and .context: here the text preset's templates.
    final bundle = PresetImporter().decode({
      'preset': {'temp': 1},
      'instruct': {
        'input_sequence': '<in {{user}}>',
        'output_sequence': '<out {{name}}>',
        'first_output_sequence': '',
        'last_output_sequence': '<last-out>',
        'first_input_sequence': '<first-in>',
        'last_input_sequence': '',
        'input_suffix': '</in>',
        'output_suffix': '</out>',
        'system_sequence': '<sys>',
        'system_suffix': '</sys>',
        'last_system_sequence': '<last-sys>',
        'story_string_prefix': '<story>',
        'story_string_suffix': '</story>',
        'stop_sequence': '<stop>',
        'user_alignment_message': '继续',
      },
      'context': {'example_separator': '***{{char}}', 'chat_start': '<开始>'},
      'sysprompt': {'content': '写{{char}}的回复'},
    });
    (String, String) run(
      String source, {
      ImportedPreset? preset,
      String system = '',
    }) {
      final engine = MacroEngine(
        env: MacroEnv.of(
          card: {
            'name': '道渊',
            'description': '[{{systemPrompt}}]',
            'system_prompt': system,
          },
          user: '阿雨',
          preset: preset,
        ),
        clock: DateTime.utc(2026),
        seed: 1,
      );
      final text = engine.render(source);
      return (text, engine.diagnostics.map((d) => d.code).join(','));
    }

    const instruct =
        '{{instructStoryStringPrefix}}|{{instructStoryStringSuffix}}|'
        '{{instructUserPrefix}}|{{instructInput}}|{{instructUserSuffix}}|'
        '{{instructAssistantPrefix}}|{{instructOutput}}|'
        '{{instructAssistantSuffix}}|{{instructSeparator}}|'
        '{{instructSystemPrefix}}|{{instructSystemSuffix}}|'
        '{{instructFirstAssistantPrefix}}|{{instructFirstOutputPrefix}}|'
        '{{instructLastAssistantPrefix}}|{{instructLastOutputPrefix}}|'
        '{{instructStop}}|{{instructUserFiller}}|'
        '{{instructSystemInstructionPrefix}}|{{instructFirstUserPrefix}}|'
        '{{instructFirstInput}}|{{instructLastUserPrefix}}|'
        '{{INSTRUCTLASTINPUT}}';
    const system =
        '{{systemPrompt}}|{{defaultSystemPrompt}}|{{instructSystem}}|'
        '{{instructSystemPrompt}}';
    const context = '{{exampleSeparator}}|{{chatSeparator}}|{{chatStart}}';

    test('instruct mode gives the template text as written', () {
      // Not resolved again; an empty first/last sequence falls back.
      expect(run(instruct, preset: bundle), (
        '<story>|</story>|<in {{user}}>|<in {{user}}>|</in>|'
            '<out {{name}}>|<out {{name}}>|</out>|</out>|<sys>|</sys>|'
            '<out {{name}}>|<out {{name}}>|<last-out>|<last-out>|<stop>|继续|'
            '<last-sys>|<first-in>|<first-in>|<in {{user}}>|<in {{user}}>',
        '',
      ));
      expect(run(context, preset: bundle), (
        '***{{char}}|***{{char}}|<开始>',
        '',
      ));
      expect(run('{{instructInput::x}}{{chatStart}}a{{/chatStart}}'), (
        '{{instructInput::x}}{{chatStart}}a{{/chatStart}}',
        'invalid_macro_arguments',
      ));
    });

    test('the system prompt prefers the card\'s, resolved', () {
      expect(run(system, preset: bundle, system: ' 卡{{char}} '), (
        '卡道渊|写{{char}}的回复|写{{char}}的回复|写{{char}}的回复',
        '',
      ));
      expect(run(system, preset: bundle), (
        '写{{char}}的回复|写{{char}}的回复|写{{char}}的回复|写{{char}}的回复',
        '',
      ));
      // A card field's env has no card fields, so no card system prompt.
      expect(run('{{description}}', preset: bundle, system: '卡'), (
        '[写{{char}}的回复]',
        '',
      ));
    });

    test('a text preset without a template is ST with it off', () {
      final plain = PresetImporter().decode({
        'preset': {'temp': 1},
        'context': {'chat_start': '<开始>'},
      });
      expect(run(instruct, preset: plain).$1, '|' * 21);
      expect(run(system, preset: plain, system: '卡'), ('|||', ''));
      // The missing separator is the previous template's: a fresh install's.
      expect(run(context, preset: plain), ('***|***|<开始>', ''));
    });

    /// A text completion of [preset] for the card 道渊 and the brief `x`.
    PresetInput text(
      Map<String, dynamic> preset, {
      String type = 'normal',
      Map<String, dynamic> card = const {},
    }) => PresetInput(
      preset: PresetImporter().decode({
        'preset': {'temp': 1},
        ...preset,
      }),
      branchId: 'main',
      throughPosition: 1,
      brief: 'x',
      generationType: type,
      clock: DateTime.utc(2026),
      randomSeed: 1,
      userName: '阿雨',
      card: CardImporter().decode(
        Uint8List.fromList(utf8.encode(jsonEncode({'name': '道渊', ...card}))),
        'card.json',
      ),
    );

    test('instruct templates are migrated as ST selects them', () {
      // instruct-mode.js `migrateInstructModeSettings` (L55-105), run on
      // every template ST selects or imports (L834).
      const empty = {'story_string': '', 'chat_start': ''};
      final legacy = text({
        'context': empty,
        'instruct': {
          'input_sequence': '<in>',
          'output_sequence': '<out>',
          'output_suffix': '</old>',
          'separator_sequence': '</out>',
          'names': true,
          'system_sequence_prefix': '<sys>',
        },
      });
      expect(legacy.env.instruct, {
        // What the template lacks keeps a fresh install's (Alpaca's).
        'first_output_sequence': '',
        'last_output_sequence': '',
        'stop_sequence': '',
        'activation_regex': '',
        'wrap': true,
        'macro': true,
        'input_sequence': '<in>',
        'output_sequence': '<out>',
        'output_suffix': '</out>',
        'names_behavior': 'always',
        'input_suffix': '',
        'system_sequence': '',
        'system_suffix': '',
        'user_alignment_message': '',
        'last_system_sequence': '',
        'first_input_sequence': '',
        'last_input_sequence': '',
        'skip_examples': false,
        'system_same_as_user': false,
        'sequences_as_stop_strings': true,
        'story_string_prefix': '',
        'story_string_suffix': '',
      });
      expect(run('{{instructSeparator}}', preset: legacy.preset).$1, '</out>');
      // Compile reads the same template: names, sequences as stop strings.
      final result = PromptCompiler().compile(legacy);
      expect(result.completionText, '<in>\n阿雨: x\n<out>\n道渊:');
      expect(result.stopStrings, containsAll(['\n<in>', '\n<out>']));
      String names(Map<String, dynamic> instruct) =>
          text({
                'instruct': {'output_sequence': '<out>', ...instruct},
              }).env.instruct['names_behavior']
              as String;
      expect(names({'names': false, 'names_force_groups': true}), 'force');
      expect(names({'names': 0}), 'none');
      expect(names({}), 'force');
      expect(names({'names_behavior': 'none'}), 'none');
    });

    test('without a context template a fresh ST install\'s is used', () {
      // default/content/settings.json's power_user.context after
      // power-user.js `loadContextSettings`.
      final plain = text(
        {},
        card: {'description': '描述', 'personality': '冷静', 'scenario': '山中'},
      );
      expect(run(context, preset: plain.preset), ('***|***|***', ''));
      final result = PromptCompiler().compile(plain);
      expect(
        result.completionText,
        startsWith('描述\n道渊\'s personality: 冷静\nScenario: 山中\n***\n阿雨: x\n'),
      );
      expect(result.stopStrings, unorderedEquals(['\n***', '\n阿雨:']));
    });

    test('a context template gets ST\'s defaults for what it lacks', () {
      // `#context_presets` change (power-user.js L2037-2085): control
      // defaults (L354-370), the rest from the template selected before.
      final partial = text(
        {
          'context': {'story_string': '[{{description}}]'},
        },
        card: {'description': '描述'},
      );
      expect(run(context, preset: partial.preset), ('***|***|***', ''));
      final result = PromptCompiler().compile(partial);
      expect(result.completionText, startsWith('[描述]\n***\n阿雨: x\n'));
      // `use_stop_strings` defaults to off; the character's name stops a
      // continue after a user message only (script.js L3033-3042).
      expect(result.stopStrings, ['\n阿雨:']);
      expect(
        PromptCompiler()
            .compile(
              text({
                'context': {'story_string': ''},
              }, type: 'continue'),
            )
            .stopStrings,
        unorderedEquals(['\n阿雨:', '\n道渊:']),
      );
    });

    test('a stored env keeps the templates it was compiled with', () {
      // Tasks freeze MacroEnv.of's templates; older ones as written.
      final engine = MacroEngine(
        env: MacroEnv.fromJson({
          'textCompletion': true,
          'instruct': {'output_sequence': 'O', 'separator_sequence': 'S'},
          'context': <String, dynamic>{},
        }),
        clock: DateTime.utc(2026),
        seed: 1,
      );
      expect(engine.render('{{instructSeparator}}|{{chatStart}}'), '|');
    });

    test('a chat preset has no templates; it is reported', () {
      final (text, codes) = run('$instruct|$system|$context', system: '卡');
      expect(text, '|' * 28);
      expect(codes.split(','), everyElement('advanced_formatting_unavailable'));
      expect(codes.split(','), hasLength(29));
    });

    test('text completion without a system prompt template drops the '
        'card\'s system prompt and post-history instructions', () {
      // script.js `Generate` L4686-4697 and L4748-4765: with the system
      // prompt disabled `system` is empty and nothing follows the history.
      final result = PromptCompiler().compile(
        PresetInput(
          preset: PresetImporter().decode({
            'preset': {'temp': 1},
            'context': {'story_string': '[{{#if system}}{{system}}{{/if}}]'},
          }),
          branchId: 'main',
          throughPosition: 1,
          brief: '',
          generationType: 'continue',
          clock: DateTime.utc(2026),
          randomSeed: 1,
          userName: '阿雨',
          card: CardImporter().decode(
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'name': '道渊',
                  'system_prompt': '卡',
                  'post_history_instructions': '后',
                }),
              ),
            ),
            'card.json',
          ),
        ),
      );
      expect(result.completionText, '[]\n***\n');
    });
  });

  group('extension macros', () {
    test('extensions SillyDraft lacks give ST\'s output with nothing set', () {
      // Author's Note, Summarize and Character Expressions in a fresh ST
      // install: no note, no summary, no fallback expression, no sprites,
      // the default classifier labels.
      expect(
        _run(
          '{{authorsNote}}|{{charAuthorsNote}}|{{defaultAuthorsNote}}|'
          '{{summary}}|{{lastExpression}}|{{LASTEXPRESSION::道渊}}|'
          '{{defaultExpression}}',
        ),
        ('||||||#none', ''),
      );
      expect(_run('{{availableExpressions}}'), (
        'admiration, amusement, anger, annoyance, approval, caring, '
            'confusion, curiosity, desire, disappointment, disapproval, '
            'disgust, embarrassment, excitement, fear, gratitude, grief, joy, '
            'love, nervousness, optimism, pride, realization, relief, '
            'remorse, sadness, surprise, neutral',
        '',
      ));
      // `lastExpression` resolves its argument itself.
      expect(_run('{{lastExpression::{{setvar::a::1}}}}{{getvar::a}}'), (
        '1',
        '',
      ));
      expect(_run('{{summary::x}}{{lastExpression::a::b}}'), (
        '{{summary::x}}{{lastExpression::a::b}}',
        'invalid_macro_arguments,invalid_macro_arguments',
      ));
      expect(_run('{{if summary}}y{{else}}n{{/if}}'), ('n', ''));
      expect(_run('{{if defaultExpression}}y{{else}}n{{/if}}'), ('y', ''));
    });

    test('reasoning macros read the reasoning template, else a fresh '
        'install\'s', () {
      String run(MacroEnv env) =>
          MacroEngine(env: env, clock: DateTime.utc(2026), seed: 1).render(
            '{{reasoningPrefix}}|{{reasoningSuffix}}|{{reasoningSeparator}}',
          );
      final bundle = PresetImporter().decode({
        'preset': {'temp': 1},
        'reasoning': {'name': 'x', 'prefix': '<思 {{user}}>', 'suffix': '</思>'},
      });
      final env = MacroEnv.of(user: '阿雨', preset: bundle);
      // As written, and a field the template lacks is empty.
      expect(run(env), '<思 {{user}}>|</思>|');
      expect(run(MacroEnv.fromJson(env.toJson())), '<思 {{user}}>|</思>|');
      for (final env in [
        const MacroEnv(),
        MacroEnv.of(user: '阿雨'),
        MacroEnv.of(
          user: '阿雨',
          preset: PresetImporter().decode({'prompts': <Object>[]}),
        ),
        MacroEnv.fromJson({}),
      ]) {
        expect(run(env), '<think>|</think>|\n');
      }
    });

    test('image generation prefixes come from the card', () {
      String run(Map<String, dynamic>? card) => MacroEngine(
        env: MacroEnv.of(card: card, user: '阿雨'),
        clock: DateTime.utc(2026),
        seed: 1,
      ).render('{{charPrefix}}|{{charNegativePrefix}}|{{description}}');
      final card = {
        'spec': 'chara_card_v3',
        'data': {
          'name': '道渊',
          'description': '[{{charPrefix}}]',
          'extensions': {
            'sd_character_prompt': {
              'positive': 'masterpiece, {{char}}',
              'negative': 'lowres',
            },
          },
        },
      };
      // As written, also in a card field.
      expect(run(card), 'masterpiece, {{char}}|lowres|[masterpiece, {{char}}]');
      expect(run(null), '||');
      expect(
        run({
          'name': '道渊',
          'extensions': {
            'sd_character_prompt': {'positive': 1, 'negative': ''},
          },
        }),
        '||',
      );
    });
  });
}
