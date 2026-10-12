import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// Explicit migrations keep the same database usable by Flutter and the runner.
final class StoryDatabase extends GeneratedDatabase {
  StoryDatabase(super.executor);

  factory StoryDatabase.memory() => StoryDatabase(NativeDatabase.memory());

  factory StoryDatabase.open(String path) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    return StoryDatabase(NativeDatabase.createInBackground(file));
  }

  @override
  int get schemaVersion => 4;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      for (final sql in [
        ...schema,
        ...taskSchema,
        ...preferencesSchema,
        ...resourceSchema,
      ]) {
        await customStatement(sql);
      }
    },
    onUpgrade: (_, from, to) async {
      if (from < 2) {
        for (final sql in taskSchema) {
          await customStatement(sql);
        }
      }
      if (from < 3) {
        for (final sql in preferencesSchema) {
          await customStatement(sql);
        }
      }
      if (from < 4) {
        for (final sql in resourceSchema) {
          await customStatement(sql);
        }
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 5000');
      await customStatement('PRAGMA journal_mode = WAL');
    },
  );

  static const schema = <String>[
    '''CREATE TABLE novels (
      id TEXT PRIMARY KEY, title TEXT NOT NULL CHECK(length(trim(title)) > 0),
      synopsis TEXT NOT NULL, genre TEXT NOT NULL, language TEXT NOT NULL,
      style TEXT NOT NULL, point_of_view TEXT NOT NULL,
      active_branch_id TEXT NOT NULL, cover_asset_id TEXT,
      archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1)),
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE branches (
      id TEXT PRIMARY KEY, novel_id TEXT NOT NULL REFERENCES novels(id),
      name TEXT NOT NULL, parent_branch_id TEXT REFERENCES branches(id),
      fork_scene_id TEXT, fork_revision_id TEXT REFERENCES revisions(id),
      created_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE branch_chapters (
      branch_id TEXT NOT NULL REFERENCES branches(id), chapter_id TEXT NOT NULL,
      title TEXT NOT NULL, position INTEGER NOT NULL CHECK(position >= 0),
      PRIMARY KEY(branch_id, chapter_id)
    )''',
    '''CREATE TABLE revisions (
      id TEXT PRIMARY KEY, novel_id TEXT NOT NULL REFERENCES novels(id),
      scene_id TEXT NOT NULL, origin_branch_id TEXT NOT NULL REFERENCES branches(id),
      parent_revision_id TEXT REFERENCES revisions(id),
      content_json TEXT NOT NULL, created_at INTEGER NOT NULL,
      reason TEXT NOT NULL, source_proposal_id TEXT
    )''',
    '''CREATE TABLE branch_scenes (
      branch_id TEXT NOT NULL, scene_id TEXT NOT NULL, chapter_id TEXT NOT NULL,
      title TEXT NOT NULL, position INTEGER NOT NULL CHECK(position >= 0),
      revision_id TEXT NOT NULL REFERENCES revisions(id),
      PRIMARY KEY(branch_id, scene_id),
      FOREIGN KEY(branch_id, chapter_id) REFERENCES branch_chapters(branch_id, chapter_id)
    )''',
    '''CREATE TABLE proposals (
      id TEXT PRIMARY KEY, branch_id TEXT NOT NULL, scene_id TEXT NOT NULL,
      base_revision_id TEXT NOT NULL REFERENCES revisions(id),
      content_json TEXT NOT NULL, summary TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('pending', 'accepted', 'rejected')),
      accepted_revision_id TEXT REFERENCES revisions(id), task_id TEXT,
      created_at INTEGER NOT NULL,
      FOREIGN KEY(branch_id, scene_id) REFERENCES branch_scenes(branch_id, scene_id)
    )''',
    'CREATE INDEX branches_novel ON branches(novel_id)',
    'CREATE INDEX scenes_order ON branch_scenes(branch_id, chapter_id, position)',
    'CREATE INDEX revisions_scene ON revisions(scene_id)',
    'CREATE INDEX proposals_branch ON proposals(branch_id, status)',
  ];

  static const taskSchema = <String>[
    '''CREATE TABLE generation_tasks (
      id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
      kind TEXT NOT NULL, status TEXT NOT NULL,
      scene_id TEXT, base_revision_id TEXT REFERENCES revisions(id),
      input_json TEXT NOT NULL, partial_text TEXT NOT NULL DEFAULT '',
      reasoning TEXT NOT NULL DEFAULT '', error TEXT NOT NULL DEFAULT '',
      result_json TEXT NOT NULL DEFAULT '{}', retry_of TEXT REFERENCES generation_tasks(id),
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    )''',
    'CREATE INDEX tasks_branch ON generation_tasks(branch_id, created_at)',
    '''CREATE TABLE branch_variables (
      branch_id TEXT PRIMARY KEY REFERENCES branches(id), version INTEGER NOT NULL,
      local_json TEXT NOT NULL, global_json TEXT NOT NULL
    )''',
    '''CREATE TABLE variable_revisions (
      id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
      version INTEGER NOT NULL, scene_id TEXT NOT NULL,
      revision_id TEXT NOT NULL REFERENCES revisions(id),
      local_json TEXT NOT NULL, global_json TEXT NOT NULL, created_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE agent_conversations (
      id TEXT PRIMARY KEY, branch_id TEXT NOT NULL REFERENCES branches(id),
      title TEXT NOT NULL, created_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE agent_messages (
      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES agent_conversations(id) ON DELETE CASCADE,
      role TEXT NOT NULL, content TEXT NOT NULL, metadata_json TEXT NOT NULL,
      position INTEGER NOT NULL, created_at INTEGER NOT NULL
    )''',
  ];

  static const preferencesSchema = <String>[
    'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value_json TEXT NOT NULL)',
    '''CREATE TABLE reading_bookmarks (
      id TEXT PRIMARY KEY, branch_id TEXT NOT NULL, scene_id TEXT NOT NULL,
      label TEXT NOT NULL, offset INTEGER NOT NULL, created_at INTEGER NOT NULL,
      FOREIGN KEY(branch_id,scene_id) REFERENCES branch_scenes(branch_id,scene_id)
    )''',
  ];

  static const resourceSchema = <String>[
    '''CREATE TABLE library_resources (
      id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, filename TEXT NOT NULL,
      source_hash TEXT NOT NULL, data_json TEXT NOT NULL, encrypted_source BLOB NOT NULL,
      parent_id TEXT REFERENCES library_resources(id), archived INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL
    )''',
  ];
}
