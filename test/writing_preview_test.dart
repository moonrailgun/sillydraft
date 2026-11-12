import 'package:drift/drift.dart' hide Column, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/writing_request_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';
import 'support/query_gate.dart';

void main() {
  for (final overflow in [false, true]) {
    testWidgets('preview explains selection and blocks overflow: $overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      await services.saveConnection(
        ModelConnection(
          id: 'test',
          name: '测试模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'test',
          contextWindow: 2000,
          maxOutputTokens: 200,
        ),
      );
      if (!overflow) {
        await services.saveConnection(
          ModelConnection(
            id: 'reviewer',
            name: '审读',
            baseUrl: 'http://localhost:1/v1',
            model: 'audit',
          ),
        );
        await repo.setSetting('modelRoles', {'review': 'reviewer'});
      }
      final branch = (await repo.createNovel(title: '预览')).activeBranchId;
      await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.world,
        name: '禁忌',
        content: overflow ? '规则' * 3000 : '亡者不能复生',
        data: {'contextRequired': true},
      );
      final person = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '林岚',
        content: '摆渡人',
      );
      final other = await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.character,
        name: '陈舟',
        content: '已失明',
      );
      await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.relationship,
        name: '旧盟约',
        content: '彼此隐瞒真实身份',
        data: {'fromId': person.id, 'toId': other.id, 'contextRequired': true},
      );
      await repo.saveLoreEntry(
        branchId: branch,
        kind: LoreKind.world,
        name: '珊瑚',
        content: '海底呈紫色',
      );
      final chapter = await repo.createChapter(branchId: branch);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            WritingRequestScreen(chapter: chapter, initialBrief: '林岚回家'),
            brightness: overflow ? Brightness.dark : Brightness.light,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('预览提示词'));
      await tester.tap(find.text('预览提示词'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('连续性审读模型：${overflow ? 'test' : 'audit'}'),
        findsOneWidget,
      );
      expect(find.textContaining('生成时会额外请求一次章前计划'), findsOneWidget);
      expect(find.textContaining('新书首章还会请求一次全书布局'), findsOneWidget);
      expect(find.textContaining('上述估算不含这些辅助请求'), findsOneWidget);
      final selection = find.text('资料选择 · 已带 4 · 未带 1');
      final pageScroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(selection, 180, scrollable: pageScroll);
      await tester.tap(selection);
      await tester.pumpAndSettle();
      expect(find.text('禁忌 · 必带 · 作者指定'), findsOneWidget);
      expect(find.text('林岚 · 必带 · 本次要求点名'), findsOneWidget);
      expect(find.text('陈舟 · 必带 · 关联资料引用'), findsOneWidget);
      expect(find.text('珊瑚 · 未带 · 本次未匹配'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('开始生成'),
        180,
        scrollable: pageScroll,
      );
      final start = find.widgetWithText(FButton, '开始生成');
      expect(tester.widget<FButton>(start).onPress == null, overflow);
      expect(await repo.listTasks(branchId: branch), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
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
