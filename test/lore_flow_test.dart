import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide ImageProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/theme.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/lore/lore_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'package:sillydraft/features/lore/lore_edit_screen.dart';

import 'support/finders.dart';
import 'support/host.dart';

/// The app's forui theme and toaster around a test page, as `SillyDraftApp`
/// provides them.
Widget _app(Widget home) => MaterialApp(
  builder: (context, child) => FTheme(
    data: appTheme(Brightness.light),
    child: FToaster(child: child!),
  ),
  home: home,
);

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 16, height: 16)));

class _Reply implements ModelProvider {
  _Reply(this.config, this.text);
  @override
  final ModelConnection config;
  final String text;
  @override
  Stream<ProviderEvent> generate(
    ProviderRequest request, {
    GenerationCancellation? cancellation,
  }) async* {
    if (request.executionId?.startsWith('image-prompt-') == true) {
      yield TextDelta(
        '${request.messages.first['content']}'.contains('内容分类器')
            ? 'false'
            : '${request.messages.last['content']}',
      );
      yield const GenerationFinished('stop');
      return;
    }
    yield TextDelta(text);
    yield const GenerationFinished('stop');
  }

  @override
  Future<List<String>> listModels() async => [config.model];
  @override
  List<CompatibilityDiagnostic> validateParameters(ProviderRequest request) =>
      [];
  @override
  void close() {}
}

class _Painter implements ImageProvider {
  _Painter(this.config);
  @override
  final ModelConnection config;
  @override
  Future<GeneratedImage> generate(
    ImageRequest request, {
    List<ImageReference> references = const [],
    GenerationCancellation? cancellation,
  }) async => GeneratedImage(bytes: _png());
  @override
  void close() {}
}

