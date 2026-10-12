import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('display regex uses frozen task context without changing document or variables', () {
    final content = ManuscriptContent.fromDelta([
      {
        'insert': '雾',
        'attributes': {'bold': true},
      },
      {'insert': '归来\n后续正文\n'},
    ]);
    final task = GenerationTask(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.completed,
      partialText: '雾归来',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'macroValues': {'char': '阿雾'},
        'variableResult': {
          'local': {'seen': 'old'},
          'global': <String, dynamic>{},
        },
        'outputRegex': [
          {
            'findRegex': '/雾/g',
            'replaceString': '{{char}}的薄雾{{setvar::seen::new}}',
            'placement': [2],
            'markdownOnly': true,
          },
          {
            'findRegex': '/正文/g',
            'replaceString': '不能出现在显示阶段',
            'placement': [2],
            'promptOnly': true,
          },
        ],
      },
    );
    final original = content.encoded;
    final shown = ManuscriptPresentation.fromTask(content, task);
    expect(shown.content.text, '阿雾的薄雾归来\n后续正文\n');
    expect(shown.content.delta.first['attributes'], {'bold': true});
    expect(
      shown.sourceOffset(shown.content.text.indexOf('后续')),
      content.text.indexOf('后续'),
    );
    expect(
      shown.displayOffset(content.text.indexOf('后续')),
      shown.content.text.indexOf('后续'),
    );
    expect(content.encoded, original);
    expect(
      ((task.input['variableResult'] as Map)['local'] as Map)['seen'],
      'old',
    );
  });
}
