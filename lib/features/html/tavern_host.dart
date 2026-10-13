import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';
import 'html_block_view.dart';

/// Host effects for HTML blocks on one page: toasts as forui toasts, events
/// relayed over the page's bus, and writing requests handed to the page.
final class FlutterTavernHost implements TavernHostActions {
  FlutterTavernHost({
    required this.context,
    required this.bus,
    required this.onWritingRequest,
  });

  /// The page's current context; evaluated late so it stays mounted.
  final BuildContext Function() context;
  final HtmlEventBus bus;
  final Future<void> Function(TavernWritingRequest request) onWritingRequest;

  @override
  void toast(String severity, String message, {String title = ''}) {
    final host = context();
    if (!host.mounted) return;
    final text = title.isEmpty ? message : '$title · $message';
    switch (severity) {
      case 'error':
        showError(host, text);
      case 'warning':
        showFToast(
          context: host,
          icon: const Icon(FLucideIcons.triangleAlert),
          title: Text(text),
        );
      default:
        showFToast(context: host, title: Text(text));
    }
  }

  @override
  Future<void> requestWriting(TavernWritingRequest request) =>
      onWritingRequest(request);

  @override
  void broadcast(String event, List<Object?> args, {Object? source}) =>
      bus.broadcast(event, args, source: source);

  @override
  void log(String level, String message) =>
      debugPrint('[html-block] $level: $message');
}
