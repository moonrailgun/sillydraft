import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
  test('books group by identity and keep costs after deletion', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final first = await repo.createNovel(title: '同名书');
    final second = await repo.createNovel(title: '同名书');
    final fork = await repo.forkBranch(
      branchId: first.activeBranchId,
      name: '另一条路线',
    );
    final connection = ModelConnection(
      id: 'c',
      name: '网关',
      baseUrl: 'https://gateway.example/v1',
      model: 'm',
    );
    for (final (branch, purpose, cost) in [
      (first.activeBranchId, 'writing', 1.0),
      (fork.id, 'illustration', 2.0),
      (second.activeBranchId, 'writing', 4.0),
      (null, null, null),
    ]) {
      await repo.recordUsage(
        connection: connection,
        kind: purpose == 'illustration' ? 'image' : 'text',
        branchId: branch,
        purpose: purpose,
        costUsd: cost,
        inputTokens: 100,
        outputTokens: 20,
        source: cost == null ? CostSource.unknown : CostSource.upstream,
      );
    }
    final books = await repo.usageByBook();
    expect(books.map((t) => t.label), ['同名书', '同名书', '未归属书籍']);
    expect(books.map((t) => t.requests), [1, 2, 1]);
    expect(books.map((t) => t.cost), [4.0, 3.0, 0.0]);
    expect(books[1].inputTokens, 200);
    expect(books[1].outputTokens, 40);
    expect(books.last.unpriced, 1);
    final tools = await repo.usageByTool();
    expect(tools.map((t) => t.label), ['正文生成', '生图', '未分类工具']);
    expect(tools.map((t) => t.cost), [5.0, 2.0, 0.0]);
    await repo.updateNovel(first.copyWith(title: '新书名'));
    expect((await repo.usageByBook())[1].label, '新书名');
    await repo.deleteNovel(first.id);
    expect((await repo.usageByBook()).map((t) => t.cost), [4.0, 3.0, 0.0]);
    expect((await repo.usageByBook())[1].label, '同名书（已删除）');
  });

  test(
    'daily totals use local dates and retain pricing and estimate flags',
    () async {
      final dir = await Directory.systemTemp.createTemp('daily-usage-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/library.sqlite';
      final writer = StoryRepository.open(path);
      final connection = ModelConnection(
        id: 'c',
        name: '网关',
        baseUrl: 'https://gateway.example/v1',
        model: 'm',
      );
      for (final (id, cost, source) in [
        ('a', 0.5, CostSource.stPricing),
        ('b', null, CostSource.unknown),
        ('c', 0.0, CostSource.upstream),
      ]) {
        await writer.recordUsage(
          connection: connection,
          kind: 'text',
          executionId: id,
          inputTokens: 100,
          outputTokens: 20,
          estimated: id == 'a',
          costUsd: cost,
          source: source,
        );
      }
      await writer.close();
      final db = sqlite.sqlite3.open(path);
      for (final (id, date) in [
        ('a', DateTime(2026, 10, 17, 0, 1)),
        ('b', DateTime(2026, 10, 17, 23, 59)),
        ('c', DateTime(2026, 10, 19)),
      ]) {
        db.execute(
          'UPDATE usage_records SET created_at = ? WHERE execution_id = ?',
          [date.millisecondsSinceEpoch, id],
        );
      }
      db.close();
      final reader = StoryRepository.open(path);
      addTearDown(reader.close);
      final days = await reader.usageByDay();
      expect(days.map((d) => d.label), ['2026-10-17', '2026-10-19']);
      expect(days.first.requests, 2);
      expect(days.first.inputTokens, 200);
      expect(days.first.outputTokens, 40);
      expect(days.first.cost, 0.5);
      expect(days.first.unpriced, 1);
      expect(days.first.estimated, isTrue);
      expect(days.first.costEstimated, isTrue);
      expect(days.last.cost, 0);
      expect(days.last.unpriced, 0);
      expect(days.last.estimated, isFalse);
      expect(days.last.costEstimated, isFalse);
    },
  );
}
