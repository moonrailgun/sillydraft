import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  testWidgets(
    'Chinese composition commits to the manuscript and survives leaving editor',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '中文输入测试');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        title: '第一章',
      );
      final scene = await repo.createScene(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        title: '第一幕',
      );
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(services.close);
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中文输入测试'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑正文'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      // An IME inserts at the current cursor; it does not remove Quill's existing
      // final paragraph separator when composing in an empty document.
      final suffix = tester.testTextInput.editingState!['text'] as String;
      expect(suffix, '\n');
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: 'yu$suffix',
          selection: const TextSelection.collapsed(offset: 2),
          composing: const TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '雨落在渡口。$suffix',
          selection: const TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存并返回'));
      await tester.pumpAndSettle();
      final saved = await repo.getScene(
        branchId: novel.activeBranchId,
        sceneId: scene.id,
      );
      expect(saved.content.text.trim(), '雨落在渡口。');
      expect(find.text('6 字'), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-reader')));
      await tester.pumpAndSettle();
      expect(find.textContaining('雨落在渡口。', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
