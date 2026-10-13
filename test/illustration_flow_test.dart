import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart' hide ImageProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/features/illustrations/asset_image.dart';
import 'package:sillydraft/features/illustrations/illustration_gallery.dart';
import 'package:sillydraft/features/illustrations/illustration_request.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

class _WaitingImageProvider implements ImageProvider {
  _WaitingImageProvider(this.config, this.started);
  @override
  final ModelConnection config;
  final Completer<ImageRequest> started;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    final done = Completer<void>();
    final remove = cancellation!.onCancel(() => done.complete());
    started.complete(request);
    try {
      await done.future;
      cancellation.check();
      throw StateError('cancel expected');
    } finally {
      remove();
    }
  }

  @override
  void close() {}
}

void main() {
  testWidgets(
    'phone image form starts a durable job and cancellation preserves prose',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sillydraft-image-task-ui-'),
      );
      final started = Completer<ImageRequest>();
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
        dataDirectory: dir,
        imageProviderFactory: (c) async => _WaitingImageProvider(c, started),
      );
      addTearDown(() async {
        await services.close();
        await dir!.delete(recursive: true);
      });
      await services.saveConnection(
        ModelConnection(
          id: 'image',
          name: '测试生图模型',
          baseUrl: 'http://localhost:1/v1',
          model: 'fixture-image',
        ),
      );
      final repo = services.repository,
          novel = await services.repository.createNovel(title: '取消生图');
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('不会被生图任务改动的正文'),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            IllustrationRequestScreen(
              branchId: chapter.branchId,
              chapterId: chapter.id,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('illustration-name')), '港口');
      await tester.enterText(
        find.byKey(const Key('illustration-prompt')),
        '雾中的港口，水彩',
      );
      await tester.scrollUntilVisible(
        find.text('开始生成'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('开始生成'));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect((await started.future).prompt, '雾中的港口，水彩');
      expect(
        (await repo.listTasks(branchId: chapter.branchId)).single.kind,
        TaskKind.illustration,
      );
      await tester.tap(find.text('取消生成'));
      await tester.pumpAndSettle();
      expect(
        (await repo.listTasks(branchId: chapter.branchId)).single.status,
        TaskStatus.cancelled,
      );
      expect(
        (await repo.getChapter(
          branchId: chapter.branchId,
          chapterId: chapter.id,
        )).revisionId,
        chapter.revisionId,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'local image can be selected at the cursor and read independently',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late AppServices services;
      late Novel novel;
      late Chapter chapter;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('sillydraft-image-ui-');
        services = AppServices(
          repository: StoryRepository.memory(),
          secrets: MemorySecrets(),
          dataDirectory: dir,
        );
        novel = await services.repository.createNovel(title: '带插画的小说');
        chapter = await services.repository.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('港口起雾了。'),
        );
        await services.assets!.importImage(
          branchId: novel.activeBranchId,
          name: '港口插画',
          bytes: await File('test/fixtures/tiny-illustration.png')
              .readAsBytes(),
        );
      });
      addTearDown(() async {
        await services.close();
        await dir.delete(recursive: true);
      });
      Future<void> settleImages() async {
        // Repository futures are advanced by pump; filesystem and codec work
        // need real async turns after their widgets have actually been built.
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          if (find.byType(FCircularProgress).evaluate().isEmpty &&
              find.byType(Image).evaluate().isNotEmpty) {
            break;
          }
        }
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(SillyDraftApp(services: services));
      await tester.pumpAndSettle();
      await tester.tap(find.text('带插画的小说'));
      await tester.pumpAndSettle();
      await editChapter(tester, chapter.title);
      await tester.tap(findAction('插入图片'));
      await tester.pump();
      await settleImages();
      await tester.tap(find.text('港口插画'));
      await tester.pump();
      await settleImages();
      expect(find.byType(AssetImageView), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(
        (await services.repository.getChapter(
          branchId: chapter.branchId,
          chapterId: chapter.id,
        )).content.delta.any((op) => op['insert'] is Map),
        true,
      );
      await tester.tap(findAction('保存并返回'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(findAction('阅读'));
      await tester.pump();
      await settleImages();
      expect(find.byType(AssetImageView), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'gallery archives illustrations while retaining manuscript references',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      final repo = services.repository,
          novel = await services.repository.createNovel(title: '插图库');
      final asset = await repo.storeAsset(
        branchId: novel.activeBranchId,
        name: '雨夜港口',
        prepared: PreparedAsset(
          hash: 'a' * 64,
          thumbnailHash: 'b' * 64,
          width: 100,
          height: 100,
          byteLength: 200,
        ),
      );
      final s = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('港口'),
      );
      final inserted = await repo.insertIllustration(
        branchId: s.branchId,
        chapterId: s.id,
        expectedRevisionId: s.revisionId,
        assetId: asset.id,
        offset: 2,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(IllustrationGallery(branchId: s.branchId)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('雨夜港口'));
      await tester.pumpAndSettle();
      await tester.tap(findAction('归档图片'));
      await tester.pumpAndSettle();
      expect((await repo.getAsset(asset.id)).archived, true);
      expect(
        (await repo.getChapter(
          branchId: s.branchId,
          chapterId: s.id,
        )).revisionId,
        inserted.revisionId,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
