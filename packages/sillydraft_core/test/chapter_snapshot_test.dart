import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

const _initVar = '''
主角:
  生命: 100
  境界: 凡人
''';

Map<String, dynamic> _card() => {
  'spec': 'chara_card_v2',
  'spec_version': '2.0',
  'data': {
    'name': '道渊',
    'description': '修仙世界',
    'first_mes': '你踏入山门。',
    'character_book': {
      'name': '道渊世界书',
      'entries': [
        {
          'id': 1,
          'keys': <String>[],
          'comment': '[initvar] 初始',
          'constant': true,
          'enabled': false,
          'content': _initVar,
        },
      ],
    },
  },
};

/// Writes the next reply from [replies] for each request, once [gate]
/// allows.
final class _Replies implements ModelProvider {
  _Replies(this.config, this.replies, [this.gate]);
  @override
  final ModelConnection config;
  final List<String> replies;
  final Future<void>? gate;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    await gate;
    yield TextDelta(replies.removeAt(0));
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

void main() {
  test('chapters written with auto-accept each keep their own story state to fork from', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    await repo.storeResource(
      id: 'card',
      kind: ResourceKind.character,
      name: '道渊',
      filename: 'card.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: _card(),
    );
    final novel = await repo.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
      userName: '玖神',
    );
    final branchId = novel.activeBranchId;
    final card = const CardImporter().decode(
      Uint8List.fromList(utf8.encode(jsonEncode(_card()))),
      'card.json',
    );
    final replies = [
      "下山历练。\n_.set('主角.生命', 100, 70);//遇袭",
      "闭关突破。\n_.set('主角.境界', '凡人', '筑基');//突破",
    ];
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => _Replies(c, replies),
    );
    addTearDown(runner.close);
    final service = WritingService(repository: repo, runner: runner);
    final connection = ModelConnection(
      id: 'local',
      name: 'Test',
      baseUrl: 'http://localhost:1234/v1',
      model: 'm',
    );
    final mvu = MvuService(repo);

    /// Adds an empty chapter at the end and writes it, as the reader does.
    Future<Scene> writeChapter(String title) async {
      final chapter = await repo.createChapter(
        branchId: branchId,
        title: title,
      );
      final scene = await repo.createScene(
        branchId: branchId,
        chapterId: chapter.id,
        title: title,
      );
      final task = await service.generate(
        branchId: branchId,
        sceneId: scene.id,
        connection: connection,
        brief: '写下一章',
        append: true,
        card: card,
        expectedRevisionId: scene.revisionId,
        autoAccept: true,
      );
      expect((await runner.wait(task.id)).status, TaskStatus.completed);
      return repo.getScene(branchId: branchId, sceneId: scene.id);
    }

    final opening = (await repo.getStory(branchId)).scenes.single;
    final two = await writeChapter('第2章 下山');
    final three = await writeChapter('第3章 闭关');

    // Accepted without review: the text is in each chapter, nothing waits.
    expect(two.content.text, contains('下山历练。'));
    expect(three.content.text, contains('闭关突破。'));
    expect(
      await repo.listProposals(branchId, status: ProposalStatus.pending),
      isEmpty,
    );

    // Every chapter has its own snapshot of the state.
    Future<Map> stateAt(Scene s) async =>
        (await mvu.storedAt(branchId, sceneId: s.id))!.statData['主角'] as Map;
    expect((await stateAt(opening))['生命'], 100);
    expect((await stateAt(two))['生命'], 70);
    expect((await stateAt(two))['境界'], '凡人');
    expect((await stateAt(three))['生命'], 70);
    expect((await stateAt(three))['境界'], '筑基');

    // Forking at a chapter starts from that chapter's state.
    final fork = await repo.forkBranch(
      branchId: branchId,
      name: '另一条路',
      atSceneId: two.id,
    );
    final forked = (await mvu.storedAt(fork.id))!.statData['主角'] as Map;
    expect(forked['生命'], 70);
    expect(forked['境界'], '凡人');
    expect((await repo.getStory(fork.id)).scenes, hasLength(2));
  });

  test('a changed scene leaves an auto-accepted result for review', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '冲突');
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      title: '一',
    );
    final scene = await repo.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
    );
    final gate = Completer<void>();
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => _Replies(c, ['模型写的'], gate.future),
    );
    addTearDown(runner.close);
    final draft = await WritingService(repository: repo, runner: runner)
        .prepare(
          branchId: novel.activeBranchId,
          sceneId: scene.id,
          connection: ModelConnection(
            id: 'local',
            name: 'Test',
            baseUrl: 'http://localhost:1234/v1',
            model: 'm',
          ),
          brief: '写',
          append: true,
          autoAccept: true,
        );
    expect(draft.input['autoAccept'], isTrue);
    final task = await WritingService(
      repository: repo,
      runner: runner,
    ).startPrepared(draft);
    // The author writes in the scene before the reply lands.
    await repo.saveScene(
      branchId: novel.activeBranchId,
      sceneId: scene.id,
      expectedRevisionId: scene.revisionId,
      content: ManuscriptContent.plainText('作者自己写的'),
    );
    gate.complete();
    expect((await runner.wait(task.id)).status, TaskStatus.completed);
    expect(
      (await repo.getScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
      )).content.text.trim(),
      '作者自己写的',
    );
    expect(
      await repo.listProposals(
        novel.activeBranchId,
        status: ProposalStatus.pending,
      ),
      hasLength(1),
    );
  });
}
