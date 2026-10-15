import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// A `sillydraft://` link from a QR code or a paste.
sealed class SillyDraftLink {
  const SillyDraftLink();

  static SillyDraftLink parse(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != 'sillydraft') {
      throw const FormatException('不是 SillyDraft 链接');
    }
    return switch (uri.host) {
      'connect' => ConnectLink._parse(uri.queryParameters),
      'receive' => ReceiveLink._parse(uri.queryParameters),
      _ => throw const FormatException('不是 SillyDraft 链接'),
    };
  }

  Uri get uri;
  @override
  String toString() => uri.toString();
}

/// Pairs a phone with a desktop's library: where it is, the access key and
/// the certificate it serves.
final class ConnectLink extends SillyDraftLink {
  const ConnectLink({
    required this.host,
    required this.port,
    required this.key,
    required this.fingerprint,
    required this.name,
  });
  factory ConnectLink._parse(Map<String, String> q) => ConnectLink(
    host: _host(q),
    port: _port(q),
    key: _secret(q, 'key'),
    fingerprint: _fingerprint(q),
    name: (q['name'] ?? '').trim().isEmpty ? '桌面' : q['name']!.trim(),
  );
  final String host, key, fingerprint, name;
  final int port;

  @override
  Uri get uri => Uri(
    scheme: 'sillydraft',
    host: 'connect',
    queryParameters: {
      'host': host,
      'port': '$port',
      'key': key,
      'fp': fingerprint,
      'name': name,
    },
  );

  Uri endpoint(String path) =>
      Uri(scheme: 'https', host: host, port: port, path: path);
}

/// Fetches one shared item, once, from the device showing the code.
final class ReceiveLink extends SillyDraftLink {
  const ReceiveLink({
    required this.host,
    required this.port,
    required this.token,
    required this.fingerprint,
  });
  factory ReceiveLink._parse(Map<String, String> q) => ReceiveLink(
    host: _host(q),
    port: _port(q),
    token: _secret(q, 't'),
    fingerprint: _fingerprint(q),
  );
  final String host, token, fingerprint;
  final int port;

  @override
  Uri get uri => Uri(
    scheme: 'sillydraft',
    host: 'receive',
    queryParameters: {
      'host': host,
      'port': '$port',
      't': token,
      'fp': fingerprint,
    },
  );

  Uri get endpoint =>
      Uri(scheme: 'https', host: host, port: port, path: '/v1/share/$token');
}

String _host(Map<String, String> q) {
  final host = q['host'] ?? '';
  if (InternetAddress.tryParse(host) == null &&
      !RegExp(r'^[A-Za-z0-9.-]{1,253}$').hasMatch(host)) {
    throw const FormatException('链接中的地址无效');
  }
  return host;
}

int _port(Map<String, String> q) {
  final port = int.tryParse(q['port'] ?? '');
  if (port == null || port < 1 || port > 65535) {
    throw const FormatException('链接中的端口无效');
  }
  return port;
}

String _secret(Map<String, String> q, String name) {
  final value = q[name] ?? '';
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    throw const FormatException('链接中的密钥无效');
  }
  return value;
}

String _fingerprint(Map<String, String> q) {
  final value = q['fp'] ?? '';
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('链接中的证书指纹无效');
  }
  return value;
}

/// 32 random bytes as unpadded base64url: access keys and share tokens.
String randomSecret() {
  final random = Random.secure();
  return base64Url
      .encode(List.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// This device's IPv4 addresses another device might reach: private LAN
/// ranges first, then Tailscale-style `100.x`, then the rest.
Future<List<String>> reachableAddresses() async {
  final all = [
    for (final face in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      for (final address in face.addresses)
        if (!address.isLoopback) address.address,
  ];
  int rank(String a) =>
      a.startsWith('192.168.') ||
          a.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a)
      ? 0
      : a.startsWith('100.')
      ? 1
      : 2;
  return all..sort((a, b) => rank(a).compareTo(rank(b)));
}
