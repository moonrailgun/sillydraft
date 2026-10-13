import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sillydraft_core/src/migration/legacy_schema.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

import 'support/legacy_database.dart';

void main() {
  test(
    'v7 database merges chapters and remains editable after reopening',
    () async {
      final dir = await Directory.systemTemp.createTemp('chapter-migration-');
      final path = '${dir.path}/old.sqlite';
      addTearDown(() => dir.delete(recursive: true));
      final old = sqlite.sqlite3.open(path);
      createLegacyDatabase(old);
      _seed(old);
      final legacySnapshot = {
        'format': 'sillydraft-project',
        'version': 1,
        'schema': 6,
        'tables': {
          for (final table in legacyProjectTables)
            table: old
                .select('SELECT * FROM $table')
                .map(Map<String, dynamic>.from)
                .toList(),
        },
      };
      old.close();

      var repo = StoryRepository.open(path);
      try {
        final story = await repo.getStory('branch');
        expect(story.chapters.map((c) => c.title), ['第一章', '空白章']);
        expect(story.chapters.first.content.text, '上半章\n下半章\n');
        expect(story.chapters.last.content.text, '\n');
        expect(story.chapters.first.content.delta.first['attributes'], {
          'bold': true,
        });
        final bookmark = (await repo.listBookmarks('branch')).single;
        expect(bookmark.chapterId, 'chapter');
        expect(bookmark.offset, '上半章\n'.length + 1);
        expect(
          (await repo.getReadingProgress('branch'))!['chapterId'],
          'chapter',
        );
        expect(
          (await repo.listConversations('branch')).single['through_chapter_id'],
          'chapter',
        );

        final migrated = await repo.exportProject('novel');
        final fromBackup = ProjectSnapshot.fromJson(legacySnapshot);
        expect(fromBackup.toJson()['schema'], 8);
        final restored = StoryRepository.memory();
        try {
          await restored.restoreProject(fromBackup, encryptedSources: {});
          expect((await restored.getStory('branch')).text, story.text);
          expect(
            (await restored.exportProject('novel')).fingerprint,
            migrated.fingerprint,
          );
        } finally {
          await restored.close();
        }

        final chapter = story.chapters.first;
        final saved = await repo.saveChapter(
          branchId: 'branch',
          chapterId: chapter.id,
          expectedRevisionId: chapter.revisionId,
          content: ManuscriptContent.plainText('修改后的完整一章'),
        );
        final fork = await repo.forkBranch(
          branchId: 'branch',
          name: '新路线',
          atChapterId: chapter.id,
        );
        expect(
          (await repo.getStory(fork.id)).chapters.single.revisionId,
          saved.revisionId,
        );
        await repo.close();
        repo = StoryRepository.open(path);
        expect(
          (await repo.getStory('branch')).chapters.first.content.text,
          '修改后的完整一章\n',
        );
      } finally {
        await repo.close();
      }
      final current = sqlite.sqlite3.open(path);
      try {
        expect(current.select('PRAGMA user_version').single.values.single, 8);
        expect(current.select('PRAGMA foreign_key_check'), isEmpty);
        expect(
          current.select(
            "SELECT name FROM sqlite_master WHERE name = 'branch_scenes'",
          ),
          isEmpty,
        );
      } finally {
        current.close();
      }
    },
  );

  test('invalid legacy content leaves original database intact', () async {
    final dir = await Directory.systemTemp.createTemp('chapter-rollback-');
    final path = '${dir.path}/old.sqlite';
    addTearDown(() => dir.delete(recursive: true));
    final old = sqlite.sqlite3.open(path);
    createLegacyDatabase(old);
    _seed(old);
    old.execute("UPDATE revisions SET content_json = '{}' WHERE id = 'second'");
    old.close();
    final repo = StoryRepository.open(path);
    try {
      await expectLater(
        repo.getStory('branch'),
        throwsA(predicate((e) => e.toString().contains('不支持的正文格式版本'))),
      );
    } finally {
      await repo.close();
    }
    final untouched = sqlite.sqlite3.open(path);
    try {
      expect(untouched.select('PRAGMA user_version').single.values.single, 7);
      expect(untouched.select('SELECT * FROM branch_scenes'), hasLength(2));
      expect(untouched.select('SELECT * FROM branch_chapters'), hasLength(2));
    } finally {
      untouched.close();
    }
  });

  test('invalid references roll back the table rebuild', () async {
    final dir = await Directory.systemTemp.createTemp('chapter-rollback-');
    final path = '${dir.path}/old.sqlite';
    addTearDown(() => dir.delete(recursive: true));
    final old = sqlite.sqlite3.open(path);
    createLegacyDatabase(old);
    _seed(old);
    old.execute("UPDATE reading_bookmarks SET scene_id = 'missing'");
    old.close();
    final repo = StoryRepository.open(path);
    try {
      await expectLater(
        repo.getStory('branch'),
        throwsA(predicate((e) => e.toString().contains('无效引用'))),
      );
    } finally {
      await repo.close();
    }
    final untouched = sqlite.sqlite3.open(path);
    try {
      expect(untouched.select('PRAGMA user_version').single.values.single, 7);
      expect(untouched.select('SELECT * FROM branch_scenes'), hasLength(2));
      expect(
        untouched
            .select('SELECT scene_id FROM reading_bookmarks')
            .single['scene_id'],
        'missing',
      );
    } finally {
      untouched.close();
    }
  });
}

void _seed(sqlite.Database db) {
  db.execute(
    "INSERT INTO novels VALUES ('novel','旧作品','','','','','','branch',NULL,0,1,1)",
  );
  db.execute(
    "INSERT INTO branches VALUES ('branch','novel','主线',NULL,NULL,NULL,1)",
  );
  db.execute(
    "INSERT INTO branch_chapters VALUES ('branch','chapter','第一章',0),('branch','empty','空白章',1)",
  );
  for (final (id, scene, content) in [
    (
      'first',
      's1',
      ManuscriptContent.fromDelta([
        {
          'insert': '上半章\n',
          'attributes': {'bold': true},
        },
      ]),
    ),
    ('second', 's2', ManuscriptContent.plainText('下半章')),
  ]) {
    db.execute(
      'INSERT INTO revisions VALUES (?,\'novel\',?,\'branch\',NULL,?,1,\'create\',NULL)',
      [id, scene, content.encoded],
    );
  }
  db.execute(
    "INSERT INTO branch_scenes VALUES ('branch','s1','chapter','开头',0,'first'),('branch','s2','chapter','后续',1,'second')",
  );
  db.execute(
    "INSERT INTO reading_bookmarks VALUES ('bookmark','branch','s2','书签',1,1)",
  );
  db.execute(
    "INSERT INTO agent_conversations VALUES ('conversation','branch','对话',1,'s2')",
  );
  db.execute('INSERT INTO app_settings VALUES (?,?)', [
    'progress/branch',
    jsonEncode({'sceneId': 's2', 'fraction': .5, 'updatedAt': 1}),
  ]);
}
