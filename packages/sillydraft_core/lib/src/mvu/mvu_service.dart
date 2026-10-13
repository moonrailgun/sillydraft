import '../model/story.dart';
import '../st/macro_engine.dart';
import '../st/world_book.dart';
import '../storage/story_repository.dart';
import 'mvu_data.dart';
import 'mvu_init.dart';
import 'mvu_path.dart';
import 'mvu_schema.dart';

/// MVU over a branch's versioned variables: every chapter is a message, its
/// `stat_data` and companions live in the chapter's local variables, and a
/// chapter's record is derived from the previous chapter's record plus the
/// update commands in its own text, as MagVarUpdate derives a message's
/// record from the one before it.
final class MvuService {
  MvuService(this.repository, {DateTime Function()? clock})
    : _clock = clock ?? _utcNow;
  final StoryRepository repository;
  final DateTime Function() _clock;
  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Writing-profile key: `true`/`false` to force schema checks on or off;
  /// absent means on unless the card brings its own `registerMvuSchema`
  /// script, which replaces MVU's structural checks in SillyTavern.
  static const schemaChecksKey = 'mvuSchemaChecks';

  /// Key under `initialized_lorebooks` for a card's unnamed embedded book.
  static const defaultBookName = '角色卡世界书';

  /// `[InitVar]` entries of a world book, in entry order.
  static List<MvuInitEntry> entriesOf(WorldBook book, {String? name}) => [
    for (final entry in book.entries)
      if (MvuInitEntry.matches(entry.comment))
        MvuInitEntry(
          book: name ?? (book.name.isEmpty ? defaultBookName : book.name),
          comment: entry.comment,
          content: entry.content,
        ),
  ];

  /// `[InitVar]` entries of a card's embedded book, from its raw JSON.
  static List<MvuInitEntry> entriesOfCard(Map<String, dynamic> raw) {
    final data = raw['spec'] == null
        ? raw
        : raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    final book = data['character_book'];
    if (book is! Map<String, dynamic>) return const [];
    try {
      final parsed = WorldBook.fromJson(book);
      return entriesOf(
        parsed,
        name: parsed.name.isNotEmpty ? parsed.name : defaultBookName,
      );
    } on FormatException {
      return const [];
    }
  }

  /// Whether a card ships a 酒馆助手 script that registers an MVU schema
  /// (`registerMvuSchema`, the MVU Zod helper). Such cards rely on that
  /// script instead of `$meta` markers, so structural checks must be off.
  static bool usesSchemaScript(Map<String, dynamic> raw) {
    final data = raw['spec'] == null
        ? raw
        : raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    final extensions = data['extensions'];
    if (extensions is! Map) return false;
    final helper = extensions['tavern_helper'];
    if (helper is! Map || helper['scripts'] is! List) return false;
    for (final script in helper['scripts'] as List) {
      if (script is! Map || script['enabled'] == false) continue;
      final content = '${script['content'] ?? ''}';
      if (content.contains('registerMvuSchema') ||
          content.contains('mvu_zod')) {
        return true;
      }
    }
    return false;
  }

  Future<Map<String, dynamic>> _profile(String branchId) async =>
      await repository.getSetting('writing/$branchId') ?? {};

  Future<Map<String, dynamic>?> _resource(Object? id) async {
    if (id is! String) return null;
    try {
      return (await repository.getResource(id)).data;
    } on StoryNotFound {
      return null;
    }
  }

  /// InitVar entries from the branch's card and bound world books.
  Future<List<MvuInitEntry>> initEntries(String branchId) async {
    final profile = await _profile(branchId);
    final entries = <MvuInitEntry>[];
    final card = await _resource(profile['cardId']);
    if (card != null) entries.addAll(entriesOfCard(card));
    for (final id in profile['worldBookIds'] as List? ?? const []) {
      final raw = await _resource(id);
      if (raw == null) continue;
      try {
        entries.addAll(entriesOf(WorldBook.fromJson(raw)));
      } on FormatException {
        // A broken world book cannot seed variables.
      }
    }
    return entries;
  }

  /// Whether update commands are checked against the generated schema.
  Future<bool> schemaChecks(String branchId) async {
    final profile = await _profile(branchId);
    if (profile[schemaChecksKey] case final bool forced) return forced;
    final card = await _resource(profile['cardId']);
    return card == null || !usesSchemaScript(card);
  }

