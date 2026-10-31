import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

// Runtime-only Vue uses compiled render functions, as community bundles do.
const _page = r'''<!doctype html><html><body><div id="app"></div><script>
try {
  const settings = YAML.parse('count: 2\nlabel: "**开场**"');
  if (YAML.parse(YAML.stringify(settings)).count !== 2) throw new Error('YAML round trip failed');
  const markdown = new showdown.Converter().makeHtml(settings.label);
  const schema = z.object({count: z.coerce.number().int().nonnegative().default(0)});
  if (schema.safeParse({count: -1}).success) throw new Error('Validation failed');
  const count = Vue.ref(schema.parse({count: '2'}).count);
  const router = VueRouter.createRouter({
    history: VueRouter.createMemoryHistory(),
    routes: [{path: '/', component: {render: () => Vue.h('span', 'route ready')}}]
  });
  Vue.createApp({
    setup() {
      Vue.onMounted(() => $('#slider').slider({min: 0, max: 10, value: settings.count}));
      return () => Vue.h('main', [
        Vue.h('div', {id: 'markdown', innerHTML: markdown}),
        Vue.h('div', {id: 'slider'}),
        Vue.h('div', {id: 'tailwind', class: 'grid p-[17px]'}, 'utility styles'),
        Vue.h('p', {id: 'message'}, getChatMessages(0)[0].message),
        Vue.h(VueRouter.RouterView),
        Vue.h('button', {id: 'increment', onClick: async () => {
          count.value++;
          await setChatMessages([{message_id: 0, message: String(count.value)}]);
          window.saved = true;
        }}, String(count.value))
      ]);
    }
  }).use(router).mount('#app');
  window.libraryResult = 'ready';
} catch (error) {
  window.libraryResult = String(error);
}
</script></body></html>''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final rewrite in [false, true]) {
    testWidgets(
      'preloaded libraries work ${rewrite ? 'after document.write' : 'before card scripts'}',
      (tester) async {
        final writes = <Object?>[];
        final controller = WebViewController();
        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.addJavaScriptChannel(
          'SillyDraftBridge',
          onMessageReceived: (message) async {
            final call = jsonDecode(message.message) as Map<String, dynamic>;
            if (call['method'] == 'setChatMessages') writes.add(call['args']);
            await controller.runJavaScript(
              '__sdResolve(${call['id']}, true, null)',
            );
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: WebViewWidget(controller: controller)),
          ),
        );
        addTearDown(() async => tester.pumpWidget(const SizedBox()));
        final source = rewrite
            ? '<script>setTimeout(function () {document.open();document.write('
                  '${jsonEncode(_page).replaceAll('</', r'<\/')});'
                  'document.close();}, 0);</script>'
            : _page;
        debugPrint('Libraries: loading document (rewrite=$rewrite)');
        await controller.loadHtmlString(
          HtmlBlocks.document(
            block: HtmlBlock(
              start: 0,
              end: source.length,
              source: source,
              kind: HtmlBlockKind.frontend,
            ),
            runtime: tavernRuntimeJs,
            state: const {
              'messages': [
                {'message_id': 0, 'message': '开场正文', 'role': 'assistant'},
              ],
            },
            nonce: 'test',
          ),
          baseUrl: 'https://render.sillydraft.invalid/',
        );

        Future<Object> js(String script) => controller
            .runJavaScriptReturningResult(script)
            .timeout(const Duration(seconds: 5));
        Future<void> waitFor(String expression) async {
          final deadline = DateTime.now().add(const Duration(seconds: 45));
          while (DateTime.now().isBefore(deadline)) {
            // WebKit updates independently of Flutter's frame scheduling.
            await Future<void>.delayed(const Duration(milliseconds: 100));
            if (await js(expression) == true) return;
          }
          fail(
            'Timed out: $expression; ${await js("String(window.libraryResult)")}',
          );
        }

        await waitFor('typeof window.libraryResult === "string"');
        debugPrint('Libraries: page ready');
        expect(await js('window.libraryResult'), 'ready');
        expect(
          await js('document.querySelector("#markdown strong").textContent'),
          '开场',
        );
        await controller
            .runJavaScript('void \$("#slider").slider("value", 7)')
            .timeout(const Duration(seconds: 5));
        expect(await js('\$("#slider").slider("value")'), 7);
        expect(
          await js('!!document.querySelector("#slider .ui-slider-handle")'),
          true,
        );
        expect(await js('typeof \$.support.touch'), 'boolean');
        expect(
          await js(
            '!\$.support.touch || typeof \$.ui.mouse.prototype._touchStart === "function"',
          ),
          true,
        );
        await waitFor(
          'getComputedStyle(document.getElementById("tailwind")).paddingTop === "17px"',
        );
        expect(
          await js(
            'getComputedStyle(document.getElementById("tailwind")).display',
          ),
          'grid',
        );
        await controller.runJavaScript(
          'document.getElementById("tailwind").classList.add("mt-[23px]")',
        );
        await waitFor(
          'getComputedStyle(document.getElementById("tailwind")).marginTop === "23px"',
        );
        await waitFor('document.body.textContent.includes("route ready")');
        debugPrint('Libraries: styles and routing ready');
        expect(
          await js('document.getElementById("message").textContent'),
          '开场正文',
        );
        expect(
          await js('document.getElementById("increment").textContent'),
          '2',
        );
        await controller.runJavaScript(
          'document.getElementById("increment").click()',
        );
        await waitFor('window.saved === true');
        debugPrint('Libraries: bridge acknowledged');
        expect(
          await js('document.getElementById("increment").textContent'),
          '3',
        );
        expect(writes, [
          [
            [
              {'message_id': 0, 'message': '3'},
            ],
            <String, dynamic>{},
          ],
        ]);
      },
    );
  }
}
