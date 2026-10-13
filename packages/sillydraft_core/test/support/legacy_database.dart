import 'package:sillydraft_core/src/migration/legacy_schema.dart';
import 'package:sillydraft_core/src/storage/database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Frozen pre-chapter-only layout, so upgrade tests never start with v8 tables.
void createLegacyDatabase(sqlite.Database db, {int version = 7}) {
  for (final sql in [
    ..._legacyBaseSchema,
    if (version >= 2) ...StoryDatabase.taskSchema.map(legacyChapterSql),
    if (version >= 3) ...StoryDatabase.preferencesSchema.map(legacyChapterSql),
    if (version >= 4) ...StoryDatabase.resourceSchema.map(legacyChapterSql),
    if (version >= 5) ...StoryDatabase.loreSchema.map(legacyChapterSql),
    if (version >= 6) ...StoryDatabase.assetSchema.map(legacyChapterSql),
  ]) {
    db.execute(sql);
  }
  db.execute('PRAGMA user_version = $version');
}

const _legacyBaseSchema = <String>[
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
