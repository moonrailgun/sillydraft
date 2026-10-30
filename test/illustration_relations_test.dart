import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide ImageProvider;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/illustrations/illustration_relations.dart';
import 'package:sillydraft/features/illustrations/illustration_detail.dart';
import 'package:sillydraft/features/illustrations/asset_image.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

class _Images implements ImageProvider {
  _Images(this.config, this.bytes, this.onGenerate);
  @override
  final ModelConnection config;
  final Uint8List bytes;
  final Future<void> Function(ImageRequest) onGenerate;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async {
    await onGenerate(request);
    return GeneratedImage(bytes: bytes);
  }

  @override
  void close() {}
}

Future<void> settle(WidgetTester tester, {String? until}) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if ((until == null || find.textContaining(until).evaluate().isNotEmpty) &&
        find.byType(FCircularProgress).evaluate().isEmpty &&
        !tester.binding.hasScheduledFrame) {
      return;
    }
  }
  if (until != null) expect(find.textContaining(until), findsWidgets);
  expect(find.byType(FCircularProgress), findsNothing);
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'relations and regeneration work at width $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late AppServices services;
        late Directory dir;
        late String branch;
        late StoryAsset reference, child;
        late Chapter chapter;
        var calls = 0;
        int? failAt;
        Completer<void>? gate;
        final prompts = <String>[];
        final wide = width > 900;
        final count = wide ? 2 : 1;
        await tester.runAsync(() async {
          dir = await Directory.systemTemp.createTemp('relations-ui-');
          final bytes = await File('test/fixtures/tiny-illustration.png')
              .readAsBytes();
          services = AppServices(
            repository: StoryRepository.memory(),
            secrets: MemorySecrets(),
            dataDirectory: dir,
            imageProviderFactory: (c) async =>
                _Images(c, bytes, (request) async {
                  calls++;
                  prompts.add(request.prompt);
                  if (calls == failAt) {
                    throw const ProviderException('test', '本地失败');
                  }
                  await gate?.future;
                }),
          );
          final connection = ModelConnection(
            id: 'image',
            name: '本地测试引擎',
            baseUrl: 'http://localhost:1',
            model: 'image',
            kind: ModelKind.image,
          );
          await services.saveConnection(connection);
          branch = (await services.repository.createNovel(title: '关系测试'))
              .activeBranchId;
          final task = await services.illustrations.generate(
            branchId: branch,
            connection: connection,
            name: '人物参考图',
            request: ImageRequest(prompt: '红衣人物'),
            purpose: AssetPurpose.reference,
          );
          reference = await services.repository.getAsset(
            (await services.runner.wait(task.id)).result['assetId'] as String,
          );
          final lore = await services.repository.saveLoreEntry(
            branchId: branch,
            kind: LoreKind.character,
            name: '人物',
            content: '人物',
            data: {
              'images': [reference.id],
              'referencePrompt': '红衣人物',
            },
          );
          final drawing = await services.illustrations.generate(
            branchId: branch,
            connection: connection,
            name: '桥上相遇',
            request: ImageRequest(prompt: '桥上相遇'),
            visualReferences: [
              VisualReference(
                kind: LoreKind.character,
                name: '人物',
                prompt: '红衣人物',
                entry: lore,
                assetId: reference.id,
              ),
            ],
          );
          child = await services.repository.getAsset(
            (await services.runner.wait(drawing.id)).result['assetId']
                as String,
          );
          chapter = await services.repository.createChapter(
            branchId: branch,
            title: '第一章',
            content: ManuscriptContent.plainText('正文').insertImage(0, child.id),
          );
          if (wide) {
            final next = await services.illustrations.generate(
              branchId: branch,
              connection: connection,
              name: '桥上交谈',
              request: ImageRequest(prompt: '桥上交谈'),
              previousSceneAssetId: child.id,
            );
            await services.runner.wait(next.id);
          }
          final replacement = await services.illustrations.regenerate(
            branchId: branch,
            assetId: reference.id,
            connection: connection,
          );
          await services.runner.wait(replacement.id);
        });
        addTearDown(() async {
          await tester.runAsync(() async {
            await services.close();
            await dir.delete(recursive: true);
          });
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(
              MediaQuery(
                data: MediaQueryData(
                  textScaler: TextScaler.linear(wide ? 1 : 1.5),
                ),
                child: Scaffold(
                  body: SingleChildScrollView(
                    child: IllustrationRelations(
                      branchId: branch,
                      assetId: reference.id,
                    ),
                  ),
                ),
              ),
              brightness: wide ? Brightness.light : Brightness.dark,
            ),
          ),
        );
        await settle(tester, until: '图片关联');
        expect(find.text('参考图不一致'), findsNWidgets(count));
        expect(find.text('第一章'), findsOneWidget);
        expect(find.text('全部重新生成（$count 张）'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('全部重新生成（$count 张）'));
        await settle(tester, until: '开始生成');
        expect(find.textContaining('本地测试引擎'), findsWidgets);
        expect(find.byType(AssetImageView), findsWidgets);
        if (wide) failAt = calls + 2;
        await tester.tap(find.text('开始生成'));
        if (wide) {
          await settle(tester, until: '本地失败');
          expect(find.text('参考图不一致'), findsOneWidget);
          expect(find.text('继续未完成（1 张）'), findsOneWidget);
          await tester.tap(find.text('继续未完成（1 张）'));
          await settle(tester, until: '开始生成');
          await tester.tap(find.text('开始生成'));
        }
        await settle(tester, until: '已完成 1 张');
        expect(calls, wide ? 7 : 4);
        expect(find.text('参考图不一致'), findsNothing);
        await tester.runAsync(() async {
          final current = await services.repository.getChapter(
            branchId: branch,
            chapterId: chapter.id,
          );
          expect(current.content.text, chapter.content.text);
          expect(
            current.content.delta.first['insert'],
            isNot({'image': 'asset:${child.id}'}),
          );
        });
        if (wide) {
          // Desktop actions appear on hover and keyboard focus.
          final action = find.byWidgetPredicate(
            (w) => w is IconAction && w.tooltip == '重新生成人物参考图',
          );
          bool actionsVisible() => tester
              .widget<Visibility>(
                find
                    .ancestor(of: action, matching: find.byType(Visibility))
                    .first,
              )
              .visible;
          expect(actionsVisible(), isFalse);
          final root = (await tester.runAsync(
            () => services.repository.illustrationGraph(branch),
          ))!.current(reference.id);
          final node = find.byKey(ValueKey('illustration-node-${root.id}'));
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(node));
          await tester.pumpAndSettle();
          expect(actionsVisible(), isTrue);
          await mouse.removePointer();
          await tester.pumpAndSettle();
          FocusManager.instance.primaryFocus?.unfocus();
          for (var i = 0; i < 5 && !actionsVisible(); i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
          }
          expect(actionsVisible(), isTrue);
        } else {
          // Single regeneration accepts an edited prompt; cancelling preserves it.
          await tester.tap(find.text('重新生成此图'));
          await settle(tester, until: '开始生成');
          await tester.enterText(find.byType(EditableText), '蓝衣人物');
          await tester.tap(find.text('开始生成'));
          await settle(tester, until: '已完成 1 张');
          expect(prompts.last, contains('蓝衣人物'));
          expect(find.text('参考图不一致'), findsOneWidget);
          for (final cancel in [false, true]) {
            final edited = cancel ? '紫衣人物' : '绿衣人物';
            gate = cancel ? Completer<void>() : null;
            failAt = cancel ? null : calls + 1;
            await tester.tap(find.text('重新生成此图'));
            await settle(tester, until: '开始生成');
            await tester.enterText(find.byType(EditableText), edited);
            final before = calls;
            await tester.tap(find.text('开始生成'));
            if (cancel) {
              await settle(tester, until: '正在生成');
              for (var i = 0; i < 100 && calls == before; i++) {
                await tester.runAsync(
                  () => Future<void>.delayed(const Duration(milliseconds: 20)),
                );
                await tester.pump();
              }
              expect(calls, before + 1);
              await tester.tap(find.text('停止生成'));
              gate!.complete();
            }
            await settle(tester, until: cancel ? '已取消' : '本地失败');
            expect(find.text('继续未完成（1 张）'), findsOneWidget);
            await tester.tap(find.text('继续未完成（1 张）'));
            await settle(tester, until: '开始生成');
            await tester.tap(find.text('开始生成'));
            await settle(tester, until: '已完成 1 张');
            expect(prompts.last, contains(edited));
          }
        }
        expect(tester.takeException(), isNull);
        // Opening an old asset continues to show that version, with a latest link.
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(services)],
            child: testHost(
              IllustrationDetail(branchId: branch, assetId: reference.id),
            ),
          ),
        );
        await settle(tester, until: '这是旧版本 · 查看最新图片');
        expect(
          tester
              .widget<AssetImageView>(find.byType(AssetImageView).first)
              .assetId,
          reference.id,
        );
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(
        width > 900 ? TargetPlatform.macOS : TargetPlatform.android,
      ),
    );
  }
}
