import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/library_host.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';
import 'library_switcher.dart';
import 'scan_screen.dart';

/// What a share page shows: one link per reachable address.
typedef ShareOffer = ({
  List<ReceiveLink> links,
  Future<void> received,
  void Function() close,
});

/// Opens a share page for what [build] produces.
Future<void> shareByQr(
  BuildContext context,
  Future<SharePayload> Function() build, {
  bool containsKey = false,
}) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => ShareScreen(build: build, containsKey: containsKey),
  ),
);

/// Opens what a scanned or pasted link points to: a desktop to pair with,
/// or a share to receive.
Future<void> openLink(BuildContext context, WidgetRef ref, String text) async {
  try {
    switch (SillyDraftLink.parse(text)) {
      case final ConnectLink link:
        if (!isPhone) {
          throw const FormatException('这是桌面的配对链接，请在手机上扫码或粘贴');
        }
        if (context.mounted) await switchLibrary(context, ref, link);
      case final ReceiveLink link:
        if (context.mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(builder: (_) => ReceiveScreen(link: link)),
          );
        }
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> scanLink(BuildContext context, WidgetRef ref) async {
  final text = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const ScanScreen()),
  );
  if (text != null && context.mounted) await openLink(context, ref, text);
}

Future<void> pasteLink(BuildContext context, WidgetRef ref) async {
  final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return;
  final text = await askText(
    context,
    title: '粘贴链接',
    label: '配对或分享链接',
    initial: clipboard?.text?.startsWith('sillydraft://') == true
        ? clipboard!.text!
        : '',
  );
  if (text != null && context.mounted) await openLink(context, ref, text);
}

class ShareScreen extends ConsumerStatefulWidget {
  const ShareScreen({
    super.key,
    required this.build,
    this.containsKey = false,
    this.offer,
  });
  final Future<SharePayload> Function() build;

  /// The payload carries an API key: the page warns about screenshots.
  final bool containsKey;

  /// Hands the payload out; the app's [LibraryHosting] unless a test passes
  /// its own.
  final Future<ShareOffer> Function(SharePayload)? offer;

  @override
  ConsumerState<ShareScreen> createState() => _ShareState();
}

class _ShareState extends ConsumerState<ShareScreen> {
  late final AppServices _services = ref.read(servicesProvider);
  ShareOffer? _offer;
  int _selected = 0;
  bool _received = false, _expired = false;
  Object? _error;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<ShareOffer> _hostOffer(SharePayload payload) async {
    final hosting = _services.hosting;
    final offered = await hosting.offer(payload);
    final addresses = await reachableAddresses();
    return (
      links: [
        for (final address in addresses)
          ReceiveLink(
            host: address,
            port: offered.port,
            token: offered.ticket.token,
            fingerprint: offered.fingerprint,
          ),
      ],
      received: offered.ticket.received,
      close: () {
        offered.ticket.close();
        unawaited(hosting.releaseShares());
      },
    );
  }

  Future<void> _open() async {
    try {
      final payload = await widget.build();
      final offer = await (widget.offer ?? _hostOffer)(payload);
      if (!mounted) {
        offer.close();
        return;
      }
      setState(() => _offer = offer);
      unawaited(
        offer.received.then((_) {
          if (mounted) setState(() => _received = true);
        }),
      );
      _expiry = Timer(const Duration(minutes: 10), () {
        if (mounted) setState(() => _expired = true);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _offer?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final offer = _offer;
    return PageScaffold(
      title: '扫码分享',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // First, so the author reads it before the code is on screen.
          if (widget.containsKey) ...[
            Text(
              '二维码含 API Key：看到或截到它的人都能用这把密钥。',
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.error,
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (_error != null)
            Text('无法分享：$_error')
          else if (offer == null)
            const Center(child: FCircularProgress())
          else if (offer.links.isEmpty)
            const Text('没有找到可用的网络地址：请连接 Wi‑Fi 或局域网。')
          else ...[
            if (offer.links.length > 1)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, link) in offer.links.indexed)
                    ChoicePill(
                      label: link.host,
                      selected: i == _selected,
                      onPress: () => setState(() => _selected = i),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFFFFFFFF),
                child: QrImageView(
                  data: '${offer.links[_selected]}',
                  size: 240,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                _received
                    ? '已被接收'
                    : _expired
                    ? '已过期，请重新打开分享'
                    : '等待另一台设备扫码',
                style: theme.typography.body.md.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SelectableText('${offer.links[_selected]}', style: muted),
            const SizedBox(height: 8),
            FButton(
              variant: FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              prefix: const Icon(FLucideIcons.copy),
              onPress: () async {
                await Clipboard.setData(
                  ClipboardData(text: '${offer.links[_selected]}'),
                );
                if (context.mounted) toast(context, '已复制分享链接');
              },
              child: const Text('复制链接'),
            ),
          ],
          const SizedBox(height: 24),
          Text('另一台设备需在同一网络。分享在本页打开期间有效，最长 10 分钟，被接收一次后失效。', style: muted),
        ],
      ),
    );
  }
}

class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, required this.link, this.fetch});
  final ReceiveLink link;
  final Future<SharePayload> Function(ReceiveLink)? fetch;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveState();
}