  Future<MacroEngine> _macros(String branchId) async {
    final context = await repository.displayContext(branchId);
    return MacroEngine(values: context.macroValues, clock: _clock(), seed: 0);
  }

  /// Whether structural checks apply, from the writing profile's
  /// [schemaChecksKey] or, failing that, the card's scripts.
  static bool schemaChecksFor(
    Map<String, dynamic> profile,
    Map<String, dynamic>? cardRaw,
  ) {
    if (profile[schemaChecksKey] case final bool forced) return forced;
    return cardRaw == null || !usesSchemaScript(cardRaw);
  }

  /// The record a story starts from before any command runs: every InitVar
  /// entry merged, an `<initvar>` block in [opening] replacing the card
  /// book's values (other books reload on top, as MVU does), the schema
  /// built. Null when nothing seeds variables. [entries] and
  /// [schemaChecks] default to the branch's bound resources.
  Future<MvuData?> seed(
    String branchId, {
    String? opening,
    List<MvuInitEntry>? entries,
    bool? schemaChecks,
    List<String>? errors,
  }) async {
    final all = entries ?? await initEntries(branchId);
    if (all.isEmpty && (opening == null || !opening.contains('<initvar'))) {
      return null;
    }
    final macros = await _macros(branchId);
    final data = MvuData();
    MvuInit.load(data, all, substitute: macros.render, errors: errors);
    if (opening != null) {
      final override = MvuInit.openingOverride(
        opening,
        substitute: macros.render,
        errors: errors,
      );
      if (override != null) {
        data.statData = override;
        final card = all.isEmpty ? null : all.first.book;
        data.initializedLorebooks = {?card: <Object?>[]};
        MvuInit.load(data, all, substitute: macros.render, errors: errors);
      }
    }
    MvuInit.finalizeSchema(data);
    if (!(schemaChecks ?? await this.schemaChecks(branchId))) {
      data.schema = anySchema;
    }
    return data;
  }

  /// [seed] with the opening's own update commands applied: the record of
  /// a story whose only chapter is the opening.
  Future<MvuData?> initialData(
    String branchId, {
    String? opening,
    List<MvuInitEntry>? entries,
    bool? schemaChecks,
    List<String>? errors,
  }) async {
    final data = await seed(
      branchId,
      opening: opening,
      entries: entries,
      schemaChecks: schemaChecks,
      errors: errors,
    );
    if (data != null && opening != null) {
      final macros = await _macros(branchId);
      final result = MvuUpdater.apply(opening, data, substitute: macros.render);
      errors?.addAll(result.errors);
    }
    return data;
  }

  /// The record stored at or before [chapterId]; null when none.
  Future<MvuData?> storedAt(String branchId, {String? chapterId}) async =>
      MvuData.fromStored(
        (await repository.getBranchVariables(
          branchId,
          throughChapterId: chapterId,
        )).local,
      );

  /// Makes a record follow the branch's schema policy: checks on means a
  /// schema rebuilt from the data when the record had none, checks off
  /// means the permissive `any` schema. Needed because stored records keep
  /// the schema they were saved with and the policy can change later.
  static void applySchemaPolicy(MvuData data, bool checks) {
    final any = data.schema['type'] == 'any';
    if (!checks && !any) {
      data.schema = anySchema;
    } else if (checks && any) {
      data.schema = MvuSchema.generate(MvuPath.clone(data.statData));
    }
  }

  /// The record a chapter's update starts from: the one stored at the chapter
  /// before it, or the initial record for the opening chapter (and for any
  /// chapter of a story that was never initialised). An empty [entries]
  /// list falls back to the branch's bound resources; when nothing seeds
  /// variables any more but the chapter already holds a record, that record
  /// is the base, so an unbound card does not switch MVU off.
  Future<MvuData?> baseFor(
    String branchId,
    String chapterId, {
    List<MvuInitEntry>? entries,
    bool? schemaChecks,
    List<String>? errors,
  }) async {
    final story = await repository.getStory(branchId);
    final index = story.chapters.indexWhere((s) => s.id == chapterId);
    if (index < 0) throw const StoryNotFound('章节');
    final checks = schemaChecks ?? await this.schemaChecks(branchId);
    final seeds = entries == null || entries.isEmpty ? null : entries;
    final opening = story.chapters.first.content.text;
    MvuData? base;
    if (index == 0) {
      base = await seed(
        branchId,
        opening: opening,
        entries: seeds,
        schemaChecks: checks,
        errors: errors,
      );
    } else {
      base = await storedAt(branchId, chapterId: story.chapters[index - 1].id);
      base ??= await initialData(
        branchId,
        opening: opening,
        entries: seeds,
        schemaChecks: checks,
        errors: errors,
      );
    }
    base ??= await storedAt(branchId, chapterId: chapterId);
    if (base != null) applySchemaPolicy(base, checks);
    return base;
  }

