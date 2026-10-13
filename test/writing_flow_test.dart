import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

class _Writer implements ModelProvider {
  _Writer(this.config);
  @override
  final ModelConnection config;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    yield const TextDelta('新句');
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => ['test'];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

void main() {
  testWidgets(
    'selected prose is previewed, generated separately, compared, and accepted',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory();
      final services = AppServices(
        repository: repo,
        secrets: MemorySecrets(),
        modelProviderFactory: (c) async => _Writer(c),
      );
      addTearDown(services.close);
      await services.saveConnection(
        ModelConnection(
          id: 'test',
          name: '测试模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'test',
        ),
      );
      final novel = await repo.createNovel(title: '选区写作');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('甲原文乙'),
      );
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选区写作'));
      await tester.pumpAndSettle();
      await editChapter(tester, chapter.title);
      tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller
          .updateSelection(
            const TextSelection(baseOffset: 1, extentOffset: 3),
            ChangeSource.local,
          );
      await tester.pump();
      await tester.tap(findAction('生成或改写选区'));
      await tester.pumpAndSettle();
      expect(find.text('原文'), findsWidgets);
      await tester.enterText(find.byKey(const Key('writing-brief')), '更简洁');
      await tester.tap(find.text('预览提示词'));
      await tester.pumpAndSettle();
      expect(await repo.listTasks(branchId: novel.activeBranchId), isEmpty);
      await tester.ensureVisible(find.text('开始生成候选'));
      await tester.tap(find.text('开始生成候选'));
      await tester.pumpAndSettle();
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text.trim(),
        '甲原文乙',
      );
      await tester.tap(find.text('审阅正文候选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采纳到正文'));
      await tester.pumpAndSettle();
      expect(
        (await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        )).content.text.trim(),
        '甲新句乙',
      );
      await tester.tap(findAction('返回'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<QuillEditor>(find.byType(QuillEditor))
            .controller
            .document
            .toPlainText()
            .trim(),
        '甲新句乙',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
