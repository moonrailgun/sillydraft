import 'package:drift/drift.dart' hide Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/agent/writing_request_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';
import 'support/query_gate.dart';

void main() {
  for (final change in ['brief', 'mode', 'preset']) {
    testWidgets('changing $change during preparation invalidates the preview', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
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
      await services.saveConnection(
        ModelConnection(
          id: 'test',
          name: '测试模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'test',
        ),
      );
      final novel = await repo.createNovel(title: '预览');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('原文'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(WritingRequestScreen(chapter: chapter)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('writing-brief')), '写一场下雨');
      gate.arm((sql) => sql.contains('SELECT c.*, r.content_json'));
      await tester.tap(find.text('预览提示词'));
      await gate.waitUntilBlocked(tester);
      switch (change) {
        case 'brief':
          await tester.enterText(
            find.byKey(const Key('writing-brief')),
            '写一场晴天',
          );
        case 'mode':
          await tester.tap(find.text('改写整章'));
        case 'preset':
          await tester.tap(find.text('预设'));
          await tester.pump();
          await tester.binding.handlePopRoute();
          await tester.pump();
      }
      gate.release();
      await tester.pumpAndSettle();
      expect(find.text('开始生成'), findsNothing);
      expect(await repo.listTasks(branchId: chapter.branchId), isEmpty);
      await tester.tap(find.text('预览提示词'));
      await tester.pumpAndSettle();
      expect(find.text('开始生成'), findsOneWidget);
      final preview = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((text) => text.data ?? '')
          .join('\n');
      if (change == 'brief') {
        expect(preview, contains('写一场晴天'));
        expect(preview, isNot(contains('写一场下雨')));
      }
    });
  }
}
