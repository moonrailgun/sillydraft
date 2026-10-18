import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/editor/workspace_screen.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft/features/reader/reader_document.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft/features/resources/card_start_screen.dart';
import 'package:sillydraft/features/settings/settings_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/finders.dart';
import 'support/host.dart';

const _opening =
    '```html\n<html><body><button onclick="go()">开启仙途</button></body></html>\n```';
const _creationPage =
    '```html\n<html><body><form>重塑仙缘</form></body></html>\n```';

/// Stands in for the web view: shows the block kind and offers the calls a
/// real page would make through the bridge.
Widget fakeBlock(HtmlBlockRequest request) => Container(
  key: const Key('fake-html'),
  color: const Color(0x11000000),
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('FAKE:${request.block.kind.name}'),
      if (request.bridge case final bridge?) ...[
        FButton(
          key: const Key('fake-switch'),
          variant: FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => bridge.handle('setChatMessages', [
            [
              {'message_id': 0, 'swipe_id': 1},
            ],
            <String, dynamic>{'refresh': 'affected'},
          ]),
          child: const Text('switch'),
        ),
        FButton(
          key: const Key('fake-send'),
          variant: FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => bridge.runSlash('/send 开启仙途'),
          child: const Text('send'),
        ),
        FButton(
          key: const Key('fake-setvar'),
          variant: FButtonVariant.ghost,
          mainAxisSize: MainAxisSize.min,
          onPress: () => bridge.runSlash('/setvar key=境界 凡人'),
          child: const Text('setvar'),
        ),
      ],
    ],
  ),
);

Future<AppServices> _services() async {
  final services = AppServices(
    repository: StoryRepository.memory(),
    secrets: MemorySecrets(),
  );
  await services.repository.storeResource(
    id: 'card',
    kind: ResourceKind.character,
    name: '道渊',
    filename: 'card.json',
    sourceHash: 'fixture',
    encryptedSource: [],
    data: {
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': '道渊',
        'description': '修仙世界',
        'scenario': '玄天界',
        'first_mes': '$_opening\n开场后的旁白。',
        'alternate_greetings': ['[重塑仙缘]'],
        'extensions': {
          'regex_scripts': [
            {
              'id': 'r1',
              'scriptName': '开局创造人物',
              'findRegex': r'\[重塑仙缘\]',
              'replaceString': _creationPage,
              'placement': [2],
              'markdownOnly': true,
            },
          ],
          'tavern_helper': {
            'scripts': [
              {'name': 'MVU', 'enabled': true},
              {'name': '道渊工坊', 'enabled': true},
            ],
          },
        },
      },
    },
  );
  return services;
}

Widget _host(AppServices services, Widget page, {bool fake = true}) =>
    ProviderScope(
      overrides: [
        servicesProvider.overrideWithValue(services),
        if (fake) htmlBlockBuilderProvider.overrideWithValue(fakeBlock),
      ],
      child: testHost(page),
    );

