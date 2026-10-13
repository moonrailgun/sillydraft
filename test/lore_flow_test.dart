import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/theme.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/lore/lore_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';

/// The app's forui theme and toaster around a test page, as `SillyDraftApp`
/// provides them.
Widget _app(Widget home) => MaterialApp(
  builder: (context, child) => FTheme(
    data: appTheme(Brightness.light),
    child: FToaster(child: child!),
  ),
  home: home,
);

void main() {
  testWidgets(
    'phone dossiers save a plan separately from prose and archive it',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = StoryRepository.memory(), secrets = MemorySecrets();
      final services = AppServices(repository: repo, secrets: secrets);
      addTearDown(services.close);
      final novel = await repo.createNovel(title: '旁路创作');
      await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('不可混入资料的正文'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: _app(LoreScreen(branchId: novel.activeBranchId)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FloatingAction, '添加资料'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('lore-name')), '尚未抵达的灯塔');
      await tester.enterText(
        find.byKey(const Key('lore-content')),
        '未来想让角色在这里重逢',
      );
      await tester.tap(
        find.descendant(
          of: find.byWidgetPredicate((w) => w is FSelect<LoreCertainty>),
          matching: find.byType(EditableText),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('创作计划').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存资料'));
      await tester.tap(find.text('保存资料'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listLore(novel.activeBranchId)).single.certainty,
        LoreCertainty.plan,
      );
      expect(
        (await repo.getStory(novel.activeBranchId)).text.trim(),
        '不可混入资料的正文',
      );
      await tester.tap(find.text('尚未抵达的灯塔'));
      await tester.pumpAndSettle();
      await tester.tap(findAction('移入资料归档'));
      await tester.pumpAndSettle();
      expect(await repo.listLore(novel.activeBranchId), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
