import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  final definitions = {
    'KSampler': {
      'python_module': 'nodes',
      'input': {
        'required': {
          'seed': [
            'INT',
            {'control_after_generate': true},
          ],
          'steps': ['INT', <String, dynamic>{}],
          'positive': ['CONDITIONING', <String, dynamic>{}],
        },
      },
    },
    'CLIPTextEncode': {
      'python_module': 'nodes',
      'input': {
        'required': {
          'text': ['STRING', <String, dynamic>{}],
        },
      },
    },
  };
  Map<String, dynamic> canvas() => {
    'nodes': [
      {
        'id': 1,
        'type': 'CLIPTextEncode',
        'widgets_values': ['a harbour'],
      },
      {
        'id': 2,
        'type': 'KSampler',
        'widgets_values': [42, 'randomize', 8],
        'inputs': [
          {'name': 'positive', 'link': 10},
        ],
      },
      {
        'id': 3,
        'type': 'MarkdownNote',
        'widgets_values': ['a note'],
      },
    ],
    'links': [
      [10, 1, 0, 2, 0, 'CONDITIONING'],
    ],
  };
  test('converts standard canvas links and skips seed control widgets', () {
    final result = ComfyWorkflow.parseCanvas(canvas(), definitions);
    expect(result.keys, ['1', '2']);
    expect(result['2']['inputs'], {
      'seed': 42,
      'steps': 8,
      'positive': ['1', 0],
    });
    expect(result['1']['inputs']['text'], 'a harbour');
  });
  test('named widget values win over stale positional values', () {
    final data = canvas();
    (data['nodes'] as List)[1]['widgets_values_named'] = {
      'steps': 12,
      'seed': 7,
    };
    expect(
      ComfyWorkflow.parseCanvas(data, definitions)['2']['inputs']['steps'],
      12,
    );
  });
  test('unsupported canvas features fail explicitly without a size claim', () {
    for (final change in <void Function(Map<String, dynamic>)>[
      (d) => (d['nodes'] as List)[1]['mode'] = 4,
      (d) => (d['nodes'] as List)[1]['type'] = 'MissingNode',
      (d) => (d['nodes'] as List)[1]['widgets_values'] = [42, 'randomize'],
      (d) => d['links'] = <Object>[],
    ]) {
      final data = canvas();
      change(data);
      expect(
        () => ComfyWorkflow.parseCanvas(data, definitions),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('2 MB')),
          ),
        ),
      );
    }
  });
  test('format and size diagnostics are separate', () {
    expect(
      () => ComfyWorkflow.parseNodes({'nodes': <Object>[]}),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          isNot(contains('2 MB')),
        ),
      ),
    );
  });
}
