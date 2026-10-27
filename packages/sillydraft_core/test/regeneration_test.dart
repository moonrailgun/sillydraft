import 'dart:convert';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repo;
  late TaskRunner runner;
  late WritingService service;
  late String branchId;
  final connection = ModelConnection(
    id: 'test',
    name: 'Test',
    baseUrl: 'http://localhost:1/v1',
    model: 'test',
  );

  setUp(() async {
    repo = StoryRepository.memory();
    runner = TaskRunner(
      repository: repo,
      providerFactory: (_) async => throw StateError('No model calls'),
    );
    service = WritingService(repository: repo, runner: runner);
    branchId = (await repo.createNovel(title: '重新生成')).activeBranchId;
  });
  tearDown(() async {
    await runner.close();
    await repo.close();
  });

  Future<Chapter> chapter(String text, int version) async {
    final chapter = await repo.createChapter(
      branchId: branchId,
      content: ManuscriptContent.plainText(text),
    );
    await repo.setBranchVariables(
      branchId: branchId,
      chapterId: chapter.id,
      expectedVersion: version - 1,
      local: {
        'where': text,
        ...MvuData(statData: {'stage': version}).toStored(),
      },
      global: {'when': text},
    );
    return chapter;
  }

  test(
    'regeneration uses only the previous chapter state and history',
    () async {
      final previous = await chapter('PREVIOUS_CHAPTER', 1);
      final lore = await repo.saveLoreEntry(
        branchId: branchId,
        kind: LoreKind.character,
        name: '人物',
        content: 'PREVIOUS_LORE',
      );
      final current = await chapter('DISCARDED_CHAPTER', 2);
      await repo.saveLoreEntry(
        branchId: branchId,
        id: lore.id,
        expectedRevisionId: lore.revisionId,
        kind: lore.kind,
        name: lore.name,
        content: 'DISCARDED_LORE',
      );
      await chapter('FUTURE_CHAPTER', 3);
      final draft = await service.prepare(
        branchId: branchId,
        chapterId: current.id,
        connection: connection,
        brief:
            '重写。{{getvar::where}} {{getglobalvar::when}} {{lastCharMessage}}',
        regenerate: true,
      );
      final request = jsonEncode(draft.input['request']);
      expect(request, contains('PREVIOUS_CHAPTER'));
      expect(request, contains('PREVIOUS_LORE'));
      expect(request, isNot(contains('DISCARDED')));
      expect(request, isNot(contains('FUTURE')));
      expect(draft.input['sourceRevisions'], [
        {'chapterId': previous.id, 'revisionId': previous.revisionId},
      ]);
      expect(draft.input['variableBaseVersion'], 3);
      expect(
        (draft.input['variableResult'] as Map)['local']['where'],
        'PREVIOUS_CHAPTER',
      );
      expect((draft.input['mvu'] as Map)['base']['stat_data'], {'stage': 1});
      expect(draft.baseRevisionId, current.revisionId);
      expect(draft.kind, TaskKind.rewrite);
      final task = await repo.createTask(
        branchId: branchId,
        chapterId: current.id,
        kind: draft.kind,
        input: draft.input,
      );
      expect(task.macros(message: '新文').render('{{lastMessageId}}'), '1');
    },
  );

  test(
    'first chapter regeneration does not reuse its variables or initvar',
    () async {
      await repo.saveLoreEntry(
        branchId: branchId,
        kind: LoreKind.character,
        name: '人物',
        content: 'INITIAL_LORE',
      );
      final current = await chapter(
        '<initvar>{"secret":"DISCARDED"}</initvar>旧文',
        1,
      );
      await repo.saveLoreEntry(
        branchId: branchId,
        kind: LoreKind.character,
        name: '后来认识的人',
        content: 'DISCARDED_LORE',
      );
      final draft = await service.prepare(
        branchId: branchId,
        chapterId: current.id,
        connection: connection,
        brief:
            '重写。{{getvar::where}} {{getglobalvar::when}} {{lastCharMessage}}',
        regenerate: true,
        worldBooks: [
          ScopedWorldBook(
            WorldBook.fromJson({
              'name': '世界设定',
              'entries': [
                {'content': 'INITIAL_WORLD_BOOK', 'constant': true},
              ],
            }),
          ),
        ],
      );
      expect(jsonEncode(draft.input['request']), contains('INITIAL_LORE'));
      expect(
        jsonEncode(draft.input['request']),
        contains('INITIAL_WORLD_BOOK'),
      );
      expect(jsonEncode(draft.input['request']), isNot(contains('DISCARDED')));
      expect(draft.input['sourceRevisions'], isEmpty);
      expect(draft.input['mvu'], isNull);
      expect(draft.input['variableBaseVersion'], 1);
      expect((draft.input['variableResult'] as Map)['local']['where'], isNull);
      final seeded = await MvuService(repo).baseFor(
        branchId,
        current.id,
        includeCurrentChapter: false,
        entries: [
          const MvuInitEntry(
            book: 'test',
            comment: '[InitVar]',
            content: 'remembered: "{{lastCharMessage}}"',
          ),
        ],
      );
      expect(seeded!.statData['remembered'], '');
    },
  );

  test('ordinary rewrites still see the chapter being edited', () async {
    final current = await chapter('EDIT_THIS_CHAPTER', 1);
    final draft = await service.prepare(
      branchId: branchId,
      chapterId: current.id,
      connection: connection,
      brief: '润色当前正文。',
      rewrite: true,
    );
    expect(jsonEncode(draft.input['request']), contains('EDIT_THIS_CHAPTER'));
    expect(
      (draft.input['variableResult'] as Map)['local']['where'],
      'EDIT_THIS_CHAPTER',
    );
  });

  test('regeneration rejects append and selection replacement', () async {
    final current = await chapter('旧文', 1);
    for (final append in [true, false]) {
      await expectLater(
        service.prepare(
          branchId: branchId,
          chapterId: current.id,
          connection: connection,
          brief: '重写。',
          regenerate: true,
          append: append,
          rangeStart: append ? null : 0,
          rangeEnd: append ? null : 1,
        ),
        throwsArgumentError,
      );
    }
  });
}
