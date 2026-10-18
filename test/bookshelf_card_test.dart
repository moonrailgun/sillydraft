import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/illustrations/asset_image.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  for (final hasCover in [false, true]) {
    testWidgets('shelf identifies a work with cover=$hasCover', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final repo = StoryRepository.memory();
      final services = AppServices(repository: repo, secrets: MemorySecrets());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await services.close();
      });
      var novel = await repo.createNovel(
        title: '一封迟到十三年的信与地图上不存在的灯塔',
        synopsis: '年轻信使在雾港寻找失踪的守塔人。',
        genre: '奇幻',
      );
      if (hasCover) {
        // The title must also survive a cover that is unavailable locally.
        novel = await repo.updateNovel(
          novel.copyWith(coverAssetId: 'unavailable-cover'),
        );
      }
      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();

      expect(find.text(novel.title), findsOneWidget);
      expect(find.text(novel.synopsis), findsOneWidget);
      expect(find.textContaining('奇幻 · '), findsOneWidget);
      if (hasCover) {
        expect(
          tester.getTopLeft(find.text(novel.title)).dy,
          greaterThan(tester.getBottomLeft(find.byType(AssetImageView)).dy),
        );
      }
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(390, 844);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpAndSettle();
      expect(find.text(novel.title), findsOneWidget);
      expect(tester.takeException(), isNull);

      await repo.updateNovel(novel.copyWith(synopsis: '  ', genre: ''));
      await tester.pumpAndSettle();
      expect(find.text(novel.title), findsOneWidget);
      expect(find.text(novel.synopsis), findsNothing);
      expect(find.text('一个正在生长的故事'), findsNothing);
      expect(find.textContaining(' · '), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
