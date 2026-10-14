import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft/features/reader/reader_style.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../test/support/host.dart';

const _source = '''
<div id="plain" style="height:60px">正文颜色</div>
<div id="authored" style="color:rgb(12,34,56);height:40px">自定义颜色</div>
<div id="panel" style="height:100px;overflow:auto">
  <div id="inside" style="height:400px">内部滚动</div>
</div>
''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<WebViewController> mount(
    WidgetTester tester, {
    required ValueNotifier<Color> color,
    required ScrollController scroll,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: testHost(
          Scaffold(
            body: ValueListenableBuilder<Color>(
              valueListenable: color,
              builder: (context, value, _) => DefaultTextStyle.merge(
                style: TextStyle(color: value),
                child: SingleChildScrollView(
                  controller: scroll,
                  child: const Column(
                    children: [
                      SizedBox(height: 120),
                      HtmlBlockView(
                        block: HtmlBlock(
                          start: 0,
                          end: _source.length,
                          source: _source,
                          kind: HtmlBlockKind.fragment,
                        ),
                        width: 400,
                      ),
                      SizedBox(height: 1600),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      color.dispose();
      scroll.dispose();
    });
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      final controller = tester
          .state<HtmlBlockViewState>(find.byType(HtmlBlockView))
          .controller;
      if (controller == null) continue;
      if (await controller.runJavaScriptReturningResult(
            '!!document.getElementById("panel")',
          ) ==
          true) {
        return controller;
      }
    }
    throw TestFailure('HTML did not load');
  }

  testWidgets('HTML inherits reader color without overriding authored CSS', (
    tester,
  ) async {
    final color = ValueNotifier(ReaderTheme.paper.foreground);
    final controller = await mount(
      tester,
      color: color,
      scroll: ScrollController(),
    );
    Future<Object> css(String id, String property) =>
        controller.runJavaScriptReturningResult(
          'getComputedStyle(document.getElementById("$id")).$property',
        );
    expect(await css('plain', 'color'), 'rgb(52, 49, 46)');
    expect(await css('authored', 'color'), 'rgb(12, 34, 56)');
    expect(await css('plain', 'backgroundColor'), 'rgba(0, 0, 0, 0)');
    await controller.runJavaScript('window.pageState = "preserved"');
    color.value = ReaderTheme.night.foreground;
    await tester.pump(const Duration(milliseconds: 100));
    expect(await css('plain', 'color'), 'rgb(201, 198, 189)');
    expect(await css('authored', 'color'), 'rgb(12, 34, 56)');
    expect(
      await controller.runJavaScriptReturningResult('window.pageState'),
      'preserved',
    );
    await controller.runJavaScript(
      'document.body.style.color = "rgb(9, 8, 7)"',
    );
    color.value = ReaderTheme.green.foreground;
    await tester.pump(const Duration(milliseconds: 100));
    expect(await css('plain', 'color'), 'rgb(9, 8, 7)');
  });

  testWidgets('HTML hands only unconsumed wheel scrolling to its parent', (
    tester,
  ) async {
    final scroll = ScrollController(initialScrollOffset: 100);
    final controller = await mount(
      tester,
      color: ValueNotifier(ReaderTheme.paper.foreground),
      scroll: scroll,
    );
    Future<void> wheel(String id, double delta, {int mode = 0}) async {
      await controller.runJavaScript('''
        document.getElementById(${jsonEncode(id)}).dispatchEvent(new WheelEvent('wheel', {
          deltaY:$delta, deltaMode:$mode, bubbles:true, cancelable:true
        }));
      ''');
      await tester.pump(const Duration(milliseconds: 100));
    }

    await wheel('plain', 36);
    expect(scroll.offset, 136);
    await wheel('plain', -16);
    expect(scroll.offset, 120);
    await wheel('inside', 36);
    expect(scroll.offset, 120, reason: 'The inner panel can still scroll');
    await controller.runJavaScript(
      'document.getElementById("panel").scrollTop = 300',
    );
    await wheel('inside', 36);
    expect(scroll.offset, 156, reason: 'At its bottom, scroll chains outward');
    await wheel('inside', -36);
    expect(scroll.offset, 156, reason: 'The panel can scroll back up');
    await controller.runJavaScript('''
      document.getElementById('panel').style.overscrollBehaviorY = 'contain';
    ''');
    await wheel('inside', 36);
    expect(scroll.offset, 156, reason: 'CSS can explicitly block chaining');
    await controller.runJavaScript('''
      window.addEventListener('wheel', event => event.preventDefault(), {once:true, passive:false});
    ''');
    await wheel('plain', 36);
    expect(scroll.offset, 156, reason: 'Page handlers get the event first');
    await controller.runJavaScript('''
      SillyDraftScroll.postMessage('NaN');
      SillyDraftScroll.postMessage('Infinity');
      SillyDraftScroll.postMessage('invalid');
    ''');
    await tester.pump(const Duration(milliseconds: 100));
    expect(scroll.offset, 156);
    await wheel('plain', 1, mode: 1);
    expect(
      scroll.offset,
      greaterThan(156),
      reason: 'Line deltas become pixels',
    );
    await wheel('plain', -100000);
    expect(scroll.offset, 0, reason: 'The parent clamps at its own edge');
  });
}
