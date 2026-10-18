import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

void main() {
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
