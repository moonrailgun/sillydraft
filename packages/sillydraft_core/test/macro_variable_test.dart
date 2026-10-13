import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

MacroEngine _engine() => MacroEngine(
  values: const {'user': '玖神', 'char': '道渊'},
  clock: DateTime.utc(2026),
  seed: 1,
  local: encodeVariables({
    'stat_data': {
      '主角': {
        '境界': '凡人（DC:0）',
        '生命': 100,
        r'$meta': 'hidden',
        '气运': <String, dynamic>{},
      },
      '世界': {'当前时间': '未知', '备注': '第一行\n第二行'},
      '道侣': ['阿雾', '小满'],
    },
    'mood': '平静',
  }),
  global: encodeVariables({'theme': 'dark'}),
);

void main() {
  for (final name in ['setvar', 'addvar', 'setglobalvar', 'addglobalvar']) {
    test('$name preserves invalid calls without changing variables', () {
      for (final arguments in ['', '::count', '::count::1::extra']) {
        final engine = MacroEngine(
          values: {},
          clock: DateTime.utc(2026),
          seed: 1,
          local: {'count': '2'},
          global: {'count': '3'},
        );
        final source = '{{$name$arguments}}';
        expect(engine.render(source), source);
        expect(engine.local, {'count': '2'});
        expect(engine.global, {'count': '3'});
        expect(engine.diagnostics.single.code, 'invalid_macro_arguments');
        expect(engine.diagnostics.single.severity, DiagnosticSeverity.warning);
      }
    });

    test('$name accepts an explicitly empty value', () {
      final engine = _engine();
      expect(engine.render('{{$name::empty::}}'), '');
      final scope = name.contains('global') ? engine.global : engine.local;
      expect(scope['empty'], name.startsWith('set') ? '' : '0');
      expect(engine.diagnostics, isEmpty);
    });
  }

  test('get_*_variable returns strings as-is and other values as JSON', () {
    final engine = _engine();
    expect(
      engine.render('{{get_message_variable::stat_data.主角.境界}}'),
      '凡人（DC:0）',
    );
    expect(engine.render('{{get_chat_variable::stat_data.主角.生命}}'), '100');
    expect(engine.render('{{get_global_variable::theme}}'), 'dark');
    expect(engine.render('{{get_message_variable::stat_data.道侣[1]}}'), '小满');
    expect(engine.render('{{get_message_variable::missing}}'), 'null');
    expect(
      engine.render('{{get_message_variable::stat_data.主角}}'),
      isNot(contains(r'$meta')),
    );
    expect(engine.render('{{get_character_variable::x}}'), 'null');
    expect(engine.diagnostics, isEmpty);
  });

  test('format_*_variable dumps YAML indented to the line prefix', () {
    final engine = _engine();
    final text = engine.render(
      '状态：\n  {{format_message_variable::stat_data}}\n结束',
    );
    expect(
      text,
      startsWith(
        '状态：\n  主角:\n    境界: 凡人（DC:0）\n    生命: 100\n    气运: {}\n  世界:\n    当前时间: 未知\n    备注: |-\n',
      ),
    );
    expect(text, contains('  道侣:\n    - 阿雾\n    - 小满'));
    expect(text, isNot(contains(r'$meta')));
    expect(text, endsWith('\n结束'));
    expect(engine.render('{{format_message_variable::mood}}'), '平静');
    expect(
      engine.render('{{format_message_variable_quoted::stat_data.世界.当前时间}}'),
      '未知',
    );
    expect(
      engine.render('{{format_global_variable_quoted::}}'),
      'theme: "dark"',
    );
    expect(engine.diagnostics, isEmpty);
  });
}
