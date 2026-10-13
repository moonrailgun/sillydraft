// End-to-end run against the author's own library and model connection:
// the real 《道渊》 card's opening page switches to the character-creation
// page, the form is filled and confirmed, and the resulting `/sys … | /cut
// 0 | /trigger` request is generated with the configured model. Local use
// only; it creates a novel in the real library.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/app/widgets.dart';
import 'package:sillydraft/features/agent/writing_request_screen.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft/features/reader/reader_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/support/host.dart';

const _out =
    '/private/tmp/claude-501/-Users-moonrailgun-sillydraft/4b630bf5-061a-46c6-aa0c-8851c2c8546d/scratchpad/e2e';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('道渊: create a character and generate the opening', (
    tester,
  ) async {
    Directory(_out).createSync(recursive: true);
    final log = File('$_out/e2e.log')..writeAsStringSync('');
    void note(String message) {
      log.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
      );
      debugPrint('[e2e] $message');
    }

    Future<void> settle(Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> waitFor(
      bool Function() condition,
      String what, {
      Duration timeout = const Duration(seconds: 30),
    }) async {
      final end = DateTime.now().add(timeout);
      while (!condition() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (!condition()) {
        note('timeout waiting for $what');
        fail('timeout waiting for $what');
      }
    }

    final services = await AppServices.open();
    final repo = services.repository;
    for (final c in await services.connections()) {
      note('connection ${c.name} ${c.protocol.name} ${c.model} ${c.baseUrl}');
      final doubled = c.baseUrl.indexOf('https://', 8);
      if (doubled > 0) {
        final fixed = c.baseUrl.substring(doubled);
        await services.saveConnection(
          ModelConnection.fromJson({...c.raw, 'baseUrl': fixed}),
        );
        note('baseUrl was pasted twice; saved as $fixed');
      }
    }
    final cards = await repo.listResources(kind: ResourceKind.character);
    final card = cards.firstWhere((r) => r.name.contains('道渊'));
    final now = DateTime.now();
    final novel = await repo.createNovelFromCard(
      resourceId: card.id,
      title: 'E2E 测试 · 道渊 ${now.hour}:${now.minute.toString().padLeft(2, '0')}',
      userName: '玖神',
    );
    final branch = novel.activeBranchId;
    note('novel ${novel.id} branch $branch');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: testHost(ReaderScreen(branchId: branch)),
      ),
    );
    HtmlBlockViewState? current() {
      if (find.byType(HtmlBlockView).evaluate().isEmpty) return null;
      final state = tester.state<HtmlBlockViewState>(
        find.byType(HtmlBlockView).first,
      );
      return state.controller == null ? null : state;
    }

    await waitFor(() => current() != null, 'opening web view');
    var state = current()!;
    final grow = DateTime.now().add(const Duration(seconds: 60));
    while (tester.getSize(find.byType(WebViewWidget).first).height <= 300 &&
        DateTime.now().isBefore(grow)) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    if (tester.getSize(find.byType(WebViewWidget).first).height <= 300) {
      try {
        note(
          'page1 stuck: ${await state.controller!.runJavaScriptReturningResult('JSON.stringify({ready: document.readyState, inner: innerHeight, scroll: document.body && document.body.scrollHeight, content: window.__sdContentHeight && window.__sdContentHeight(), api: typeof getChatMessages, height: window.SillyDraftHeight ? "channel" : "nochannel"})')}',
        );
      } catch (e) {
        note('page1 stuck and JS failed: $e');
      }
      fail('opening page did not grow');
    }
    await settle(const Duration(seconds: 3));
    note(
      'page1 frame ${tester.getSize(find.byType(WebViewWidget).first).height} content ${await state.controller!.runJavaScriptReturningResult('window.__sdContentHeight()')}',
    );
    await state.controller!.runJavaScript('switchToSecondGreeting()');
    final first = state.controller;
    await waitFor(
      () => current() != null && current()!.controller != first,
      'creation page web view',
    );
    state = current()!;
    await settle(const Duration(seconds: 6));
    Future<String> js(String script) async =>
        (await state.controller!.runJavaScriptReturningResult(script))
            .toString();
    note(
      'page2 ready: ${await js('document.title + " start=" + !!document.getElementById("start-button")')}',
    );
    await state.controller!.runJavaScript(
      'document.getElementById("start-button").click()',
    );
    await settle(const Duration(seconds: 2));
    await state.controller!.runJavaScript(
      'document.getElementById("simple-mode-btn").click()',
    );
    await settle(const Duration(seconds: 3));
    note(
      'form frame ${tester.getSize(find.byType(WebViewWidget).first).height} content ${await js('window.__sdContentHeight()')} active=${await js('document.querySelector(".screen.active") && document.querySelector(".screen.active").id')}',
    );
    await state.controller!.runJavaScript(r'''
      (function () {
        function set(id, value) { var e = document.getElementById(id); if (!e) return; e.value = value; e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true})); e.dispatchEvent(new Event('blur')); }
        set('char-name', '玖神');
        set('char-gender', '男');
        set('char-race', '人族');
        set('char-appearance', '剑眉星目，身形修长，常着青衫');
        set('char-identity', '山村散修');
        set('char-realm', '凡人（DC:0）');
        set('char-spirit-root', '五行杂灵根');
        set('char-technique', '无');
      })();
    ''');
    await settle(const Duration(seconds: 1));
    note('name=${await js('document.getElementById("char-name").value')}');
    await state.controller!.runJavaScript(
      'document.getElementById("confirm-creation-button").click()',
    );
    await waitFor(
      () => find.text('改写整章').evaluate().isNotEmpty,
      'writing request screen',
      timeout: const Duration(seconds: 60),
    );
    final brief = tester
        .widget<TextField>(find.byKey(const Key('writing-brief')))
        .controller!
        .text;
    note('brief:\n$brief');
    final variables = await repo.getBranchVariables(branch);
    note(
      'variables: ${variables.local.keys.toList()} stat_data=${variables.local['stat_data']?.substring(0, 200)}',
    );

    await tester.tap(find.text('预览提示词'));
    final requestList = find.descendant(
      of: find.byType(WritingRequestScreen),
      matching: find.byType(Scrollable),
    );
    final previewDeadline = DateTime.now().add(const Duration(seconds: 240));
    var ready = false;
    while (DateTime.now().isBefore(previewDeadline)) {
      await tester.pump(const Duration(milliseconds: 300));
      if (find.textContaining('预计 ').evaluate().isNotEmpty) {
        ready = true;
        break;
      }
      final texts = find
          .byType(Text)
          .evaluate()
          .map((e) => (e.widget as Text).data ?? '')
          .where((t) => t.length > 12)
          .toList();
      if (find.text('预览提示词').evaluate().isNotEmpty &&
          texts.any(
            (t) =>
                t.contains('Exception') ||
                t.contains('错误') ||
                t.contains('失败') ||
                t.contains('请先'),
          )) {
        note('preview error texts: ${texts.join(' | ')}');
        break;
      }
    }
    if (!ready) {
      note(
        'all texts: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '').join(' | ')}',
      );
      fail('prompt preview did not produce a draft');
    }
    await tester.scrollUntilVisible(
      find.text('开始生成候选'),
      400,
      scrollable: requestList.first,
    );
    await tester.pumpAndSettle();
    final startButton = find.widgetWithText(FButton, '开始生成候选');
    final enabled = tester.widget<FButton>(startButton).onPress != null;
    note('start enabled: $enabled');
    if (!enabled) {
      for (final a in find.byType(FAlert).evaluate()) {
        final alert = a.widget as FAlert;
        note(
          'diagnostic: ${(alert.title as Text?)?.data} ${(alert.subtitle as Text?)?.data}',
        );
      }
      fail('generation blocked by diagnostics');
    }
    await tester.tap(startButton);
    await settle(const Duration(seconds: 2));
    GenerationTask? task;
    final deadline = DateTime.now().add(const Duration(minutes: 6));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 500));
      final tasks = await repo.listTasks(branchId: branch);
      task = tasks.firstOrNull;
      if (task != null && !task.isActive) break;
    }
    note(
      'task ${task?.id} ${task?.status.name} error="${task?.error}" partial=${task?.partialText.length}',
    );
    final proposals = await repo.listProposals(branch);
    for (final p in proposals) {
      note('proposal ${p.id} ${p.status.name} ${p.content.text.length} chars');
      File('$_out/proposal.txt').writeAsStringSync(p.content.text);
    }
    expect(task?.status, TaskStatus.completed, reason: task?.error);
    expect(proposals, isNotEmpty);
    expect(proposals.first.content.text.trim(), isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await services.close();
  });
}
