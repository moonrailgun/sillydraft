import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/support/host.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final animated in [false, true]) {
    testWidgets(
      'HTML reclaims space after ${animated ? 'animated' : 'details'} collapse',
      (tester) async {
        tester.platformDispatcher.localesTestValue = const [Locale('en')];
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
        final source = animated
            ? '''<style>body{display:flex;flex-direction:column;}
              #panel{max-height:0;overflow:hidden;transition:max-height .4s linear;}</style>
              <div style="height:60px">Header</div>
              <div id="panel"><div style="height:600px">Content</div></div>'''
            : '''<details id="panel"><summary style="height:60px">Header</summary>
              <div style="height:600px">Content</div></details>''';
        await tester.pumpWidget(
          ProviderScope(
            child: testHost(
              Scaffold(
                body: SingleChildScrollView(
                  child: HtmlBlockView(
                    block: HtmlBlock(
                      start: 0,
                      end: source.length,
                      source: source,
                      kind: HtmlBlockKind.fragment,
                    ),
                    width: 400,
                  ),
                ),
              ),
            ),
          ),
        );
        addTearDown(() async => tester.pumpWidget(const SizedBox()));
        Future<void> expectHeight(double height) async {
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          double actual = 0;
          while (DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            if (find.byType(WebViewWidget).evaluate().isEmpty) continue;
            actual = tester.getSize(find.byType(WebViewWidget)).height;
            if ((actual - height).abs() < 2) return;
          }
          final controller = tester
              .state<HtmlBlockViewState>(find.byType(HtmlBlockView))
              .controller;
          final metrics = await controller?.runJavaScriptReturningResult(
            'JSON.stringify({frame:innerHeight,body:document.body.scrollHeight,content:__sdContentHeight(),posts:__sdPosts})',
          );
          expect(actual, closeTo(height, 2), reason: '$metrics');
        }

        await expectHeight(60);
        final controller = tester
            .state<HtmlBlockViewState>(find.byType(HtmlBlockView))
            .controller!;
        for (var cycle = 0; cycle < 2; cycle++) {
          await controller.runJavaScript(
            animated
                ? 'document.getElementById("panel").style.maxHeight = "600px"'
                : 'document.getElementById("panel").open = true',
          );
          await expectHeight(660);
          await controller.runJavaScript(
            animated
                ? 'document.getElementById("panel").style.maxHeight = "0"'
                : 'document.getElementById("panel").open = false',
          );
          await expectHeight(60);
        }
      },
    );
  }
}
