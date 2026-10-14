part of 'story_repository.dart';

extension CardStartOperations on StoryRepository {
  /// Creates a novel from a card, then seeds MVU variables from the card's
  /// `[InitVar]` entries and the opening's own update commands, as MVU
  /// initialises a new chat. A broken InitVar entry never blocks creation.
  Future<Novel> createNovelFromCard({
    required String resourceId,
    required String title,
    String userName = '主角',
    String persona = '',
    String pointOfView = '第三人称',
    int greetingIndex = 0,
    String? openingOverride,
    DateTime? openingClock,
  }) async {
    final novel = await _createNovelFromCard(
      resourceId: resourceId,
      title: title,
      userName: userName,
      persona: persona,
      pointOfView: pointOfView,
      greetingIndex: greetingIndex,
      openingOverride: openingOverride,
      openingClock: openingClock,
    );
    try {
      await MvuService(
        this,
        clock: () => openingClock ?? DateTime.now().toUtc(),
      ).ensureInitialized(novel.activeBranchId);
    } catch (_) {
      // The novel exists already; the variable manager reports the state
      // and lets the author reload InitVar or reprocess.
    }
    return novel;
  }

  Future<Novel> _createNovelFromCard({
    required String resourceId,
    required String title,
    String userName = '主角',
    String persona = '',
    String pointOfView = '第三人称',
    int greetingIndex = 0,
    String? openingOverride,
    DateTime? openingClock,
  }) => _write(() async {
    final resource = await getResource(resourceId);
    if (resource.kind != ResourceKind.character) {
      throw const FormatException('需要角色卡资源');
    }
    final card = const CardImporter().decode(
      Uint8List.fromList(utf8.encode(jsonEncode(resource.data))),
      'card.json',
    );
    if (greetingIndex < 0 || greetingIndex >= card.greetings.length) {
      throw const FormatException('备用开场不存在');
    }
    final macros = MacroEngine(
      values: {
        'char': card.name,
        'user': userName,
        'description': card.description,
        'personality': card.personality,
        'scenario': card.scenario,
        'persona': persona,
      },
      clock: openingClock ?? DateTime.now().toUtc(),
      seed: 0,
    );
    final rendered = macros.render(card.greetings[greetingIndex]);
    final opening = openingOverride ?? rendered;
    if (openingOverride == null &&
        macros.diagnostics.any((d) => d.severity == DiagnosticSeverity.error)) {
      throw FormatException(
        '开场包含暂不支持的宏，请先编辑开场：${macros.diagnostics.map((d) => d.message).join('；')}',
      );
    }
    final novel = await createNovel(
      title: title,
      synopsis: card.scenario,
      pointOfView: pointOfView,
    );
    final chapter = await createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText(opening),
    );
    await setSetting('writing/${novel.activeBranchId}', {
      'cardId': resourceId,
      'userName': userName,
      'persona': persona,
      'greetingIndex': greetingIndex,
    });
    await saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: card.name,
      content: [
        card.description,
        card.personality,
      ].where((s) => s.isNotEmpty).join('\n\n'),
      atChapterId: chapter.id,
      provenance: {'type': 'card', 'resourceId': resourceId},
      data: {'cardId': resourceId},
    );
    if (card.scenario.isNotEmpty) {
      await saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.world,
        name: '开场设定',
        content: card.scenario,
        atChapterId: chapter.id,
        provenance: {'type': 'card', 'resourceId': resourceId},
      );
    }
    for (final entry in card.worldBook?.entries ?? <WorldBookEntry>[]) {
      await saveLoreEntry(
        branchId: novel.activeBranchId,
        kind: LoreKind.world,
        name: entry.comment.isNotEmpty
            ? entry.comment
            : entry.keys.isNotEmpty
            ? entry.keys.join('、')
            : '世界书 ${entry.id}',
        content: entry.content,
        atChapterId: chapter.id,
        provenance: {
          'type': 'card',
          'resourceId': resourceId,
          'worldBookEntryId': entry.id,
        },
        data: {'worldBookOnly': true, 'entry': entry.raw},
      );
    }
    if (macros.local.isNotEmpty || macros.global.isNotEmpty) {
      await setBranchVariables(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        expectedVersion: 0,
        local: macros.local,
        global: macros.global,
      );
    }
    return novel;
  });
}
