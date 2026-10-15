import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/library_host.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';
import 'share_screen.dart';

final pairedDesktopsProvider = FutureProvider<List<ConnectLink>>(
  (ref) => PairedDesktops(ref.watch(servicesProvider).secrets).list(),
);

final remoteStatusProvider = StreamProvider<RemoteStatus>(
  (ref) =>
      ref.watch(servicesProvider).remote?.statuses ??
      Stream.value((connected: true, problem: null)),
);

/// Opens [link]'s library, or this device's own for null. Leaving this
/// device's library first asks when its own tasks are still running;
/// leaving a desktop that cannot take unsaved drafts asks before dropping
/// them.
Future<void> switchLibrary(
  BuildContext context,
  WidgetRef ref,
  ConnectLink? link,
) async {
  final host = ref.read(libraryHostProvider),
      services = ref.read(servicesProvider);
  try {
    if (link == null) {
      try {
        return await host.openLocal();
      } on RemoteUnavailable {
        if (!context.mounted ||
            !await confirmAction(
              context,
              title: '桌面已断开',
              message: '未保存的修改和阅读位置无法写回桌面。仍要切回本机吗？',
              confirmLabel: '放弃并切换',
              destructive: true,
            )) {
          return;
        }
        return await host.openLocal(discardUnsaved: true);
      }
    }
    if (services.remote?.link.fingerprint == link.fingerprint) return;
    if (services.remote == null) {
      final running = (await services.repository.listTasks())
          .where((t) => t.isActive)
          .length;
      if (running > 0 &&
          (!context.mounted ||
              !await confirmAction(
                context,
                title: '切换作品库？',
                message: '切换会中断 $running 个本机任务。',
                confirmLabel: '切换',
              ))) {
        return;
      }
    }
    await host.openRemote(link);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// The bookshelf title on a phone: which library is open, and a menu to
/// switch.
class LibrarySwitcher extends ConsumerWidget {
  const LibrarySwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remote = ref.watch(servicesProvider).remote;
    final paired = ref.watch(pairedDesktopsProvider).value ?? const [];
    final theme = context.theme;
    return MenuAction(
      tooltip: '切换作品库',
      entries: [
        menuEntry(
          '本机',
          () => switchLibrary(context, ref, null),
          icon: FLucideIcons.smartphone,
        ),
        for (final link in paired)
          menuEntry(
            '${link.name}（${link.host}）',
            () => switchLibrary(context, ref, link),
            icon: FLucideIcons.monitor,
          ),
        menuEntry(
          '扫码添加桌面',
          () => scanLink(context, ref),
          icon: FLucideIcons.scanLine,
        ),
        menuEntry(
          '粘贴链接',
          () => pasteLink(context, ref),
          icon: FLucideIcons.clipboardPaste,
        ),
        if (paired.isNotEmpty)
          menuEntry(
            '管理配对',
            () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const PairedDesktopsScreen(),
              ),
            ),
            icon: FLucideIcons.settings2,
          ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            remote == null ? FLucideIcons.libraryBig : FLucideIcons.monitor,
            size: 24,
            color: theme.colors.foreground,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              remote == null ? 'SillyDraft' : '桌面：${remote.hello.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            FLucideIcons.chevronDown,
            size: 18,
            color: theme.colors.mutedForeground,
          ),
        ],
      ),
    );
  }
}

/// [child] under a bar saying the desktop is unreachable, with a way back
/// to this device's library.
class RemoteFrame extends ConsumerWidget {
  const RemoteFrame({super.key, required this.navigator, required this.child});

  /// The app's navigator, which this frame sits above: dialogs open there.
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(remoteStatusProvider).value;
    if (status == null || status.connected) return child;
    final theme = context.theme;
    final style = theme.typography.body.sm.copyWith(
      color: theme.colors.errorForeground,
    );
    return Column(
      children: [
        ColoredBox(
          color: theme.colors.error,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(FLucideIcons.unplug, size: 18, color: style.color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(status.problem ?? '与桌面断开，正在重连', style: style),
                  ),
                  FButton(
                    variant: FButtonVariant.outline,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => switchLibrary(
                      navigator.currentContext ?? context,
                      ref,
                      null,
                    ),
                    child: const Text('切回本机'),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}

class PairedDesktopsScreen extends ConsumerWidget {
  const PairedDesktopsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paired = ref.watch(pairedDesktopsProvider);
    return PageScaffold(
      title: '已配对的桌面',
      body: AsyncView(
        value: paired,
        builder: (List<ConnectLink> all) => ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (all.isEmpty) const Text('还没有配对的桌面。'),
            if (all.isNotEmpty)
              FTileGroup(
                children: [
                  for (final link in all)
                    FTile(
                      prefix: const Icon(FLucideIcons.monitor),
                      title: Text(link.name),
                      subtitle: Text('${link.host}:${link.port}'),
                      suffix: IconAction(
                        icon: FLucideIcons.trash2,
                        tooltip: '删除配对',
                        onPress: () async {
                          await PairedDesktops(
                            ref.read(servicesProvider).secrets,
                          ).remove(link.fingerprint);
                          ref.invalidate(pairedDesktopsProvider);
                        },
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
