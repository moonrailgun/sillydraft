import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('EjsTemplate evaluates and persists variables in WebKit', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final errors = <Object?>[];
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.addJavaScriptChannel(
      'SillyDraftBridge',
      onMessageReceived: (message) async {
        final call = jsonDecode(message.message) as Map<String, dynamic>;
        if (call['method'] == 'replaceVariables') {
          requests.add(call);
        } else {
          if (call['method'] == 'log') errors.add(call['args']);
          await controller.runJavaScript(
            '__sdResolve(${call['id']}, true, null)',
          );
        }
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WebViewWidget(controller: controller)),
      ),
    );
    addTearDown(() async => tester.pumpWidget(const SizedBox()));
    debugPrint('EJS: loading document');
    await controller.loadHtmlString(
      HtmlBlocks.document(
        block: const HtmlBlock(
          start: 0,
          end: 0,
          source: '<p>模板测试</p>',
          kind: HtmlBlockKind.frontend,
        ),
        runtime: tavernRuntimeJs,
        state: const {
          'name1': '作者',
          'name2': '角色',
          'chat_id': 'test-chat',
          'message_id': 2,
          'messages': [
            {'message_id': 0, 'message': '开场', 'role': 'assistant'},
            {'message_id': 1, 'message': '继续', 'role': 'user'},
            {'message_id': 2, 'message': '正文', 'role': 'assistant'},
          ],
          'variables': {
            'global': {'shared': 'global', 'globalOnly': 1},
            'chat': {'shared': 'local', 'localOnly': 2},
            'messages': {
              '0': {'inherited': 7},
              '2': {'shared': 'message'},
            },
          },
        },
        nonce: 'test',
      ),
      baseUrl: 'https://render.sillydraft.invalid/',
    );
    Future<Object> js(String code) => controller
        .runJavaScriptReturningResult(code)
        .timeout(const Duration(seconds: 5));
    Future<void> waitFor(String expression) async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        await tester
            .pump(const Duration(milliseconds: 50))
            .timeout(const Duration(seconds: 10));
        if (await js(expression) == true) return;
      }
      fail('Timed out: $expression; $errors');
    }

    Future<Object?> run(String code) async {
      debugPrint('EJS: running ${code.trim().split('\n').first}');
      await controller
          .runJavaScript('''
        window.testResult = null;
        void (async function () {$code})().then(
          value => window.testResult = JSON.stringify({value}),
          error => window.testResult = JSON.stringify({error: String(error), stack: error.stack})
        );
      ''')
          .timeout(const Duration(seconds: 10));
      await waitFor('window.testResult !== null');
      final result = jsonDecode(await js('window.testResult') as String) as Map;
      expect(result['error'], isNull, reason: '${result['stack']}');
      return result['value'];
    }

    await waitFor('typeof EjsTemplate === "object" && typeof _ === "function"');
    debugPrint('EJS: libraries ready');
    expect(
      await run(r'''
      const e = EjsTemplate;
      const basic = await e.evalTemplate('<% print("A", null, 2); %><%= await Promise.resolve(html) %>', {html:'<b>生效</b>'});
      const custom = await e.evalTemplate('[?= count ?]', {count:3}, {openDelimiter:'[', closeDelimiter:']', delimiter:'?', _with:false});
      const compiled = await e.compileTemplate('<%= value %>|<%- include("part") %>', {
        options:{async:false}, escaper: v => '[' + v + ']', includer: name => 'included:' + name
      });
      window.syntaxExecuted = false;
      const lint = e.getSyntaxErrorInfo('<% window.syntaxExecuted = true; %>') === '';
      const invalid = e.getSyntaxErrorInfo('<% const x = ; %>').includes('column:');
      let rejected = false;
      try { await e.evalTemplate('<% throw new Error("template failure") %>', {}); }
      catch (error) { rejected = error.message.includes('template failure'); }
      return [basic, custom, compiled({value:'raw'}), lint, invalid, window.syntaxExecuted, rejected];
    '''),
      ['A2<b>生效</b>', '3', '[raw]|included:part', true, true, false, true],
    );

    expect(
      await run(r'''
      const e = EjsTemplate;
      e.initialVariables.initialOnly = 3;
      const ctx = await e.prepareContext({message_id:2}, 2);
      window.templateContext = ctx;
      const precedence = ['shared','globalOnly','localOnly','initialOnly','inherited'].map(k => ctx.getvar(k));
      ctx.setLocalVar('count', 3);
      ctx.incLocalVar('count', 2);
      const old = ctx.setLocalVar('count', 9, {results:'old'});
      ctx.setvar('bag', '{"gold":1}', {scope:'local'});
      ctx.setvar('bag', 4, {scope:'local', index:'gold'});
      ctx.setvar('items', ['a']);
      ctx.setvar('items', ['b'], {merge:true});
      ctx.delvar('items', 'a');
      ctx.setvar('locked', 1);
      ctx.setvar('locked', 2, {flags:'nx'});
      ctx.setvar('erasable', 1, {scope:'global'});
      ctx.delvar('erasable', undefined, {scope:'global'});
      ctx.define('greet', function () { return this.userName; });
      ctx.define('nested', {fromDefine:1});
      const next = await e.prepareContext({nested:{fromEnv:2}});
      eventOnce('prompt_template_prepare', async c => { await Promise.resolve(); c.fromEvent = c.z === z; });
      const prepared = (await e.prepareContext()).fromEvent;
      const nested = await ctx.evalTemplate('<%= charName %> / {{user}}');
      return [precedence, old, ctx.getLocalVar('count'), ctx.getLocalVar('bag', {index:'gold'}),
        ctx.getvar('items'), ctx.getvar('locked'), ctx.getGlobalVar('erasable') === undefined,
        next.greet(), next.nested, prepared, nested,
        [ctx.lastMessageId, ctx.lastUserMessageId, ctx.lastCharMessage, ctx.chatId]];
    '''),
      [
        ['message', 1, 2, 3, 7],
        5,
        9,
        4,
        ['b'],
        1,
        true,
        '作者',
        {'fromEnv': 2, 'fromDefine': 1},
        true,
        '角色 / 作者',
        [2, 1, '正文', 'test-chat'],
      ],
    );
    expect(
      await run(r'''
      const e = EjsTemplate, ctx = window.templateContext;
      ctx.setVariableSchema({score: z.number().nonnegative().optional()});
      ctx.setvar('score', 8);
      let invalid = false, feature = false, world = false, swipe = false;
      try { ctx.setvar('score', -1); } catch (error) { invalid = /schema/.test(error.message); }
      try { e.setFeatures({autosave_enabled:true, unknown:true}); } catch (_) { feature = true; }
      try { await e.refreshWorldInfo(); } catch (error) { world = /尚不支持/.test(error.message); }
      try { e.allVariables(2, 1); } catch (error) { swipe = /swipe/.test(error.message); }
      const parsed = e.parseJSON("{gold: 4,}");
      const patched = e.jsonPatch({gold:1}, [{op:'replace',path:'/gold',value:4}]);
      return [invalid, ctx.getvar('score'), feature, e.getFeatures().autosave_enabled, world, swipe, parsed.gold, patched.gold];
    '''),
      [true, 8, true, false, true, true, 4, 4],
    );

    // Default save is disabled. Force waits for the actual host acknowledgement.
    await run('await EjsTemplate.saveVariables();');
    expect(requests, isEmpty);
    await controller.runJavaScript('''
      window.saved = false; window.saveError = '';
      void EjsTemplate.saveVariables(true).then(() => saved = true, e => saveError = e.message);
    ''');
    final requestDeadline = DateTime.now().add(const Duration(seconds: 10));
    while (requests.isEmpty && DateTime.now().isBefore(requestDeadline)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(requests, hasLength(1));
    expect(await js('window.saved'), false);
    await controller.runJavaScript(
      '__sdResolve(${requests.last['id']}, false, "save failed")',
    );
    await waitFor('window.saveError === "save failed"');
    expect(await js('window.saved'), false);
    final failed = requests.single['args'];
    requests.clear();
    await controller.runJavaScript(
      'void EjsTemplate.saveVariables(true).then(() => saved = true)',
    );
    var replied = 0;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await js('window.saved') != true &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      while (replied < requests.length) {
        await controller.runJavaScript(
          '__sdResolve(${requests[replied++]['id']}, true, null)',
        );
      }
    }
    expect(await js('window.saved'), true);
    expect(requests.first['args'], failed);
    expect(
      requests.map((r) => (r['args'] as List)[1]),
      containsAll([
        {'type': 'chat'},
        {'type': 'message', 'message_id': 2},
      ]),
    );
    final writeCount = requests.length;
    await run('await EjsTemplate.saveVariables(true);');
    expect(requests, hasLength(writeCount));

    expect(
      await run(r'''
      document.open(); document.write('<html><head></head><body>重写</body></html>'); document.close();
      return await EjsTemplate.evalTemplate('<%= getLocalVar("count") %>/<%= greet() %>');
    '''),
      '9/作者',
    );
  });
}
