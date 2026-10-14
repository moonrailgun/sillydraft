import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../app/widgets.dart';

/// Origin HTML blocks load under. `.invalid` never resolves, so relative
/// URLs fail harmlessly, while `localStorage` keeps one stable origin as it
/// does in SillyTavern, where every iframe shares the page origin.
const htmlBlockOrigin = 'https://render.sillydraft.invalid/';

/// Whether this platform can show blocks in a web view. Windows and Linux
/// have no backend yet and show the source instead.
bool get htmlBlocksSupported =>
    !kIsWeb &&
    const {
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform) &&
    WebViewPlatform.instance != null;

/// What one block needs to render; also what a test double receives.
final class HtmlBlockRequest {
  const HtmlBlockRequest({
    required this.block,
    required this.width,
    this.bridge,
    this.bus,
  });
  final HtmlBlock block;
  final double width;
  final TavernBridge? bridge;
  final HtmlEventBus? bus;
}

/// Replaces the web view in tests, which have no platform web view.
final htmlBlockBuilderProvider =
    Provider<Widget Function(HtmlBlockRequest request)?>((_) => null);

/// Delivers `eventEmit` between the blocks of one page. In 酒馆助手 every
/// iframe's listeners sit on SillyTavern's one `eventSource`, so each runs
/// once per emit (JS-Slash-Runner `src/function/event.ts`). A page here has
/// already run its own listeners, so members get the emitting [source] (its
/// bridge) to skip their own events.
final class HtmlEventBus {
  final _members =
      <Object, void Function(String, List<Object?>, Object? source)>{};
  void join(
    Object member,
    void Function(String event, List<Object?> args, Object? source) deliver,
  ) => _members[member] = deliver;
  void leave(Object member) => _members.remove(member);
  void broadcast(String event, List<Object?> args, {Object? source}) {
    for (final deliver in _members.values.toList()) {
      deliver(event, args, source);
    }
  }
}

/// One HTML block of a manuscript in a sandboxed web view, sized to its
/// content. The page gets the 酒馆助手-style API through [bridge]; without
/// one (raw fragments) it only renders.
///
/// Sandbox: the page loads from a string under a reserved origin, may fetch
/// only over TLS, cannot navigate the view away, open plugins, use camera
/// or microphone, or reach anything the bridge does not expose.
class HtmlBlockView extends ConsumerStatefulWidget {
  const HtmlBlockView({
    super.key,
    required this.block,
    required this.width,
    this.bridge,
    this.bus,
    this.viewportHeight,
  });
  final HtmlBlock block;
  final double width;
  final TavernBridge? bridge;
  final HtmlEventBus? bus;

  /// Height `100vh` in the page maps to; the window height by default.
  final double? viewportHeight;

  @override
  ConsumerState<HtmlBlockView> createState() => HtmlBlockViewState();
}

class HtmlBlockViewState extends ConsumerState<HtmlBlockView> {
  /// Recent height messages and lifecycle notes, for integration diagnostics.
  static final debugLog = _BoundedLog();
  WebViewController? _controller;

  /// The live web view, for integration tests that drive the page.
  WebViewController? get controller => _controller;
  double _height = 160;
  double? _viewport;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  DateTime? _lastNotice;

  @override
  void initState() {
    super.initState();
    debugLog.add('init ${widget.key} ${widget.block.source.hashCode}');
    unawaited(_start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final viewport = widget.viewportHeight ?? MediaQuery.sizeOf(context).height;
    if (viewport != _viewport) {
      _viewport = viewport;
      _run(
        'window.__sdSetViewport && window.__sdSetViewport(${viewport.round()});',
      );
    }
  }

  @override
  void didUpdateWidget(HtmlBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.block.source != widget.block.source ||
        oldWidget.block.kind != widget.block.kind) {
      unawaited(_start());
    } else if (oldWidget.width != widget.width) {
      _run('window.__sdMeasure && window.__sdMeasure();');
    }
  }

  @override
  void dispose() {
    debugLog.add('dispose ${widget.key}');
    widget.bus?.leave(this);
    _generation++;
    super.dispose();
  }

