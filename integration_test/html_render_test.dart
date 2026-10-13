import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/support/host.dart';

import 'daoyuan_fixture.dart';

/// An opening page like the ones 酒馆助手 cards ship: a full document with
/// `min-height: 100vh`, a button that switches to the second greeting
/// through the bridge, and a status line read back by the test.
const _opening = '''```html
<html>
<head>
<meta charset="UTF-8">
<style>
  body { min-height: 100vh; margin: 0; background: #030a16; color: #f0f8ff; font-family: sans-serif; }
  #card { padding: 24px; }
</style>
</head>
<body>
<div id="card">
  <h1>道渊</h1>
  <p id="status">等待</p>
  <button id="start" onclick="switchToSecondGreeting()">开启仙途</button>
</div>
<script>
  async function switchToSecondGreeting() {
    const msgs = await getChatMessages(0, { include_swipe: true });
    document.getElementById('status').textContent = 'swipes:' + msgs[0].swipes.length;
    await setChatMessage(msgs[0].swipes[1], 0, { swipe_id: 1, refresh: 'display_and_render_current' });
  }
</script>
</body>
</html>
```''';

const _creationPage = '''```html
<html>
<head><title>创建</title></head>
<body>
<p id="who"></p>
<button id="send" onclick="triggerSlash('/sys [仙缘已定] 道号：玖神 | /cut 0 | /trigger')">开始</button>
<script>
  document.getElementById('who').textContent = getCharData().name + '/' + getCurrentMessageId();
  insertOrAssignVariables({ stat_data: { 主角: { 境界: '凡人' } } }, { type: 'message', message_id: 0 });
</script>
</body>
</html>
```''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HTML opening renders in a real web view and drives the bridge', (
    tester,
  ) async {
    Future<void> waitFor(
      bool Function() condition, {
      Duration timeout = const Duration(seconds: 20),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue);
    }

    final directory = await Directory.systemTemp.createTemp('sillydraft-html-');
    final repository = StoryRepository.open('${directory.path}/library.sqlite');
    final services = AppServices(
      repository: repository,
      secrets: MemorySecrets(),
      dataDirectory: directory,
    );
    await repository.storeResource(
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
          'first_mes': _opening,
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
          },
        },
      },
    );
    final novel = await repository.createNovelFromCard(
      resourceId: 'card',
      title: 'HTML 验证',
      userName: '玖神',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(ReaderScreen(branchId: novel.activeBranchId)),
      ),
    );
    await waitFor(() => find.byType(WebViewWidget).evaluate().isNotEmpty);

    // The page measured itself: 100vh maps to the window height, so the
    // block grows well past the placeholder height.
    final grow = DateTime.now().add(const Duration(seconds: 20));
    while (tester.getSize(find.byType(WebViewWidget).first).height <= 300 &&
        DateTime.now().isBefore(grow)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (tester.getSize(find.byType(WebViewWidget).first).height <= 300) {
      final c = tester
          .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
          .controller;
      debugPrint(
        '[diag] js: ${await c?.runJavaScriptReturningResult('JSON.stringify({ready: document.readyState, inner: innerHeight, scroll: document.body.scrollHeight, posts: window.__sdPosts})')}',
      );
      debugPrint('[diag] dart: ${HtmlBlockViewState.debugLog.join(' || ')}');
      fail('opening page did not grow');
    }
    final controller = tester
        .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
        .controller!;
    Future<String> js(String script) async =>
        (await controller.runJavaScriptReturningResult(script)).toString();
    expect(
      await js(
        'typeof getChatMessages + ":" + typeof setChatMessage + ":" + getLastMessageId() + ":" + getIframeName()',
      ),
      contains('function:function:0:TH-message--0--0'),
    );
    expect(
      await js('getChatMessages(0, {include_swipe: true})[0].swipes.length'),
      contains('2'),
    );
    expect(
      await js('getVariables({type: "chat"}).stat_data === undefined'),
      contains('true'),
    );

    // The opening page's own button: switch to the second greeting.
    await controller.runJavaScript('document.getElementById("start").click()');
    Future<String> chapterText() async =>
        (await repository.getStory(novel.activeBranchId))
            .chapters
            .first
            .content
            .text
            .trim();
    var text = await chapterText();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (text != '[重塑仙缘]' && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      text = await chapterText();
    }
    expect(text, '[重塑仙缘]');
    expect(
      (await repository.getSetting(
        'writing/${novel.activeBranchId}',
      ))?['greetingIndex'],
      1,
    );

    // The marker shows as the creation page through the card's display
    // regex, in a fresh web view; its script reads card data and writes
    // message variables.
    await waitFor(() {
      if (find.byType(HtmlBlockView).evaluate().isEmpty) return false;
      final next = tester
          .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
          .controller;
      return next != null && next != controller;
    });
    final second = tester
        .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
        .controller!;
    var who = '';
    final until = DateTime.now().add(const Duration(seconds: 15));
    while (!who.contains('道渊/0') && DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 200));
      try {
        who = (await second.runJavaScriptReturningResult(
          'document.getElementById("who").textContent',
        )).toString();
      } catch (_) {}
    }
    expect(who, contains('道渊/0'));
    var variables = await repository.getBranchVariables(novel.activeBranchId);
    final stored = DateTime.now().add(const Duration(seconds: 15));
    while (!variables.local.containsKey('stat_data') &&
        DateTime.now().isBefore(stored)) {
      await tester.pump(const Duration(milliseconds: 200));
      variables = await repository.getBranchVariables(novel.activeBranchId);
    }
    expect(variables.local['stat_data'], contains('凡人'));

    // `/sys … | /cut 0 | /trigger` opens a rewrite request for chapter 0 with
    // the text as the brief; nothing generates by itself.
    await second.runJavaScript('document.getElementById("send").click()');
    await waitFor(() => find.text('改写整章').evaluate().isNotEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('writing-brief')))
          .controller!
          .text,
      '[仙缘已定] 道号：玖神',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await services.close();
  });

  /// The real 《道渊》 card's opening page (fireworks canvas, Google fonts,
  /// a bridge-driven button) and its character-creation page, from a
  /// fixture that keeps the card's HTML and regex but not its world book.
  testWidgets('a real 酒馆助手 card opening renders and switches greetings', (
    tester,
  ) async {
    Future<void> waitFor(
      bool Function() condition, {
      Duration timeout = const Duration(seconds: 40),
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue);
    }

    final directory = await Directory.systemTemp.createTemp('sillydraft-card-');
    final repository = StoryRepository.open('${directory.path}/library.sqlite');
    final services = AppServices(
      repository: repository,
      secrets: MemorySecrets(),
      dataDirectory: directory,
    );
    await repository.storeResource(
      id: 'daoyuan',
      kind: ResourceKind.character,
      name: '道渊',
      filename: 'card.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: jsonDecode(daoyuanFixtureJson) as Map<String, dynamic>,
    );
    final novel = await repository.createNovelFromCard(
      resourceId: 'daoyuan',
      title: '道渊',
      userName: '玖神',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(ReaderScreen(branchId: novel.activeBranchId)),
      ),
    );
    await waitFor(() => find.byType(WebViewWidget).evaluate().isNotEmpty);
    await waitFor(
      () => tester.getSize(find.byType(WebViewWidget).first).height > 300,
    );
    final controller = tester
        .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
        .controller!;
    Future<String> js(String script) async =>
        (await controller.runJavaScriptReturningResult(script)).toString();
    expect(
      await js(
        '[document.getElementById("info-card") !== null, document.getElementById("fireworks-canvas") !== null, typeof switchToSecondGreeting].join(",")',
      ),
      contains('true,true,function'),
    );
    expect(
      await js('getChatMessages(0, {include_swipe: true})[0].swipes.length'),
      contains('2'),
    );
    // The frame follows the page: the web view is resized to the frame, the
    // frame is never shorter than what overflows the body, and never taller
    // than the larger of the body's overflow and the visible content (so no
    // blank space is left below the page).
    Future<void> expectFitted(WebViewController c) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      double frame = 0, content = 0, inner = 0, scroll = 0;
      Future<double> number(String script) async => double.parse(
        (await c.runJavaScriptReturningResult(script)).toString(),
      );
      bool fitted() =>
          (frame - inner).abs() < 2 &&
          frame >= scroll - 2 &&
          frame <= (content > scroll ? content : scroll) + 12;
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 300));
        frame = tester.getSize(find.byType(WebViewWidget).first).height;
        inner = await number('innerHeight');
        scroll = await number('document.body.scrollHeight');
        content = await number('window.__sdContentHeight()');
        if (fitted()) break;
      }
      expect(
        fitted(),
        isTrue,
        reason: 'frame $frame inner $inner scroll $scroll content $content',
      );
    }

    await expectFitted(controller);
    // The card's own button: 开启仙途.
    await controller.runJavaScript('switchToSecondGreeting()');
    var text = '';
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (text != '[重塑仙缘]' && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      text = (await repository.getStory(novel.activeBranchId))
          .chapters
          .first
          .content
          .text
          .trim();
    }
    expect(text, '[重塑仙缘]');
    // The card regex turns the marker into its character-creation page.
    await waitFor(() {
      if (find.byType(HtmlBlockView).evaluate().isEmpty) return false;
      final next = tester
          .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
          .controller;
      return next != null && next != controller;
    });
    final second = tester
        .state<HtmlBlockViewState>(find.byType(HtmlBlockView).first)
        .controller!;
    var title = '';
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (!title.contains('道渊') && DateTime.now().isBefore(until)) {
      await tester.pump(const Duration(milliseconds: 200));
      try {
        title = (await second.runJavaScriptReturningResult(
          'document.title + "|" + document.body.innerText.length',
        )).toString();
      } catch (_) {}
    }
    expect(title, contains('道渊'));
    await expectFitted(second);
    await second.runJavaScript(
      'document.getElementById("start-button").click()',
    );
    await tester.pump(const Duration(seconds: 2));
    await second.runJavaScript(
      'document.getElementById("simple-mode-btn").click()',
    );
    await expectFitted(second);
    debugPrint('real card creation page: $title');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await services.close();
  });
}
