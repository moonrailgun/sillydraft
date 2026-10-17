import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/services.dart';
import '../../app/theme.dart';
import '../../app/widgets.dart';

final appVersionProvider = FutureProvider<PackageInfo>(
  (_) => PackageInfo.fromPlatform(),
);

/// `update` holds the author's choices: `auto` (absent means on) and `skip`
/// (a dismissed version). The checker writes only `updateCheck.at` (epoch ms
/// of the last successful check), so it never overwrites a choice made while
/// a request was in flight.
Future<void> setAutoUpdateCheck(StoryRepository repository, bool value) async =>
    repository.setSetting('update', {
      ...?await repository.getSetting('update'),
      'auto': value,
    });

var _checking = false;

/// Looks for a newer release and offers it. The automatic check runs at most
/// once a day, stays silent on failure and honours “跳过此版本”; a [manual]
/// one always reports its outcome. One check (and its dialog) at a time.
Future<void> checkUpdates(
  BuildContext context,
  WidgetRef ref, {
  bool manual = false,
}) async {
  // Read everything from ref up front: a manual check may outlive the
  // settings route that started it.
  final services = ref.read(servicesProvider);
  final endpoint = services.updateEndpoint;
  if (endpoint == null) return;
  if (_checking) {
    if (manual) toast(context, '正在检查更新…');
    return;
  }
  final repository = services.repository;
  final version = ref.read(appVersionProvider.future);
  _checking = true;
  try {
    final setting = await repository.getSetting('update') ?? {};
    final last = (await repository.getSetting('updateCheck'))?['at'];
    final now = DateTime.now().millisecondsSinceEpoch;
    // A last check "in the future" means the clock moved back; check again.
    if (!manual &&
        (setting['auto'] == false ||
            last is int &&
                now >= last &&
                now - last < Duration.millisecondsPerDay)) {
      return;
    }
    final String current;
    final UpdateInfo? info;
    try {
      current = (await version).version;
      info = await checkForUpdate(
        current: current,
        platform: Platform.operatingSystem,
        endpoint: endpoint,
      );
      await repository.setSetting('updateCheck', {'at': now});
    } catch (e) {
      if (manual && context.mounted) {
        showError(context, switch (e) {
          HttpException(:final message) ||
          FormatException(:final message) => '检查更新失败：$message',
          _ => '检查更新失败：$e',
        });
      }
      return;
    }
    if (!context.mounted) return;
    if (info == null) {
      if (manual) toast(context, '已是最新版本', description: 'SillyDraft $current');
    } else if (manual || setting['skip'] != info.version) {
      await _offer(context, repository, info, current);
    }
  } finally {
    _checking = false;
  }
}

Future<void> _offer(
  BuildContext context,
  StoryRepository repository,
  UpdateInfo info,
  String current,
) => showAppDialog<void>(
  context: context,
  builder: (dialog) {
    final skip = FButton(
      variant: FButtonVariant.outline,
      onPress: () async {
        Navigator.pop(dialog);
        await repository.setSetting('update', {
          ...?await repository.getSetting('update'),
          'skip': info.version,
        });
      },
      child: const Text('跳过此版本'),
    );
    final later = FButton(
      variant: FButtonVariant.outline,
      onPress: () => Navigator.pop(dialog),
      child: const Text('稍后'),
    );
    final download = FButton(
      onPress: () async {
        Navigator.pop(dialog);
        var opened = false;
        try {
          opened = await launchUrl(
            Uri.parse(info.downloadUrl),
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {
          // Reported below like a launcher that declined the URL.
        }
        if (!opened && context.mounted) {
          showError(context, '无法打开浏览器：${info.downloadUrl}');
        }
      },
      prefix: const Icon(FLucideIcons.download),
      child: const Text('下载'),
    );
    return AppDialog(
      key: const Key('update-dialog'),
      title: Text('发现新版本 ${info.version}'),
      body: Text(
        '当前版本 $current\n\n${info.notes.isEmpty ? '这个版本没有更新说明。' : _plain(info.notes)}',
      ),
      actions: touchPlatform
          // Phones: the rest share a row; the download spans the dialog
          // below them, nearest the thumb.
          ? [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: skip),
                      const SizedBox(width: 8),
                      Expanded(child: later),
                    ],
                  ),
                  const SizedBox(height: 8),
                  download,
                ],
              ),
            ]
          : [skip, later, download],
    );
  },
);

/// Release notes are GitHub Markdown; drop heading marks and code ticks so
/// the plain-text dialog reads cleanly.
String _plain(String markdown) => markdown
    .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
    .replaceAll('`', '');
