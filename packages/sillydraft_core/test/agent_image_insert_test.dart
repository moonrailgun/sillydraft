import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late StoryRepository repo;
  late Chapter chapter;
  late AgentMessage source;

  setUp(() async {
    repo = StoryRepository.memory();
    final novel = await repo.createNovel(title: '插画');
    chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('红伞过桥。\n白船靠岸。'),
    );
    final conversation = await repo.createConversation(
      branchId: chapter.branchId,
    );
    await repo.appendAgentMessage(
      conversation,
      role: 'user',
      content: '本章亮点生图',
    );
    source = (await repo.getAgentMessages(conversation)).single;
  });
  tearDown(() => repo.close());

  Future<String> image(String? quote) async => (await repo.storeAsset(
    branchId: chapter.branchId,
    name: '插画',
    prepared: PreparedAsset(
      hash: 'a' * 64,
      thumbnailHash: 'b' * 64,
      width: 1,
      height: 1,
      byteLength: 1,
    ),
    metadata: {
      if (quote != null)
        'illustrationAnchor': {
          'chapterId': chapter.id,
          'revisionId': chapter.revisionId,
          'quote': quote,
        },
    },
  )).id;

  Future<Chapter> current() =>
      repo.getChapter(branchId: chapter.branchId, chapterId: chapter.id);

  test(
    'batch inserts at each quote in result order and skips existing images',
    () async {
      final umbrella = await image('红伞过桥。');
      final bridge = await image('红伞过桥。');
      final boat = await image('白船靠岸。');
      await repo.insertAgentIllustration(
        branchId: chapter.branchId,
        assetId: boat,
        source: source,
      );
      final ids = [umbrella, bridge, boat];
      Future<int> insert() => repo.insertAgentIllustrations(
        branchId: chapter.branchId,
        assetIds: ids,
        source: source,
      );
      expect(await insert(), 2);
      final inserted = await current();
      expect(
        inserted.content.delta
            .where((op) => op['insert'] is Map)
            .map((op) => (op['insert'] as Map)['image']),
        ids.map((id) => 'asset:$id'),
      );
      expect(inserted.content.text, '红伞过桥。\n\uFFFC\n\uFFFC\n白船靠岸。\n\uFFFC\n\n');
      expect(await insert(), 0);
      expect((await current()).revisionId, inserted.revisionId);
    },
  );

  for (final quote in [null, '不存在']) {
    test('batch rolls back every insertion when a quote is $quote', () async {
      final invalid = await image(quote);
      final valid = await image('白船靠岸。');
      final revisions = await repo.listRevisions(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      );
      await expectLater(
        repo.insertAgentIllustrations(
          branchId: chapter.branchId,
          assetIds: [invalid, valid],
          source: source,
        ),
        throwsFormatException,
      );
      expect((await current()).revisionId, chapter.revisionId);
      expect(
        await repo.listRevisions(
          branchId: chapter.branchId,
          chapterId: chapter.id,
        ),
        hasLength(revisions.length),
      );
    });
  }

  test('batch refuses to insert into edited prose', () async {
    final id = await image('红伞过桥。');
    final edited = await repo.saveChapter(
      branchId: chapter.branchId,
      chapterId: chapter.id,
      expectedRevisionId: chapter.revisionId,
      content: ManuscriptContent.plainText('红伞过桥。\n船已离岸。'),
    );
    await expectLater(
      repo.insertAgentIllustrations(
        branchId: chapter.branchId,
        assetIds: [id],
        source: source,
      ),
      throwsA(isA<RevisionConflict>()),
    );
    expect((await current()).revisionId, edited.revisionId);
  });
}
