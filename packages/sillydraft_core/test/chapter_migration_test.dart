import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/src/migration/chapter_migration.dart';
import 'package:sillydraft_core/src/model/manuscript.dart';
import 'package:test/test.dart';

Map<String, dynamic> revision(
  String id,
  String scene,
  String text,
  int time, {
  String? parent,
  String branch = 'main',
}) => {
  'id': id,
  'novel_id': 'novel',
  'scene_id': scene,
  'origin_branch_id': branch,
  'parent_revision_id': parent,
  'content_json': ManuscriptContent.plainText(text).encoded,
  'created_at': time,
  'reason': 'edit',
  'source_proposal_id': null,
};
Map<String, List<Map<String, dynamic>>> fixture() => {
  'novels': [
    {'id': 'novel'},
  ],
  'branches': [
    {
      'id': 'main',
      'novel_id': 'novel',
      'created_at': 0,
      'fork_scene_id': null,
      'fork_revision_id': null,
    },
    {
      'id': 'fork',
      'novel_id': 'novel',
      'created_at': 4,
      'parent_branch_id': 'main',
      'fork_scene_id': 's2',
      'fork_revision_id': 'r2',
    },
  ],
  'branch_chapters': [
    {
      'branch_id': 'main',
      'chapter_id': 'c1',
      'title': 'Chapter',
      'position': 0,
    },
    {
      'branch_id': 'main',
      'chapter_id': 'empty',
      'title': 'Empty',
      'position': 1,
    },
    {
      'branch_id': 'fork',
      'chapter_id': 'c1',
      'title': 'Fork chapter',
      'position': 0,
    },
  ],
  'branch_scenes': [
    {
      'branch_id': 'main',
      'scene_id': 's1',
      'chapter_id': 'c1',
      'position': 0,
      'title': 'One',
      'revision_id': 'r1b',
    },
    {
      'branch_id': 'main',
      'scene_id': 's2',
      'chapter_id': 'c1',
      'position': 1,
      'title': 'Two',
      'revision_id': 'r2',
    },
    {
      'branch_id': 'fork',
      'scene_id': 's1',
      'chapter_id': 'c1',
      'position': 0,
      'title': 'One',
      'revision_id': 'r1',
    },
    {
      'branch_id': 'fork',
      'scene_id': 's2',
      'chapter_id': 'c1',
      'position': 1,
      'title': 'Two',
      'revision_id': 'rf',
    },
  ],
  'revisions': [
    {
      ...revision('r1', 's1', '', 1),
      'content_json': ManuscriptContent.fromDelta([
        {
          'insert': 'First',
          'attributes': {'bold': true},
        },
        {
          'insert': '\n',
          'attributes': {'header': 2},
        },
        {
          'insert': {'image': 'asset:cover'},
        },
        {'insert': '\n'},
      ]).encoded,
    },
    revision('r2', 's2', 'Second', 2),
    revision('r1b', 's1', 'Edited first', 3, parent: 'r1'),
    revision('rf', 's2', 'Fork second', 5, parent: 'r2', branch: 'fork'),
    revision('deleted', 'gone', 'Deleted history', 6),
  ],
  'proposals': [
    {
      'id': 'p',
      'branch_id': 'main',
      'scene_id': 's2',
      'base_revision_id': 'r2',
      'accepted_revision_id': null,
      'status': 'pending',
      'content_json': ManuscriptContent.plainText('Proposed second').encoded,
    },
    {
      'id': 'stale',
      'branch_id': 'main',
      'scene_id': 's1',
      'base_revision_id': 'r1',
      'accepted_revision_id': null,
      'status': 'pending',
      'content_json': ManuscriptContent.plainText('Old proposal').encoded,
    },
  ],
  'reading_bookmarks': [
    {'id': 'mark', 'branch_id': 'main', 'scene_id': 's2', 'offset': 2},
  ],
  'generation_tasks': [
    {
      'id': 'task',
      'branch_id': 'main',
      'scene_id': 's2',
      'base_revision_id': 'r2',
      'input_json': jsonEncode({
        'throughSceneId': 's2',
        'editSceneId': 's2',
        'originalContent': ManuscriptContent.plainText('Second').toJson(),
        'replacementRange': {'start': 1, 'end': 3},
        'sourceRevisions': [
          {'sceneId': 's1', 'revisionId': 'r1b'},
          {'sceneId': 's2', 'revisionId': 'r2'},
        ],
        'sceneSnapshot': [
          {
            'id': 's1',
            'revisionId': 'r1b',
            'title': 'One',
            'text': 'Edited first\n',
          },
          {'id': 's2', 'revisionId': 'r2', 'title': 'Two', 'text': 'Second\n'},
        ],
      }),
    },
  ],
  'agent_conversations': [
    {'id': 'chat', 'branch_id': 'main', 'through_scene_id': 's2'},
  ],
  'agent_messages': [
    {
      'id': 'message',
      'conversation_id': 'chat',
      'metadata_json': jsonEncode({
        'toolName': 'read_scene',
        'arguments': jsonEncode({'sceneId': 's2'}),
        'local': {'sceneId': 'user value'},
      }),
    },
  ],
  'app_settings': [
    {
      'key': 'progress/main',
      'value_json': jsonEncode({'sceneId': 's2', 'fraction': 0.5}),
    },
  ],
  'variable_revisions': [
    {
      'id': 'v2',
      'branch_id': 'main',
      'scene_id': 's2',
      'revision_id': 'r2',
      'version': 1,
      'local_json': '{"sceneId":"leave alone"}',
    },
    {
      'id': 'v1',
      'branch_id': 'main',
      'scene_id': 's1',
      'revision_id': 'r1b',
      'version': 2,
      'local_json': '{}',
    },
  ],
  'lore_versions': [
    {
      'branch_id': 'main',
      'entity_id': 'entity',
      'at_scene_id': 's2',
      'revision_id': 'l2',
      'sequence': 1,
      'data_json': '{"name":"behind_scene_label"}',
      'provenance_json': jsonEncode({'sceneId': 's2', 'revisionId': 'r2'}),
    },
    {
      'branch_id': 'main',
      'entity_id': 'entity',
      'at_scene_id': 's1',
      'revision_id': 'l1',
      'sequence': 2,
      'provenance_json': jsonEncode({'sceneId': 's1', 'revisionId': 'r1b'}),
    },
  ],
  'library_resources': [
    {
      'id': 'resource',
      'data_json': '{"sceneId":"author data"}',
      'encrypted_source': Uint8List.fromList([1, 2, 3]),
    },
  ],
};

