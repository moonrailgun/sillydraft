import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Tavern composer operations become one continuation in WebKit', (
    tester,
  ) async {
    final requests = <Map<String, dynamic>>[];
    final notices = <Object?>[];
    var loaded = false;
    final controller = WebViewController();
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(
      NavigationDelegate(onPageFinished: (_) => loaded = true),
    );
    await controller.addJavaScriptChannel(
      'SillyDraftBridge',
      onMessageReceived: (message) async {
        final call = jsonDecode(message.message) as Map<String, dynamic>;
        if (call['method'] == 'continueWriting') {
          requests.add(call);
        } else {
          if (call['method'] == 'toast') notices.add(call['args']);
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
    Future<void> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(condition(), isTrue);
    }

    Future<Object> js(String expression) => controller
        .runJavaScriptReturningResult(expression)
        .timeout(const Duration(seconds: 5));
    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 150));
    Future<void> reply(bool ok) async {
      await controller.runJavaScript(
        '__sdResolve(${requests.last['id']}, $ok, ${jsonEncode(ok ? null : '请先配置写作模型')})',
      );
      await settle();
    }

    await controller.loadHtmlString('''<!doctype html><html><head>
      <style data-sillydraft-host>body{color:rgb(1,2,3)}</style>
      <script>window.__SD_STATE = {api:true}; $tavernRuntimeJs</script>
      </head><body><p id="story">原有正文</p></body></html>''');
    await waitFor(() => loaded);
    expect(await js('!!parent.document.getElementById("send_textarea")'), true);
    expect(await js('document.getElementById("story").textContent'), '原有正文');
    expect(
      await js(
        'getComputedStyle(document.getElementById("send_textarea").parentElement).display',
      ),
      'none',
    );

    // The real preset uses the native setter, then both input events and send.
    await controller.runJavaScript('''
      var input = parent.document.getElementById('send_textarea');
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value')
        .set.call(input, '走进山洞 | 保留 /cut 原文');
      input.dispatchEvent(new Event('input', {bubbles:true}));
      input.dispatchEvent(new Event('change', {bubbles:true}));
      parent.document.getElementById('send_but').click();
      SillyTavern.getContext().generate();
    ''');
    await waitFor(() => requests.isNotEmpty);
    await settle();
    expect(requests, hasLength(1));
    expect(requests.single['args'], ['走进山洞 | 保留 /cut 原文']);
    await controller.runJavaScript(
      "input.dispatchEvent(new Event('input')); document.getElementById('send_but').click();",
    );
    await settle();
    expect(requests, hasLength(1));
    await reply(true);
    expect(await js('input.value'), '');

    // Plain assignments (also used by jQuery.val) coalesce to the final value.
    await controller.runJavaScript("input.value = '先'; input.value += '去灯塔';");
    await waitFor(() => requests.length == 2);
    expect(requests.last['args'], ['先去灯塔']);
    await reply(false);
    expect(await js('input.value'), '先去灯塔');
    await waitFor(() => notices.isNotEmpty);
    await controller.runJavaScript(
      "document.getElementById('send_but').click()",
    );
    await waitFor(() => requests.length == 3);
    expect(requests.last['args'], ['先去灯塔']);
    await reply(true);
    await controller.runJavaScript(
      "input.value = '  '; input.dispatchEvent(new Event('change'));",
    );
    await settle();
    expect(requests, hasLength(3));

    // Compressed community openings replace the document before using the composer.
    await controller.runJavaScript(
      "input.value = '等待保存'; __sdSetViewport(654)",
    );
    await waitFor(() => requests.length == 4);
    await controller.runJavaScript('''
      document.open();
      document.write('<!doctype html><html><head></head><body>新开场</body></html>');
      document.close();
      document.close();
    ''');
    await settle();
    expect(await js('!!parent.document.getElementById("send_textarea")'), true);
    expect(
      await js('document.querySelectorAll("[data-sillydraft-host]").length'),
      1,
    );
    expect(await js('getComputedStyle(document.body).color'), 'rgb(1, 2, 3)');
    expect(
      await js(
        'document.documentElement.style.getPropertyValue("--TH-viewport-height")',
      ),
      '654px',
    );
    await reply(true);
    expect(
      await js('parent.document.getElementById("send_textarea").value'),
      '',
    );
    await controller.runJavaScript('''
      const restored = parent.document.getElementById('send_textarea');
      Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(restored, '使用自定义开局');
      restored.dispatchEvent(new Event('input'));
      restored.dispatchEvent(new Event('change'));
      parent.document.getElementById('send_but').click();
    ''');
    await waitFor(() => requests.length == 5);
    expect(requests.last['args'], ['使用自定义开局']);
    await reply(true);
    expect(
      await js('parent.document.getElementById("send_textarea").value'),
      '',
    );

    loaded = false;
    await controller.loadHtmlString('''<!doctype html><html><head>
      <script>window.__SD_STATE = {api:false}; $tavernRuntimeJs</script>
      </head><body>普通片段</body></html>''');
    await waitFor(() => loaded);
    expect(await js('!!document.getElementById("send_textarea")'), false);
    await tester.pumpWidget(const SizedBox());
  });
}