  /// Makes sure the branch carries a record, as MVU initialises a chat on
  /// load: the opening chapter gets the initial record when it is the only
  /// chapter, otherwise the latest chapter does. Returns the record in force.
  Future<MvuData?> ensureInitialized(String branchId) async {
    final story = await repository.getStory(branchId);
    if (story.chapters.isEmpty) return null;
    final existing = await storedAt(branchId);
    if (existing != null) return existing;
    final only = story.chapters.length == 1;
    final data = await initialData(
      branchId,
      opening: story.chapters.first.content.text,
    );
    if (data == null) return null;
    await _write(branchId, only ? story.chapters.first : story.chapters.last, data);
    return data;
  }

  /// Re-derives one chapter's record from the chapter before it and the
  /// chapter's current text, and stores it.
  Future<MvuUpdateResult?> processChapter(String branchId, String chapterId) async {
    final story = await repository.getStory(branchId);
    final chapter = story.chapters.firstWhere(
      (s) => s.id == chapterId,
      orElse: () => throw const StoryNotFound('章节'),
    );
    final base = await baseFor(branchId, chapterId);
    if (base == null) return null;
    final macros = await _macros(branchId);
    final result = MvuUpdater.apply(
      chapter.content.text,
      base,
      substitute: macros.render,
    );
    await _write(branchId, chapter, base);
    return result;
  }

  /// Re-derives every chapter's record in order from the initial record,
  /// as MVU's "重新处理变量" replays the chat. Returns errors per chapter.
  Future<Map<String, List<String>>> reprocess(String branchId) async {
    final story = await repository.getStory(branchId);
    final errors = <String, List<String>>{};
    final macros = await _macros(branchId);
    final initErrors = <String>[];
    var data = await seed(
      branchId,
      opening: story.chapters.firstOrNull?.content.text,
      errors: initErrors,
    );
    if (data == null) return errors;
    if (initErrors.isNotEmpty) errors['init'] = initErrors;
    for (final chapter in story.chapters) {
      final result = MvuUpdater.apply(
        chapter.content.text,
        data!,
        substitute: macros.render,
      );
      if (result.errors.isNotEmpty) errors[chapter.id] = result.errors;
      await _write(branchId, chapter, data);
      data = data.clone();
    }
    return errors;
  }

  /// Loads InitVar entries not yet applied into the latest record, as the
  /// "重新读取初始变量" action does: new keys arrive, existing ones stay.
  /// Returns null when no entry was loaded; throws [FormatException] when
  /// an entry could not be parsed.
  Future<MvuData?> reloadInitVar(String branchId) async {
    final story = await repository.getStory(branchId);
    if (story.chapters.isEmpty) return null;
    final data = await storedAt(branchId) ?? MvuData();
    data.initializedLorebooks = {};
    final macros = await _macros(branchId);
    final errors = <String>[];
    final updated = MvuInit.load(
      data,
      await initEntries(branchId),
      substitute: macros.render,
      errors: errors,
    );
    if (errors.isNotEmpty) throw FormatException(errors.join('\n'));
    if (!updated) return null;
    MvuInit.finalizeSchema(data);
    if (!await schemaChecks(branchId)) data.schema = anySchema;
    await _write(branchId, story.chapters.last, data);
    return data;
  }

  /// Stores a record edited by hand at [chapterId].
  Future<void> replaceAt(String branchId, String chapterId, MvuData data) async {
    final story = await repository.getStory(branchId);
    final chapter = story.chapters.firstWhere(
      (s) => s.id == chapterId,
      orElse: () => throw const StoryNotFound('章节'),
    );
    await _write(branchId, chapter, data);
  }

  Future<void> _write(String branchId, Chapter chapter, MvuData data) async {
    final current = await repository.getBranchVariables(
      branchId,
      throughChapterId: chapter.id,
    );
    await repository.patchBranchVariables(
      branchId: branchId,
      chapterId: chapter.id,
      local: {...current.local, ...data.toStored()},
    );
  }

  /// A schema that disables structural checks, for cards using their own
  /// schema script.
  static Map<String, dynamic> get anySchema => {'type': 'any'};
}