/// Lets real I/O (isolates, files) and frames progress together.
Future<void> _settle(WidgetTester tester, [int rounds = 30]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _openEditor(
  WidgetTester tester,
  AppServices services,
  String branchId,
  LoreEntry entry,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(services)],
      child: testHost(
        Builder(
          builder: (context) => FButton(
            onPress: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    LoreEditScreen(branchId: branchId, entry: entry),
              ),
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

Finder get _portraitThumbs => find.byWidgetPredicate(
  (w) =>
      w is Padding &&
      w.key is ValueKey &&
      '${(w.key! as ValueKey).value}'.startsWith('character-image-'),
);

void main() {
  testWidgets('a location requires and saves its reference description', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final repo = services.repository;
    final branch = (await repo.createNovel(title: '雨夜')).activeBranchId;
    final asset = await repo.storeAsset(
      branchId: branch,
      name: '木屋',
      prepared: PreparedAsset(
        hash: 'a' * 64,
        thumbnailHash: 'b' * 64,
        width: 1,
        height: 1,
        byteLength: 1,
      ),
    );
    final entry = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.location,
      name: '木屋',
      content: '林中的木屋',
      data: {
        'images': [asset.id],
      },
    );
    await _openEditor(tester, services, branch, entry);
    expect(find.text('场景参考图 · 1/8'), findsOneWidget);
    final prompt = find.byKey(const Key('lore-reference-prompt'));
    await tester.ensureVisible(prompt);
    await tester.enterText(prompt, '');
    await tester.ensureVisible(find.text('保存资料'));
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    expect(find.textContaining('请填写与参考图对应的固定外观描述'), findsOneWidget);
    await tester.ensureVisible(prompt);
    await tester.enterText(
      prompt,
      'wooden cabin, window on the left, table with an oil lamp',
    );
    await tester.ensureVisible(find.text('保存资料'));
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    final saved = await repo.getLoreEntry(branchId: branch, id: entry.id);
    expect(saved.data['images'], [asset.id]);
    expect(
      saved.data['referencePrompt'],
      'wooden cabin, window on the left, table with an oil lamp',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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
  testWidgets('a character keeps its outfit, state and chosen portraits', (
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
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    PreparedAsset prepared(String digit) => PreparedAsset(
      hash: digit * 64,
      thumbnailHash: 'f' * 64,
      width: 1,
      height: 1,
      byteLength: 1,
    );
    final first = await repo.storeAsset(
      branchId: novel.activeBranchId,
      name: '林岚一',
      prepared: prepared('a'),
    );
    final second = await repo.storeAsset(
      branchId: novel.activeBranchId,
      name: '林岚二',
      prepared: prepared('b'),
    );
    final lin = await repo.saveLoreEntry(
      branchId: novel.activeBranchId,
      kind: LoreKind.character,
      name: '林岚',
      content: '摆渡人',
      data: {
        'outfit': '蓑衣',
        'images': [first.id, second.id],
      },
    );
    // Saving pops the page, so it is pushed over a host page.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(
          Builder(
            builder: (context) => FButton(
              onPress: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => LoreEditScreen(
                    branchId: novel.activeBranchId,
                    entry: lin,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('蓑衣'), findsNWidgets(2));
    expect(find.byKey(Key('character-image-${first.id}')), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('移除形象图').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('character-state')), '右手擦伤');
    await tester.ensureVisible(find.text('保存资料'));
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    final saved = await repo.getLoreEntry(
      branchId: novel.activeBranchId,
      id: lin.id,
    );
    expect(saved.data['images'], [second.id]);
    expect(saved.data['outfit'], '蓑衣');
    expect(saved.data['state'], '右手擦伤');
  });

  testWidgets('the author\'s edit makes a sidecar note theirs', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    final branch = novel.activeBranchId;
    final chapter = await repo.createChapter(
      branchId: branch,
      name: '渡口',
      content: ManuscriptContent.plainText('雨夜。'),
    );
    final lin = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: '林岚',
      content: '摆渡人',
      atChapterId: chapter.id,
      provenance: {
        'type': 'sidecar',
        'taskId': 't',
        'chapterId': chapter.id,
        'revisionId': chapter.revisionId,
      },
    );
    await _openEditor(tester, services, branch, lin);
    await tester.enterText(find.byKey(const Key('lore-content')), '摆渡人，左撇子');
    await tester.ensureVisible(find.text('保存资料'));
    await tester.tap(find.text('保存资料'));
    await tester.pumpAndSettle();
    final saved = await repo.getLoreEntry(branchId: branch, id: lin.id);
    expect(saved.content, '摆渡人，左撇子');
    expect(saved.provenance, {'type': 'manual'});
  });

  testWidgets('importing the persona portraits twice adds them once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sillydraft-lore-persona-'),
    ))!;
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
    );
    addTearDown(() async {
      await services.close();
      await dir.delete(recursive: true);
    });
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    final branch = novel.activeBranchId;
    final prepared = (await tester.runAsync(
      () => services.assets!.prepare(_png()),
    ))!;
    await repo.savePersona(
      Persona(id: 'linzhou', name: '林舟', images: [PersonaImage.of(prepared)]),
    );
    await repo.setSetting('writing/$branch', {'personaId': 'linzhou'});
    final user = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: '林舟',
      content: '主角',
      data: {'user': true},
    );
    await _openEditor(tester, services, branch, user);
    await tester.ensureVisible(find.text('从人设导入'));
    await tester.tap(find.text('从人设导入'));
    await _settle(tester);
    expect(_portraitThumbs, findsOneWidget);
    await tester.tap(find.text('从人设导入'));
    await _settle(tester);
    expect(_portraitThumbs, findsOneWidget);
    final assets = await repo.listAssets(novel.id, includeArchived: true);
    expect(assets.where((a) => a.hash == prepared.hash), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a character portrait is drafted, confirmed and generated', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('sillydraft-lore-image-'),
    ))!;
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
      modelProviderFactory: (c) async => _Reply(c, '{"prompt":"短发少女，蓑衣"}'),
      imageProviderFactory: (c) async => _Painter(c),
    );
    addTearDown(() async {
      await services.close();
      await dir.delete(recursive: true);
    });
    await services.saveConnection(
      ModelConnection(
        id: 'text',
        name: '文本',
        baseUrl: 'http://localhost:1/v1',
        model: 'fixture-text',
        kind: ModelKind.text,
      ),
    );
    await services.saveConnection(
      ModelConnection(
        id: 'image',
        name: '生图',
        baseUrl: 'http://localhost:1/v1',
        model: 'fixture-image',
        kind: ModelKind.image,
      ),
    );
    final repo = services.repository;
    final novel = await repo.createNovel(title: '雾港');
    final branch = novel.activeBranchId;
    final lin = await repo.saveLoreEntry(
      branchId: branch,
      kind: LoreKind.character,
      name: '林岚',
      content: '摆渡人',
      data: {'appearance': '短发少女', 'outfit': '蓑衣'},
    );
    await _openEditor(tester, services, branch, lin);
    await tester.ensureVisible(find.text('生成形象图'));
    await tester.tap(find.text('生成形象图'));
    await _settle(tester, 10);
    expect(find.text('参考图外观描述'), findsOneWidget);
    expect(find.text('短发少女, 蓑衣'), findsNWidgets(2));
    await tester.tap(find.text('保存').last);
    await _settle(tester);
    expect(_portraitThumbs, findsOneWidget);
    final made = (await repo.listAssets(novel.id)).single;
    expect(made.purpose, AssetPurpose.reference);
    await tester.pumpWidget(const SizedBox());
  });
}