/// The text of the writing brief field, whichever text field draws it.
String _brief(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('writing-brief')),
        matching: find.byType(EditableText),
        matchRoot: true,
      ),
    )
    .controller
    .text;

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  _workspaceTests();
  testWidgets('HTML and image visibility are independent and persist', (
    tester,
  ) async {
    _phone(tester);
    final services = await _services();
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    final repo = services.repository;
    final novel = await repo.createNovel(title: '阅读显示');
    final asset = await repo.storeAsset(
      branchId: novel.activeBranchId,
      name: '插图',
      prepared: PreparedAsset(
        hash: 'a' * 64,
        thumbnailHash: 'b' * 64,
        width: 100,
        height: 100,
        byteLength: 200,
      ),
    );
    final content = ManuscriptContent.fromDelta([
      {'insert': '前言。\n$_opening\n<div>状态面板</div>\n'},
      {
        'insert': {'image': 'asset:${asset.id}'},
      },
      {'insert': '\n正文继续。\n'},
    ]);
    await repo.createChapter(branchId: novel.activeBranchId, content: content);
    await tester.pumpWidget(
      _host(
        services,
        ReaderScreen(branchId: novel.activeBranchId),
        fake: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HtmlBlockView), findsNWidgets(2));
    expect(find.text('图片暂不可用'), findsOneWidget);

    await tester.tap(findAction('排版与主题').first);
    await tester.pumpAndSettle();
    expect(find.text('隐藏 HTML'), findsOneWidget);
    expect(find.text('隐藏插图'), findsOneWidget);
    await tester.tap(find.text('隐藏 HTML'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(HtmlBlockView), findsNothing);
    expect(find.text('图片暂不可用'), findsOneWidget);

    await tester.tap(find.text('隐藏插图'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(HtmlBlockView), findsNothing);
    expect(find.text('图片暂不可用'), findsNothing);
    expect(find.textContaining('正文继续', findRichText: true), findsWidgets);
    expect(find.textContaining('开启仙途', findRichText: true), findsNothing);
    expect(find.textContaining('状态面板', findRichText: true), findsNothing);
    expect((await repo.getSetting('reader'))?['hideHtml'], isTrue);
    expect((await repo.getSetting('reader'))?['hideImages'], isTrue);
    expect(
      (await repo.getStory(novel.activeBranchId)).chapters.single.content,
      content,
    );

    await tester.tap(find.text('隐藏 HTML'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(HtmlBlockView), findsNWidgets(2));
    expect(find.text('图片暂不可用'), findsNothing);
    await tester.tap(find.text('隐藏 HTML'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tapAt(const Offset(10, 100));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _host(
        services,
        ReaderScreen(branchId: novel.activeBranchId),
        fake: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HtmlBlockView), findsNothing);
    expect(find.text('图片暂不可用'), findsNothing);

    expect(find.text('插图已隐藏'), findsOneWidget);
    await tester.tap(find.text('显示插图'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(HtmlBlockView), findsNothing);
    expect(find.text('图片暂不可用'), findsOneWidget);
    expect(find.text('插图已隐藏'), findsNothing);
    expect((await repo.getSetting('reader'))?['hideHtml'], isTrue);
    expect((await repo.getSetting('reader'))?['hideImages'], isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inserting a hidden illustration offers to reveal only images', (
    tester,
  ) async {
    _phone(tester);
    final services = await _services();
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    final repo = services.repository;
    final novel = await repo.createNovel(title: '选段插图');
    const quote = '被选中的段落。';
    final chapter = await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('$quote\n后面的段落。\n'),
    );
    final asset = await repo.storeAsset(
      branchId: chapter.branchId,
      name: '选段插图',
      prepared: PreparedAsset(
        hash: 'a' * 64,
        thumbnailHash: 'b' * 64,
        width: 100,
        height: 100,
        byteLength: 200,
      ),
    );
    await repo.setSetting('reader', {
      'hideHtml': true,
      'hideImages': true,
      'indent': false,
    });
    await tester.pumpWidget(
      _host(services, ReaderScreen(branchId: chapter.branchId, embedded: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('插图已隐藏'), findsNothing);

    final conversation = await repo.createConversation(
      branchId: chapter.branchId,
    );
    await repo.appendAgentMessage(
      conversation,
      role: 'user',
      content: '为这段正文生成一张插图：\n\n$quote',
      metadata: {
        'illustrationAnchor': {
          'chapterId': chapter.id,
          'revisionId': chapter.revisionId,
          'endOffset': quote.length,
        },
      },
    );
    final inserted = await repo.insertAgentIllustration(
      branchId: chapter.branchId,
      assetId: asset.id,
      source: (await repo.getAgentMessages(conversation)).single,
    );
    await tester.pumpAndSettle();
    expect(inserted.content.text, '$quote\n\uFFFC\n后面的段落。\n');
    expect(find.text('插图已隐藏'), findsOneWidget);
    expect(find.text('图片暂不可用'), findsNothing);
    expect((await repo.getSetting('reader'))?['hideImages'], isTrue);

    await tester.tap(find.text('显示插图'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('图片暂不可用'), findsOneWidget);
    expect(find.text('插图已隐藏'), findsNothing);
    expect((await repo.getSetting('reader'))?['hideHtml'], isTrue);
    expect((await repo.getSetting('reader'))?['hideImages'], isFalse);
    final shown = tester
        .widget<RichText>(
          find.byWidgetPredicate(
            (widget) =>
                widget is RichText && widget.text.toPlainText().contains(quote),
          ),
        )
        .text
        .toPlainText();
    expect(shown.indexOf('\uFFFC'), greaterThan(shown.indexOf(quote)));
    expect(shown.indexOf('\uFFFC'), lessThan(shown.indexOf('后面的段落')));
    expect(
      (await repo.getChapter(
        branchId: chapter.branchId,
        chapterId: chapter.id,
      )).content,
      inserted.content,
    );
    expect(tester.takeException(), isNull);
  });

  test('reader document keeps offsets exact around an HTML block', () {
    const text = '前言\n$_opening\n正文继续\n';
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(ManuscriptContent.plainText(text)),
      fontSize: 18,
      image: (_) => const SizedBox(),
      html: (block, index) => Text('[block $index]'),
    );
    expect(doc.blocks, hasLength(1));
    final plain = doc.span.toPlainText();
    expect(plain, '前言\n￼\n正文继续\n');
    expect(doc.sourceOffset(plain.indexOf('正文')), text.indexOf('正文'));
    expect(doc.sourceOffset(plain.indexOf('￼')), text.indexOf('```html'));
    expect(doc.displayOffset(text.indexOf('正文')), plain.indexOf('正文'));
    final none = ReaderDocument.build(
      ManuscriptPresentation.identity(ManuscriptContent.plainText(text)),
      fontSize: 18,
      image: (_) => const SizedBox(),
    );
    expect(none.blocks, isEmpty);
    expect(none.span.toPlainText(), text);
  });

  testWidgets('hidden HTML never creates a view while opening', (tester) async {
    final services = await _services();
    addTearDown(services.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    final novel = await services.repository.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
    );
    await services.repository.setSetting('reader', {'hideHtml': true});
    var htmlBuilds = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          servicesProvider.overrideWithValue(services),
          htmlBlockBuilderProvider.overrideWithValue((request) {
            htmlBuilds++;
            return fakeBlock(request);
          }),
        ],
        child: testHost(ReaderScreen(branchId: novel.activeBranchId)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('开场后的旁白'), findsOneWidget);
    expect(htmlBuilds, 0);
  });

  test('hiding split HTML blocks and images keeps exact offsets', () {
    final content = ManuscriptContent.fromDelta([
      {'insert': '前言。\n```html\n<html><body>'},
      {
        'insert': '面板</body></html>\n```正文继续。\n<div>状态</div>\n',
        'attributes': {'bold': true},
      },
      {'insert': '插图前'},
      {
        'insert': {'image': 'asset:fixture'},
      },
      {'insert': '插图后。\n'},
    ]);
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 18,
      hideHtml: true,
      hideImages: true,
      image: (_) => throw StateError('hidden images must not be built'),
      html: (_, _) => throw StateError('hidden HTML must not be built'),
    );
    final shown = doc.span.toPlainText();
    expect(doc.blocks, isEmpty);
    expect(shown, '前言。\n正文继续。\n插图前插图后。\n');
    for (final word in ['前言', '正文', '插图前', '插图后']) {
      expect(doc.sourceOffset(shown.indexOf(word)), content.text.indexOf(word));
      expect(
        doc.displayOffset(content.text.indexOf(word)),
        shown.indexOf(word),
      );
    }
    expect(doc.sourceOffset(shown.length), content.text.length);
    expect(doc.displayOffset(content.text.length), shown.length);
  });

  test('HTML can be hidden even when HTML rendering is disabled', () {
    final content = ManuscriptContent.plainText(_opening);
    final doc = ReaderDocument.build(
      ManuscriptPresentation.identity(content),
      fontSize: 18,
      hideHtml: true,
      image: (_) => const SizedBox(),
    );
    expect(doc.span.toPlainText(), isEmpty);
    expect(doc.blocks, isEmpty);
    expect(doc.sourceOffset(0), content.text.length);
  });

  testWidgets('reader shows the source when no web view exists', (
    tester,
  ) async {
    _phone(tester);
    final services = await _services();
    addTearDown(services.close);
    final novel = await services.repository.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
    );
    await tester.pumpWidget(
      _host(
        services,
        ReaderScreen(branchId: novel.activeBranchId),
        fake: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('html-block-fallback')), findsOneWidget);
    expect(find.text('HTML 界面'), findsOneWidget);
    expect(find.textContaining('开场后的旁白'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'an opening page switches greetings, sets variables and sends a brief',
    (tester) async {
      _phone(tester);
      final services = await _services();
      addTearDown(services.close);
      final repo = services.repository;
      await repo.savePersona(const Persona(id: 'jiushen', name: '玖神'));
      final novel = await repo.createNovelFromCard(
        resourceId: 'card',
        title: '道渊',
        personaId: 'jiushen',
      );
      await tester.pumpWidget(
        _host(services, ReaderScreen(branchId: novel.activeBranchId)),
      );
      await tester.pumpAndSettle();
      expect(find.text('FAKE:frontend'), findsOneWidget);
      expect(find.textContaining('开启仙途'), findsNothing);

      await tester.tap(find.byKey(const Key('fake-setvar')));
      await tester.pumpAndSettle();
      expect(
        (await repo.getBranchVariables(novel.activeBranchId)).local['境界'],
        '凡人',
      );

      await tester.tap(find.byKey(const Key('fake-switch')));
      await tester.pumpAndSettle();
      final story = await repo.getStory(novel.activeBranchId);
      expect(story.chapters.single.content.text.trim(), '[重塑仙缘]');
      expect(
        (await repo.getSetting(
          'writing/${novel.activeBranchId}',
        ))?['greetingIndex'],
        1,
      );
      // The display regex turns the marker into the creation page.
      expect(find.text('FAKE:frontend'), findsOneWidget);
      expect(find.textContaining('重塑仙缘'), findsNothing);

      await tester.tap(find.byKey(const Key('fake-send')));
      await tester.pumpAndSettle();
      expect(find.text('生成正文'), findsOneWidget);
      expect(_brief(tester), '开启仙途');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('card start previews an HTML opening and keeps its request', (
    tester,
  ) async {
    _phone(tester);
    final services = await _services();
    addTearDown(services.close);
    await tester.pumpWidget(
      _host(services, const CardStartScreen(resourceId: 'card')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('helper-scripts-note')), findsOneWidget);
    expect(find.textContaining('MVU、道渊工坊'), findsOneWidget);
    expect(find.byKey(const Key('opening-preview')), findsOneWidget);
    expect(find.text('FAKE:frontend'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('opening-source-tile')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('opening-source-tile')), findsOneWidget);
    expect(find.byKey(const Key('opening-source')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('fake-switch')));
    await tester.tap(find.byKey(const Key('fake-switch')));
    await tester.pumpAndSettle();
    // Greeting 2 is the marker the card regex turns into a page.
    expect(find.text('FAKE:frontend'), findsOneWidget);
    expect(find.textContaining('备用开场 1'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('fake-setvar')));
    await tester.tap(find.byKey(const Key('fake-setvar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('fake-send')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已记录界面发出的写作要求'), findsOneWidget);
    // Let the snack bar go so it does not cover the create button.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('创建小说与初始资料'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('创建小说与初始资料'));
    await tester.pumpAndSettle();
    final repo = services.repository;
    final novel = (await repo.listNovels()).single;
    final story = await repo.getStory(novel.activeBranchId);
    expect(story.chapters.single.content.text.trim(), '[重塑仙缘]');
    expect(
      (await repo.getBranchVariables(novel.activeBranchId)).local['境界'],
      '凡人',
    );
    expect(find.text('生成正文'), findsOneWidget);
    expect(_brief(tester), '开启仙途');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('settings can turn HTML rendering off', (tester) async {
    _phone(tester);
    final services = await _services();
    addTearDown(services.close);
    await tester.pumpWidget(_host(services, const SettingsScreen()));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('settings-html')));
    await tester.tap(find.byKey(const Key('settings-html')));
    await tester.pumpAndSettle();
    expect(await services.repository.getSetting('html'), {'render': false});
    final novel = await services.repository.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
    );
    await tester.pumpWidget(
      _host(services, ReaderScreen(branchId: novel.activeBranchId)),
    );
    await tester.pumpAndSettle();
    expect(find.text('FAKE:frontend'), findsNothing);
    expect(find.textContaining('开启仙途'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}

void _workspaceTests() {
  testWidgets('the wide workspace preview renders HTML blocks too', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final services = await _services();
    addTearDown(services.close);
    final novel = await services.repository.createNovelFromCard(
      resourceId: 'card',
      title: '道渊',
    );
    await tester.pumpWidget(_host(services, NovelWorkspace(novelId: novel.id)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一章').first);
    await tester.pumpAndSettle();
    expect(find.text('FAKE:frontend'), findsOneWidget);
    expect(find.textContaining('开场后的旁白'), findsOneWidget);
    expect(find.textContaining('<html>'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
