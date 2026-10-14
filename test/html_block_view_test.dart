import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/features/html/html_block_view.dart';
import 'package:sillydraft/features/html/tavern_host.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/host.dart';

/// A web view backend whose channel setup waits for [gate]; records the
/// scripts run in its pages.
final class _Platform extends WebViewPlatform {
  _Platform(this.gate);
  final Future<void> gate;
  final scripts = <String>[];
  final controllers = <_Controller>[];
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _Controller(params, this);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _Delegate(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _View(params);
}

final class _Controller extends PlatformWebViewController {
  _Controller(super.params, this.platform) : super.implementation() {
    platform.controllers.add(this);
  }
  final _Platform platform;
  final scripts = <String>[];
  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest) onPermissionRequest,
  ) async {}
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) =>
      platform.gate;
  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}
  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
    platform.scripts.add(javaScript);
  }
}

final class _Delegate extends PlatformNavigationDelegate {
  _Delegate(super.params) : super.implementation();
  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}
  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

final class _View extends PlatformWebViewWidget {
  _View(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const SizedBox();
}

const _block = HtmlBlock(
  start: 0,
  end: 9,
  source: '<p>hi</p>',
  kind: HtmlBlockKind.fragment,
);

Widget _host(HtmlEventBus bus) => ProviderScope(
  child: testHost(HtmlBlockView(block: _block, width: 300, bus: bus)),
);

/// Lets the block's setup finish; its loading spinner never settles.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

List<String> _dispatches(List<String> scripts) =>
    scripts.where((s) => s.contains('__sdDispatch(')).toList();

/// Serves the page state only; the tests never reach the chat itself.
final class _Backend implements TavernChatBackend {
  @override
  Future<Map<String, dynamic>> snapshot(int messageId) async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Made inside each test, so the gate opens on the test's fake clock.
  _Platform install(Completer<void> gate) =>
      WebViewPlatform.instance = _Platform(gate.future);

  testWidgets('a loaded block receives events from the page bus', (
    tester,
  ) async {
    final platform = install(Completer()..complete());
    final bus = HtmlEventBus();
    await tester.pumpWidget(_host(bus));
    await _settle(tester);
    bus.broadcast('ping', const []);
    expect(_dispatches(platform.scripts), [
      'window.__sdDispatch && window.__sdDispatch("ping", []);',
    ]);
  });

  testWidgets('a block gone while its web view is set up leaves the bus', (
    tester,
  ) async {
    final gate = Completer<void>(), platform = install(gate);
    final bus = HtmlEventBus();
    await tester.pumpWidget(_host(bus));
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await _settle(tester);
    bus.broadcast('ping', const []);
    expect(_dispatches(platform.scripts), isEmpty);
  });

  testWidgets('an emitted event reaches each other block once, not its page', (
    tester,
  ) async {
    final platform = install(Completer()..complete());
    final bus = HtmlEventBus();
    TavernBridge bridge() => TavernBridge(
      backend: _Backend(),
      actions: FlutterTavernHost(
        context: () => throw UnimplementedError(),
        bus: bus,
        onWritingRequest: (_) async {},
      ),
      messageId: 0,
    );
    final emitter = bridge();
    await tester.pumpWidget(
      ProviderScope(
        child: testHost(
          Column(
            children: [
              HtmlBlockView(
                block: _block,
                width: 300,
                bus: bus,
                bridge: emitter,
              ),
              HtmlBlockView(
                block: _block,
                width: 300,
                bus: bus,
                bridge: bridge(),
              ),
            ],
          ),
        ),
      ),
    );
    await _settle(tester);
    // As the page's eventEmit does after running its own listeners.
    await emitter.handle('eventEmit', ['ping', <Object?>[]]);
    expect(platform.controllers.map((c) => _dispatches(c.scripts).length), [
      0,
      1,
    ]);
  });
}
