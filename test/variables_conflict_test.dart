import 'package:drift/drift.dart' show ApplyInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/lore/variables_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';
import 'support/query_gate.dart';

void main() {
  for (final scenario in ['loading', 'dirty chapter', 'new chapter editor']) {
    testWidgets('variable versions stay with their snapshot: $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gate = QueryGate();
      final repo = StoryRepository.connect(
        NativeDatabase.memory().interceptWith(gate),
      );
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(() async {
        gate.release();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await services.close();
      });
      final novel = await repo.createNovel(title: '变量冲突');
      final branch = novel.activeBranchId;
      final chapter = await repo.createChapter(
        branchId: branch,
        title: '第一章',
        content: ManuscriptContent.plainText('正文'),
      );
      await repo.setBranchVariables(
        branchId: branch,
        chapterId: chapter.id,
        expectedVersion: 0,
        local: {'state': 'old'},
        global: {'setting': 'old'},
      );
      if (scenario == 'new chapter editor') {
        await repo.createChapter(
          branchId: branch,
          title: '第二章',
          content: ManuscriptContent.plainText('后文'),
        );
      }
      if (scenario == 'loading') {
        gate.arm((sql) => sql.contains('FROM app_settings'));
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(VariablesScreen(branchId: branch)),
        ),
      );
      Future<void> save(String key) async {
        final button = find.byKey(Key('save-$key'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
      }

      if (scenario == 'loading') {
        await gate.waitUntilBlocked(tester);
        await repo.setBranchVariables(
          branchId: branch,
          chapterId: chapter.id,
          expectedVersion: 1,
          local: {'state': 'concurrent'},
          global: {'setting': 'old'},
        );
        gate.release();
        await tester.pumpAndSettle();
        await tester.tap(find.text('聊天'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('variables-chat')),
          '{"state":"draft"}',
        );
        await save('chat');
        final current = await repo.getBranchVariables(branch);
        expect(current.version, 2);
        expect(current.local['state'], 'concurrent');
      } else if (scenario == 'dirty chapter') {
        await tester.pumpAndSettle();
        await tester.tap(find.text('消息楼层'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(Key('variables-chapter:${chapter.id}')),
          '{"state":"draft"}',
        );
        await tester.tap(find.text('全局'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('variables-global')),
          '{"setting":"saved"}',
        );
        await save('global');
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.tap(find.text('消息楼层'));
        await tester.pumpAndSettle();
        await save('chapter:${chapter.id}');
        final current = await repo.getBranchVariables(branch);
        expect(current.version, 2);
        expect(current.local['state'], 'old');
        expect(current.global['setting'], 'saved');
      } else {
        await tester.pumpAndSettle();
        await repo.setBranchVariables(
          branchId: branch,
          chapterId: chapter.id,
          expectedVersion: 1,
          local: {'state': 'concurrent'},
        );
        await tester.tap(find.text('消息楼层'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('第 0 楼 · 第一章'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(Key('variables-chapter:${chapter.id}')),
          '{"state":"draft"}',
        );
        await save('chapter:${chapter.id}');
        final current = await repo.getBranchVariables(branch);
        expect(current.version, 3);
        expect(current.local['state'], 'draft');
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(Key('variables-chapter:${chapter.id}')),
          '{"state":"next draft"}',
        );
        await save('chapter:${chapter.id}');
        final next = await repo.getBranchVariables(branch);
        expect(next.version, 4);
        expect(next.local['state'], 'next draft');
      }
      expect(tester.takeException(), isNull);
    });
  }
}
