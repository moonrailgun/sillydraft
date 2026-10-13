/// Names used only to read databases and backups written before schema 8.
const legacyProjectTables = [
  'novels',
  'branches',
  'branch_chapters',
  'revisions',
  'branch_scenes',
  'proposals',
  'generation_tasks',
  'branch_variables',
  'variable_revisions',
  'agent_conversations',
  'agent_messages',
  'reading_bookmarks',
  'library_resources',
  'lore_versions',
  'analysis_acceptances',
  'branch_candidate_selections',
  'story_assets',
  'app_settings',
];

/// Intermediate migrations still target the legacy layout until v8 rebuilds it.
String legacyChapterSql(String sql) => sql
    .replaceAll('branch_chapters', 'branch_scenes')
    .replaceAll('chapter_id', 'scene_id');
