import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart' hide ImageProvider;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/features/illustrations/asset_image.dart';
import 'package:sillydraft/features/illustrations/illustration_detail.dart';
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
  testWidgets('image download saves the original PNG to the selected path', (
    tester,
  ) async {
    late Directory dir;
    late AppServices services;
    late StoryAsset asset;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('sillydraft-image-export-');
      services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
        dataDirectory: dir,
      );
      final novel = await services.repository.createNovel(title: '下载图片');
      asset = await services.assets!.importImage(
        branchId: novel.activeBranchId,
        name: '插画',
        bytes: await File('test/fixtures/tiny-illustration.png').readAsBytes(),
      );
    });
    addTearDown(() async {
      await services.close();
      await dir.delete(recursive: true);
    });
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    final output = File('${dir.path}/download.png');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'getSavePath');
      expect(call.arguments['suggestedName'], 'illustration.png');
      return output.path;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    late Future<void> Function() download;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          Consumer(
            builder: (context, ref, _) {
              download = () => exportIllustration(context, ref, asset.id);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await download();
      expect(await output.readAsBytes(), await services.assets!.read(asset.id));
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final protocol in [
    ModelProtocol.openAICompatible,
    ModelProtocol.novelAI,
  ]) {
    testWidgets(
      'phone $protocol image form starts a durable job and cancellation preserves prose',
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
            protocol: protocol,
          ),
        );
        await services.repository.setSetting(
          'imageDefaults/image/fixture-image',
          {'quality': 'high', 'size': '832x1216'},
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
        await tester.enterText(
          find.byKey(const Key('illustration-name')),
          '港口',
        );
        await tester.enterText(
          find.byKey(const Key('illustration-prompt')),
          '雾中的港口，水彩',
        );
        if (protocol == ModelProtocol.novelAI) {
          await tester.scrollUntilVisible(
            find.text('选择或导入参考图'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('质量'), findsNothing);
          final referenceButton = tester.widget<FButton>(
            find.widgetWithText(FButton, '选择或导入参考图'),
          );
          expect(referenceButton.onPress, isNull);
        }
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
        expect((await started.future).parameters['size'], '832x1216');
        expect(
          (await started.future).parameters['quality'],
          protocol == ModelProtocol.novelAI ? isNull : 'high',
        );
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
  }
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
      final reader = find.byKey(const Key('reader-page'));
      await tester.tapAt(tester.getTopLeft(reader) + const Offset(5, 350));
      await tester.pumpAndSettle();
      expect(findAction('阅读设置').hitTestable(), findsNothing);
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byType(SingleChildScrollView).first,
          )
          .controller!;
      final offset = scroll.offset;
      await tester.tap(find.byType(AssetImageView));
      await settleImages();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byType(IllustrationDetail), findsOneWidget);
      await tester.tap(findAction('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(IllustrationDetail), findsNothing);
      expect(findAction('阅读设置').hitTestable(), findsNothing);
      expect(scroll.offset, offset);
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
  testWidgets('the detail modal shows generation info beside the image on '
      'wide screens and behind 图片详情 on phones', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final novel = await services.repository.createNovel(title: '插图详情');
    final asset = await services.repository.storeAsset(
      branchId: novel.activeBranchId,
      name: '天台',
      prepared: PreparedAsset(
        hash: 'a' * 64,
        thumbnailHash: 'b' * 64,
        width: 100,
        height: 100,
        byteLength: 200,
      ),
      metadata: {'prompt': '风中交叠的手'},
    );
    Future<void> show(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: testHost(
            Builder(
              builder: (context) => FButton(
                onPress: () => showIllustrationDetail(
                  context,
                  assetId: asset.id,
                  branchId: novel.activeBranchId,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
    }

    await show(const Size(1200, 800));
    expect(find.text('风中交叠的手'), findsOneWidget);
    expect(findAction('图片详情'), findsNothing);
    await tester.tap(findAction('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('风中交叠的手'), findsNothing);
    expect(find.text('打开'), findsOneWidget);

    await show(const Size(390, 844));
    expect(find.text('风中交叠的手'), findsNothing);
    await tester.tap(findAction('图片详情'));
    await tester.pumpAndSettle();
    expect(find.text('风中交叠的手'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a character\'s portrait can be picked as a reference', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    await services.saveConnection(
      ModelConnection(
        id: 'img',
        name: '生图',
        baseUrl: 'http://localhost:1/v1',
        model: 'painter',
        kind: ModelKind.image,
      ),
    );
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    final portrait = await repo.storeAsset(
      branchId: novel.activeBranchId,
      name: '林岚',
      prepared: PreparedAsset(
        hash: 'a' * 64,
        thumbnailHash: 'b' * 64,
        width: 1,
        height: 1,
        byteLength: 1,
      ),
      purpose: AssetPurpose.reference,
    );
    final lin = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林岚',
      content: '摆渡人',
      data: {
        'images': [portrait.id],
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          IllustrationRequestScreen(branchId: novel.activeBranchId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('pick-character-reference')),
    );
    await tester.tap(find.byKey(const Key('pick-character-reference')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('character-reference-${lin.id}')));
    await tester.pumpAndSettle();
    expect(find.text('参考图片 · 1/16'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key('pick-character-reference')),
    );
    await tester.tap(find.byKey(const Key('pick-character-reference')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('character-reference-${lin.id}')));
    await tester.pumpAndSettle();
    expect(find.text('参考图片 · 1/16'), findsOneWidget);
    expect(find.text('这个人物的形象图都已添加'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