class _ReceiveState extends ConsumerState<ReceiveScreen> {
  SharePayload? _payload;
  Object? _error;
  bool _busy = false;

  static const _kinds = {
    ShareKind.resource: '资源',
    ShareKind.skill: '助手技能',
    ShareKind.persona: '人设',
    ShareKind.connection: '模型连接',
  };

  @override
  void initState() {
    super.initState();
    unawaited(
      (widget.fetch ?? fetchShare)(widget.link).then(
        (payload) {
          if (mounted) setState(() => _payload = payload);
        },
        onError: (Object e) {
          if (mounted) setState(() => _error = e);
        },
      ),
    );
  }

  Future<void> _accept(SharePayload payload) async {
    final services = ref.read(servicesProvider);
    setState(() => _busy = true);
    try {
      switch (payload.kind) {
        case ShareKind.resource:
          await receiveResource(services.library, payload);
        case ShareKind.skill:
          final skill = receivedSkill(payload);
          final mine = await services.skills.installed();
          if (mine.any((s) => s.name == skill.name) &&
              !(mounted &&
                  await confirmAction(
                    context,
                    title: '覆盖同名技能？',
                    message: '已有名为 ${skill.name} 的技能。',
                    confirmLabel: '覆盖',
                  ))) {
            return;
          }
          await services.skills.install([skill]);
        case ShareKind.persona:
          await receivePersona(
            services.repository,
            services.assets ?? (throw StateError('本地资源目录尚未就绪')),
            payload,
          );
        case ShareKind.connection:
          if (services.remote != null) {
            throw StateError('连接在桌面管理，请切回本机后再接收');
          }
          final taken = {for (final c in await services.connections()) c.id};
          final received = receivedConnection(payload, taken);
          if (received.connection.protocol.isLocalCli && !localCliAvailable) {
            throw const FormatException('本地订阅连接只能在桌面端使用');
          }
          await services.saveConnection(
            received.connection,
            apiKey: received.apiKey,
          );
      }
      if (mounted) {
        toast(context, '已接收「${payload.name}」');
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Where a shared connection's key would be sent.
  static String? _address(SharePayload payload) {
    if (payload.kind != ShareKind.connection) return null;
    try {
      final connection = receivedConnection(payload, const {}).connection;
      return connection.protocol.isLocalCli ? '本地订阅' : connection.baseUrl;
    } catch (_) {
      // Accepting reports what is wrong with it.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = _payload;
    return PageScaffold(
      title: '接收分享',
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (_error != null)
            Text('$_error')
          else if (payload == null)
            const Center(child: FCircularProgress())
          else ...[
            FTileGroup(
              children: [
                FTile(
                  title: Text(payload.name),
                  subtitle: Text(
                    [
                      [
                        _kinds[payload.kind]!,
                        if (payload.kind == ShareKind.connection) '含 API Key',
                      ].join(' · '),
                      ?_address(payload),
                    ].join('\n'),
                    overflow: TextOverflow.visible,
                    softWrap: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FButton(
              onPress: _busy ? null : () => _accept(payload),
              child: const Text('接收'),
            ),
          ],
        ],
      ),
    );
  }
}
