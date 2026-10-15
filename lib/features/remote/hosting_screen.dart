import 'dart:async';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/hosting.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';

/// 设置 → 手机连接: share this desktop's library with phones by QR code.
class HostingScreen extends ConsumerStatefulWidget {
  const HostingScreen({super.key, this.addresses = reachableAddresses});

  /// This desktop's reachable addresses; tests pass a fixed list.
  final Future<List<String>> Function() addresses;

  @override
  ConsumerState<HostingScreen> createState() => _HostingState();
}

class _HostingState extends ConsumerState<HostingScreen> {
  late final LibraryHosting _hosting = ref.read(servicesProvider).hosting;
  List<String> _addresses = const [];
  String? _address;
  ConnectLink? _link;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _hosting.addListener(_changed);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _hosting.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_refresh());

  /// Counts refreshes: notifications overlap, only the latest may show.
  int _generation = 0;

  Future<void> _refresh() async {
    final generation = ++_generation;
    final addresses = await widget.addresses();
    final address = addresses.contains(_address)
        ? _address
        : addresses.firstOrNull;
    ConnectLink? link;
    if (_hosting.host != null && address != null) {
      try {
        link = await _hosting.link(address);
      } catch (_) {
        // Sharing stopped meanwhile: no link to show.
      }
    }
    if (mounted && generation == _generation) {
      setState(() {
        _addresses = addresses;
        _address = address;
        _link = link;
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePort() async {
    final text = await askText(
      context,
      title: '更改端口',
      initial: '${_hosting.host?.port ?? defaultRemotePort}',
      label: '端口（1024–65535）',
    );
    final port = int.tryParse(text ?? '');
    if (text == null) return;
    if (port == null || port < 1024 || port > 65535) {
      if (mounted) showError(context, '端口须为 1024 到 65535 之间的数字');
      return;
    }
    await _run(() => _hosting.setEnabled(true, port: port));
  }

  Future<void> _regenerate() async {
    if (!await confirmAction(
      context,
      title: '重新生成密钥？',
      message: '已配对的手机需要重新扫码才能连接。',
      confirmLabel: '重新生成',
      destructive: true,
    )) {
      return;
    }
    await _run(_hosting.regenerateKey);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final host = _hosting.host, link = _link, error = _hosting.error;
    return PageScaffold(
      title: '手机连接',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('打开后，手机扫码即可直接使用这台电脑的作品库、资料和模型。生成任务在这台电脑上执行，手机锁屏也不中断。'),
          const SizedBox(height: 16),
          FTileGroup(
            children: [
              FTile(
                key: const Key('hosting-switch'),
                prefix: const Icon(FLucideIcons.smartphone),
                title: const Text('允许手机连接'),
                subtitle: Text(host == null ? '未开启' : '端口 ${host.port}'),
                suffix: FSwitch(
                  value: host != null,
                  onChange: _busy
                      ? null
                      : (value) => _run(() => _hosting.setEnabled(value)),
                ),
                onPress: _busy
                    ? null
                    : () => _run(() => _hosting.setEnabled(host == null)),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              '无法开启：$error',
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.error,
              ),
            ),
          ],
          if (host != null && _addresses.isEmpty) ...[
            const SizedBox(height: 16),
            const Text('没有找到可用的网络地址：请连接 Wi‑Fi 或局域网。'),
          ],
          if (link != null) ...[
            const SizedBox(height: 24),
            if (_addresses.length > 1)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final address in _addresses)
                    ChoicePill(
                      label: address,
                      selected: address == _address,
                      onPress: () {
                        _address = address;
                        unawaited(_refresh());
                      },
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFFFFFFFF),
                child: QrImageView(data: '$link', size: 240),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText('$link', style: muted),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  prefix: const Icon(FLucideIcons.copy),
                  onPress: () async {
                    await Clipboard.setData(ClipboardData(text: '$link'));
                    if (context.mounted) toast(context, '已复制连接链接');
                  },
                  child: const Text('复制连接链接'),
                ),
                FButton(
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _changePort,
                  child: const Text('更改端口'),
                ),
                FButton(
                  variant: FButtonVariant.destructive,
                  mainAxisSize: MainAxisSize.min,
                  onPress: _busy ? null : _regenerate,
                  child: const Text('重新生成密钥'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text(
            '持有连接链接即可读写这台电脑上的全部作品，并能用这里的模型发起付费调用。只在自己的设备间扫码，不要截图外传。',
            style: muted,
          ),
          const SizedBox(height: 8),
          Text(
            '手机需要和电脑在同一局域网，或都加入 Tailscale 等互通的网络。两边须为同一版本的 SillyDraft。',
            style: muted,
          ),
        ],
      ),
    );
  }
}
