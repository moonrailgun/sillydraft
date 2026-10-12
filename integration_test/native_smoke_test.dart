import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/resources/resource_library_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native secure storage, SQLite, editor, reader and reopen', (
    tester,
  ) async {
    Future<void> waitFor(Finder finder) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsWidgets);
      await tester.pumpAndSettle();
    }

    final directory = await Directory.systemTemp.createTemp(
      'sillydraft-native-',
    );
    final secrets = PlatformSecrets();
    final key = 'native-verification/${DateTime.now().microsecondsSinceEpoch}';
    await secrets.write(key, 'local-fixture-no-credentials');
    expect(await PlatformSecrets().read(key), 'local-fixture-no-credentials');
    await secrets.delete(key);
    expect(await secrets.read(key), isNull);

    final repository = StoryRepository.open('${directory.path}/library.sqlite');
    final services = AppServices(
      repository: repository,
      secrets: secrets,
      dataDirectory: directory,
    );
    final novel = await repository.createNovel(title: '跨端验证 · 雾港来信');
    final chapter = await repository.createChapter(
      branchId: novel.activeBranchId,
      title: '第一章 · 旧码头',
    );
    final scene = await repository.createScene(
      branchId: novel.activeBranchId,
      chapterId: chapter.id,
      title: '海风里的信',
      content: ManuscriptContent.plainText('傍晚，雾气越过码头。\n她打开了那封没有署名的信。'),
    );
    final captureKey = GlobalKey();
    final captures = <String, String>{};
    Future<void> capture(String name) async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      captures[name] = base64Encode(bytes!.buffer.asUint8List());
      image.dispose();
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: SillyDraftApp(services: services),
      ),
    );
    await tester.pumpAndSettle();
    await waitFor(find.text(novel.title));
    await tester.tap(find.text(novel.title));
    await tester.pumpAndSettle();
    await waitFor(find.byTooltip('编辑正文'));
    if ((tester.view.physicalSize / tester.view.devicePixelRatio).width >=
        900) {
      expect(find.byKey(const Key('workspace-divider')), findsOneWidget);
    }
    await capture('workspace');
    await tester.tap(find.byTooltip('编辑正文'));
    await tester.pumpAndSettle();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '雨落在雾港。\n她读到最后一行，忽然认出了自己的笔迹。\n',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('保存并返回'));
    await waitFor(find.byKey(const Key('open-reader')));
    expect(
      (await repository.getScene(
        branchId: scene.branchId,
        sceneId: scene.id,
      )).content.text,
      contains('自己的笔迹'),
    );
    await tester.tap(find.byKey(const Key('open-reader')));
    await tester.pumpAndSettle();
    expect(find.textContaining('自己的笔迹', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture('reader');
    final preset = await repository.storeResource(
      id: 'native-verification-preset',
      kind: ResourceKind.preset,
      name: '小说预设 · 本地验证',
      filename: 'native-preset.json',
      sourceHash: 'native-fixture-hash',
      encryptedSource: [],
      data: {
        'name': '小说预设 · 本地验证',
        'prompts': [
          {
            'identifier': 'main',
            'name': '正文写作',
            'role': 'system',
            'content': '保持人物动机一致，只输出小说正文。',
          },
          {
            'identifier': 'style',
            'name': '雾港的叙事风格',
            'role': 'system',
            'content': '节制、细腻，保留悬念。',
            'injection_position': 1,
            'injection_depth': 2,
            'injection_order': 100,
          },
        ],
        'prompt_order': [
          {
            'character_id': 100001,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'style', 'enabled': true},
            ],
          },
        ],
      },
    );
    unawaited(
      Navigator.of(tester.element(find.byType(Scaffold).last)).push(
        MaterialPageRoute<void>(
          builder: (_) => ResourceEditScreen(resource: preset),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await waitFor(find.byKey(const Key('prompt-edit-main')));
    await capture('preset');
    expect(tester.takeException(), isNull);
    binding.reportData = {
      'platform': Platform.operatingSystem,
      'captures': captures,
    };
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await services.close();
    final reopened = StoryRepository.open('${directory.path}/library.sqlite');
    expect(
      (await reopened.getStory(novel.activeBranchId)).text,
      contains('自己的笔迹'),
    );
    await reopened.close();
    await directory.delete(recursive: true);
  });
}
