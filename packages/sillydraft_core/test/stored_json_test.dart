import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('stored task snapshots remain independent editable copies', () {
    final task = GenerationTask.fromStoredJson(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.queued,
      inputJson: r'{"request":{"messages":[{"content":"第一行\n第二行"}]},"api_key":"secret","unknown":null}',
      partialText: '',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    final copy = task.input;
    (copy['request']['messages'] as List).clear();
    copy.remove('unknown');
    expect(task.input['request'], {
      'messages': [
        {'content': '第一行\n第二行'},
      ],
    });
    expect(task.input.containsKey('unknown'), isTrue);
    expect(task.exportJson().containsKey('api_key'), isFalse);
    expect(task.input['api_key'], 'secret');
  });

  test(
    'stored resources preserve nested data when a consumer edits its copy',
    () {
      final resource = LibraryResource.fromStoredJson(
        id: 'preset',
        kind: ResourceKind.preset,
        name: '预设',
        filename: 'preset.json',
        sourceHash: 'hash',
        createdAt: DateTime.utc(2026),
        dataJson: '{"extensions":{"unknown":[1,true,null,"中文"]}}',
      );
      (resource.data['extensions']['unknown'] as List).clear();
      expect(resource.data, {
        'extensions': {
          'unknown': [1, true, null, '中文'],
        },
      });
    },
  );
}
