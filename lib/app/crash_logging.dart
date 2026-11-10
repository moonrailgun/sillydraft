import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:url_launcher/url_launcher.dart';

LocalErrorLog? _localLog;
Future<void>? _initializing;
const _nativeDiagnostics = MethodChannel('app.sillydraft/diagnostics');

bool get canOpenCrashLogDirectory =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Called before telemetry and the library, so neither is needed for logging.
Future<void> initializeCrashLogging() async {
  if (_localLog != null) return;
  await (_initializing ??= _initialize().whenComplete(
    () => _initializing = null,
  ));
}

Future<void> _initialize() async {
  try {
    final directory = await crashLogDirectory();
    var version = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 3),
      );
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Diagnostics must still work if platform metadata is unavailable.
    }
    final log = LocalErrorLog.open(directory, version: version);
    _localLog = log;
    installLocalErrorHandlers(log);
  } catch (error) {
    // A full or read-only disk must not keep the author out of their library.
    try {
      stderr.writeln('SillyDraft: local error logging unavailable: $error');
    } catch (_) {
      // A GUI process may also have no usable stderr handle.
    }
  }
}

void recordLocalError(
  Object error,
  StackTrace stack, {
  required String source,
}) {
  _localLog?.record(error, stack, source: source);
}

void installLocalErrorHandlers(LocalErrorLog log) {
  // https://docs.flutter.dev/testing/errors: framework and uncaught asynchronous
  // errors have different handlers. Preserve the prior reporting/exit behavior.
  final flutterHandler = FlutterError.onError;
  FlutterError.onError = (details) {
    log.record(details.exception, details.stack, source: 'flutter');
    (flutterHandler ?? FlutterError.presentError)(details);
  };
  final platformHandler = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    log.record(error, stack, source: 'platform');
    return platformHandler?.call(error, stack) ?? false;
  };
}

Future<Directory> crashLogDirectory() async {
  if (Platform.isWindows) {
    // Use the runner's path, including its fallback when RoamingAppData cannot
    // be resolved. Dart and native crash records always share one directory.
    final path = await _nativeDiagnostics.invokeMethod<String>(
      'getLogDirectory',
    );
    if (path == null || path.isEmpty) throw StateError('无法确定崩溃日志目录');
    return Directory(path);
  }
  final support = await getApplicationSupportDirectory();
  return Directory('${support.path}/logs');
}

Future<void> openCrashLogDirectory({Future<bool> Function(Uri)? launch}) async {
  final directory = await crashLogDirectory();
  await directory.create(recursive: true);
  final opened = await (launch ?? _launchDirectory)(directory.uri);
  if (!opened) throw StateError('无法打开崩溃日志目录：${directory.path}');
}

Future<bool> _launchDirectory(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);