  void _run(String script) {
    final controller = _controller;
    if (controller == null) return;
    unawaited(controller.runJavaScript(script).catchError((Object _) {}));
  }

  Future<void> _start() async {
    if (!htmlBlocksSupported || ref.read(htmlBlockBuilderProvider) != null) {
      return;
    }
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    var state = const <String, dynamic>{};
    try {
      if (widget.bridge case final bridge?) state = await bridge.state();
    } catch (error) {
      _error = '界面数据暂不可用：$error';
    }
    if (!mounted || generation != _generation) return;
    final document = HtmlBlocks.document(
      block: widget.block,
      runtime: tavernRuntimeJs,
      state: state,
      nonce: HtmlBlocks.nonce(),
      viewportHeight: _viewport ?? 800,
    );
    try {
      final controller = _controller ?? await _createController();
      if (!mounted || generation != _generation) return;
      await controller.loadHtmlString(document, baseUrl: htmlBlockOrigin);
      if (!mounted || generation != _generation) return;
      // Joined only once mounted and current: a block disposed while its web
      // view was being set up would otherwise stay on the bus for good.
      widget.bus?.join(this, (event, args, source) {
        // Emitted by this page, whose own listeners already ran.
        if (source != null && identical(source, widget.bridge)) return;
        _run(
          'window.__sdDispatch && window.__sdDispatch(${jsonEncode(event)}, ${jsonEncode(args)});',
        );
      });
      setState(() {
        _controller = controller;
        _loading = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = '无法显示 HTML 区块：$error';
        });
      }
    }
  }

  Future<WebViewController> _createController() async {
    final controller = WebViewController(
      onPermissionRequest: (request) => request.deny(),
    );
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await _quietly(
      () => controller.setBackgroundColor(const Color(0x00000000)),
    );
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final url = request.url;
          if (url.startsWith(htmlBlockOrigin) || url == 'about:blank') {
            return NavigationDecision.navigate;
          }
          if (!request.isMainFrame && url.startsWith('https://')) {
            return NavigationDecision.navigate;
          }
          _notice('已阻止页面跳转：$url');
          return NavigationDecision.prevent;
        },
        onWebResourceError: (error) {
          debugPrint(
            '[html-block] resource error ${error.errorCode}: ${error.description}',
          );
        },
      ),
    );
    await controller.addJavaScriptChannel(
      'SillyDraftHeight',
      onMessageReceived: (message) {
        final height = double.tryParse(message.message);
        debugLog.add(
          'height ${message.message} mounted=$mounted current=$_height',
        );
        if (height == null || !mounted) return;
        final next = height.clamp(24, 20000).toDouble();
        if ((next - _height).abs() >= 1) setState(() => _height = next);
      },
    );
    await controller.addJavaScriptChannel(
      'SillyDraftBridge',
      onMessageReceived: (message) => unawaited(_onBridge(message.message)),
    );
    await _quietly(
      () => controller.setOnJavaScriptAlertDialog((request) async {
        if (!mounted) return;
        await showAppDialog<void>(
          context: context,
          builder: (dialog) => AppDialog(
            // The page's message is the whole dialog, as in a browser.
            title: const SizedBox.shrink(),
            body: SelectableText(request.message),
            actions: [
              FButton(
                onPress: () => Navigator.pop(dialog),
                child: const Text('确定'),
              ),
            ],
          ),
        );
      }),
    );
    await _quietly(
      () => controller.setOnJavaScriptConfirmDialog((request) async {
        if (!mounted) return false;
        return await showAppDialog<bool>(
              context: context,
              builder: (dialog) => AppDialog(
                title: const SizedBox.shrink(),
                body: SelectableText(request.message),
                actions: [
                  FButton(
                    variant: FButtonVariant.outline,
                    onPress: () => Navigator.pop(dialog, false),
                    child: const Text('取消'),
                  ),
                  FButton(
                    onPress: () => Navigator.pop(dialog, true),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ) ??
            false;
      }),
    );
    await _quietly(
      () => controller.setOnJavaScriptTextInputDialog((request) async {
        if (!mounted) return '';
        return await askText(
              context,
              title: request.message,
              initial: request.defaultText ?? '',
              label: '输入',
            ) ??
            '';
      }),
    );
    await _quietly(
      () => controller.setOnConsoleMessage((message) {
        if (message.level == JavaScriptLogLevel.error ||
            message.level == JavaScriptLogLevel.warning) {
          debugPrint('[html-block] ${message.level.name}: ${message.message}');
        }
      }),
    );
    return controller;
  }

  /// Platform backends differ in what they implement; an unsupported
  /// nicety must not stop the block from rendering.
  Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      debugPrint('[html-block] optional setup skipped: $error');
    }
  }

  Future<void> _onBridge(String raw) async {
    final bridge = widget.bridge;
    if (bridge == null) return;
    final result = await bridge.handleMessage(raw);
    if (!mounted || result.id == 0) return;
    _run(
      'window.__sdResolve(${result.id}, ${result.ok}, ${jsonEncode(result.payload)});',
    );
  }

  void _notice(String message) {
    final now = DateTime.now();
    if (_lastNotice != null &&
        now.difference(_lastNotice!) < const Duration(seconds: 3)) {
      return;
    }
    _lastNotice = now;
    if (mounted) showError(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final builder = ref.watch(htmlBlockBuilderProvider);
    if (builder != null) {
      return builder(
        HtmlBlockRequest(
          block: widget.block,
          width: widget.width,
          bridge: widget.bridge,
          bus: widget.bus,
        ),
      );
    }
    if (!htmlBlocksSupported) {
      return HtmlBlockFallback(block: widget.block, width: widget.width);
    }
    final controller = _controller;
    return SizedBox(
      width: widget.width,
      height: _height,
      child: Stack(
        children: [
          if (controller != null)
            Positioned.fill(
              child: WebViewWidget(
                key: ValueKey(controller),
                controller: controller,
              ),
            ),
          if (_loading)
            const Positioned(
              top: 8,
              right: 8,
              child: FCircularProgress(size: FCircularProgressSizeVariant.sm),
            ),
          if (_error case final error?)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Text(
                error,
                style: context.theme.typography.body.xs.copyWith(
                  color: context.theme.colors.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Where no web view exists: a labelled box with the source on request.
class HtmlBlockFallback extends StatefulWidget {
  const HtmlBlockFallback({
    super.key,
    required this.block,
    required this.width,
  });
  final HtmlBlock block;
  final double width;

  @override
  State<HtmlBlockFallback> createState() => _HtmlBlockFallbackState();
}

class _HtmlBlockFallbackState extends State<HtmlBlockFallback> {
  /// The source is laid out only once it has been asked for.
  bool _opened = false;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final block = widget.block;
    final source = block.source.length > 20000
        ? '${block.source.substring(0, 20000)}\n…'
        : block.source;
    return SizedBox(
      width: widget.width,
      child: Container(
        key: const Key('html-block-fallback'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colors.border),
          borderRadius: theme.style.borderRadius.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FItem(
              prefix: const Icon(FLucideIcons.codeXml),
              title: Text(
                block.kind == HtmlBlockKind.frontend ? 'HTML 界面' : 'HTML 片段',
              ),
              subtitle: const Text('此平台暂不支持内嵌网页渲染，这里显示源码。'),
            ),
            FAccordion(
              control: FAccordionControl.managed(
                onChange: (open) {
                  if (open.isNotEmpty && !_opened) {
                    setState(() => _opened = true);
                  }
                },
              ),
              children: [
                FAccordionItem(
                  title: const Text('查看源码'),
                  child: _opened
                      ? SelectableText(
                          source,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Keeps the last entries only.
class _BoundedLog {
  final _entries = <String>[];
  void add(String entry) {
    _entries.add(entry);
    if (_entries.length > 200) _entries.removeAt(0);
  }

  String join(String separator) => _entries.join(separator);
}
