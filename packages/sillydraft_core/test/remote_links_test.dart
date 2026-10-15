import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  final identity = TlsIdentity.generate();

  test('links survive a round trip, including a Chinese name', () {
    final link = ConnectLink(
      host: '192.168.1.5',
      port: 8790,
      key: randomSecret(),
      fingerprint: identity.fingerprint,
      name: '书房的 Mac',
    );
    final parsed = SillyDraftLink.parse('$link') as ConnectLink;
    expect(parsed.host, link.host);
    expect(parsed.port, 8790);
    expect(parsed.key, link.key);
    expect(parsed.fingerprint, link.fingerprint);
    expect(parsed.name, '书房的 Mac');
    final receive = ReceiveLink(
      host: '10.0.0.2',
      port: 51000,
      token: randomSecret(),
      fingerprint: identity.fingerprint,
    );
    final back = SillyDraftLink.parse(' ${receive.uri} ') as ReceiveLink;
    expect(back.token, receive.token);
    expect(back.endpoint.path, '/v1/share/${receive.token}');
  });

  test('an IPv6 host is bracketed in endpoints', () {
    final link = ConnectLink(
      host: 'fe80::1',
      port: 8790,
      key: randomSecret(),
      fingerprint: identity.fingerprint,
      name: 'x',
    );
    expect('${link.endpoint('/v1/hello')}', 'https://[fe80::1]:8790/v1/hello');
    expect((SillyDraftLink.parse('$link') as ConnectLink).host, 'fe80::1');
  });

  test('malformed links are refused', () {
    final good = ConnectLink(
      host: '192.168.1.5',
      port: 8790,
      key: randomSecret(),
      fingerprint: identity.fingerprint,
      name: 'x',
    ).uri;
    for (final bad in [
      'https://example.com',
      good.replace(scheme: 'http').toString(),
      good
          .replace(queryParameters: {...good.queryParameters, 'port': '0'})
          .toString(),
      good
          .replace(queryParameters: {...good.queryParameters, 'key': 'short'})
          .toString(),
      good
          .replace(queryParameters: {...good.queryParameters, 'fp': 'xyz'})
          .toString(),
    ]) {
      expect(
        () => SillyDraftLink.parse(bad),
        throwsFormatException,
        reason: bad,
      );
    }
  });

  test('secrets are 43 url-safe characters and never repeat', () {
    final a = randomSecret(), b = randomSecret();
    expect(a, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    expect(a, isNot(b));
  });

  test('an identity keeps its fingerprint through JSON', () {
    final copy = TlsIdentity.fromJson(
      jsonDecode(jsonEncode(identity.toJson())) as Map<String, dynamic>,
    );
    expect(copy.fingerprint, identity.fingerprint);
    expect(identity.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
  });

  test('a pinned client reaches only the identity it was given', () async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.serverContext,
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.write('ok');
      request.response.close();
    });
    Future<String> get(String fingerprint) async {
      final client = pinnedClient(fingerprint);
      try {
        final request = await client.getUrl(
          Uri.parse('https://127.0.0.1:${server.port}/'),
        );
        return await utf8.decodeStream(await request.close());
      } finally {
        client.close(force: true);
      }
    }

    expect(await get(identity.fingerprint), 'ok');
    await expectLater(get('0' * 64), throwsA(isA<HandshakeException>()));
  });
}