void main() {
  test(
    'merges rich content and complete histories independently per branch',
    () {
      final old = fixture();
      final migrated = migrateLegacyChapters(old);
      expect(migrated.containsKey('branch_scenes'), isFalse);
      expect(migrated['branch_chapters'], hasLength(3));
      final revisions = {for (final r in migrated['revisions']!) r['id']: r};
      String text(Object? id) =>
          ManuscriptContent.decode(revisions[id]!['content_json'] as String)
              .text;
      final main = migrated['branch_chapters']![0];
      final fork = migrated['branch_chapters']![2];
      expect(text(main['revision_id']), 'Edited first\nSecond\n');
      expect(text(fork['revision_id']), 'First\n\uFFFC\nFork second\n');
      expect(text(migrated['branch_chapters']![1]['revision_id']), '\n');
      expect(text('deleted'), 'Deleted history\n');
      final forkContent = ManuscriptContent.decode(
        revisions[fork['revision_id']]!['content_json'] as String,
      );
      expect(forkContent.delta.first['attributes'], {'bold': true});
      expect(forkContent.delta[1]['attributes'], {'header': 2});
      expect(forkContent.delta[2]['insert'], {'image': 'asset:cover'});
      var cursor = main['revision_id'];
      final history = <String>[];
      while (cursor != null) {
        history.add(text(cursor));
        cursor = revisions[cursor]!['parent_revision_id'];
      }
      expect(history, [
        'Edited first\nSecond\n',
        'First\n\uFFFC\nSecond\n',
        'First\n\uFFFC\n',
      ]);
      expect(old['branch_scenes']![0].containsKey('scene_id'), isTrue);
      expect(
        old['proposals']![0]['content_json'],
        ManuscriptContent.plainText('Proposed second').encoded,
      );
      expect(
        migrated['library_resources']!.single['encrypted_source'],
        isA<Uint8List>(),
      );
      expect(migrated, migrateLegacyChapters(old));
    },
  );

  test(
    'preserves proposal safety, offsets, scoped tasks and state priority',
    () {
      final migrated = migrateLegacyChapters(fixture());
      final main = migrated['branch_chapters']!.first;
      final proposal = migrated['proposals']!.first;
      expect(proposal['chapter_id'], 'c1');
      expect(proposal['base_revision_id'], main['revision_id']);
      expect(
        ManuscriptContent.decode(proposal['content_json'] as String).text,
        'Edited first\nProposed second\n',
      );
      expect(
        migrated['proposals']![1]['base_revision_id'],
        isNot(main['revision_id']),
      );
      expect(migrated['reading_bookmarks']!.single['offset'], 15);
      final input = jsonDecode(
        migrated['generation_tasks']!.single['input_json'] as String,
      ) as Map;
      expect(input['throughChapterId'], 'c1');
      expect(input['sourceRevisions'], [
        {'chapterId': 'c1', 'revisionId': main['revision_id']},
      ]);
      expect(
        (input['chapterSnapshot'] as List).single['text'],
        'Edited first\nSecond\n',
      );
      expect(input['replacementRange'], {'start': 14, 'end': 16});
      expect(
        ManuscriptContent.fromJson(
          input['originalContent'] as Map<String, dynamic>,
        ).text,
        'Edited first\nSecond\n',
      );
      final meta = jsonDecode(
        migrated['agent_messages']!.single['metadata_json'] as String,
      ) as Map;
      expect(meta['toolName'], 'read_chapter');
      expect(jsonDecode(meta['arguments'] as String), {'chapterId': 'c1'});
      expect(meta['local'], {'sceneId': 'user value'});
      expect(migrated['variable_revisions']!.first['version'], 2);
      expect(
        migrated['variable_revisions']!.first['local_json'],
        '{"sceneId":"leave alone"}',
      );
      expect(migrated['lore_versions']!.first['sequence'], 2);
      expect(migrated['lore_versions']!.first['revision_id'], 'l2');
      expect(
        migrated['lore_versions']!.first['data_json'],
        '{"name":"behind_scene_label"}',
      );
      final provenance = jsonDecode(
        migrated['lore_versions']!.first['provenance_json'] as String,
      ) as Map;
      expect(provenance['revisionId'], main['revision_id']);
      final progress = jsonDecode(
        migrated['app_settings']!.single['value_json'] as String,
      ) as Map;
      expect(progress['chapterId'], 'c1');
      expect(progress['fraction'], closeTo(16.5 / 20, 0.00001));
    },
  );

  test(
    'single-scene chapters retain content and IDs; corrupt history fails',
    () {
      final old = fixture();
      old['branch_scenes']!.removeWhere((row) => row['scene_id'] == 's2');
      old['proposals'] = [];
      old['generation_tasks'] = [];
      old['app_settings'] = [];
      old['reading_bookmarks'] = [];
      final migrated = migrateLegacyChapters(old);
      expect(migrated['branch_chapters']!.first['revision_id'], 'r1b');
      old['revisions']!.first['parent_revision_id'] = 'r1b';
      expect(() => migrateLegacyChapters(old), throwsFormatException);
    },
  );

  test('tied timestamps keep every head and detached history stays usable', () {
    final old = fixture();
    for (final row in old['revisions']!) {
      row['created_at'] = 1;
    }
    old['revisions']!.add(
      revision('detached', 's1', 'Unselected history', 7, parent: 'r1'),
    );
    old['proposals']![1]['base_revision_id'] = 'detached';
    old['generation_tasks']!.add({
      ...old['generation_tasks']!.first,
      'id': 'detached-task',
      'scene_id': 's1',
      'base_revision_id': 'detached',
      'input_json': jsonEncode({
        'originalContent': ManuscriptContent.plainText('Unselected history')
            .toJson(),
      }),
    });
    final migrated = migrateLegacyChapters(old);
    final revisions = {for (final r in migrated['revisions']!) r['id']: r};
    String text(Object? id) =>
        ManuscriptContent.decode(revisions[id]!['content_json'] as String).text;
    expect(
      text(migrated['branch_chapters']!.first['revision_id']),
      'Edited first\nSecond\n',
    );
    expect(text('detached'), 'Unselected history\nSecond\n');
    final proposal = migrated['proposals']![1];
    expect(proposal['base_revision_id'], 'detached');
    expect(
      ManuscriptContent.decode(proposal['content_json'] as String).text,
      'Old proposal\nSecond\n',
    );
    final task = jsonDecode(
      migrated['generation_tasks']!.last['input_json'] as String,
    ) as Map<String, dynamic>;
    expect(
      ManuscriptContent.fromJson(
        task['originalContent'] as Map<String, dynamic>,
      ).text,
      'Unselected history\nSecond\n',
    );
  });
}
