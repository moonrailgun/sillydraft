import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'remote_support.dart';

final class _User implements QueryExecutorUser {
  @override
  int get schemaVersion => 9;
  @override
  Future<void> beforeOpen(
    QueryExecutor executor,
    OpeningDetails details,
  ) async {}
}

const _wait = Duration(seconds: 5);

void main() {
  late Desktop desktop;
  setUp(() async => desktop = await Desktop.start());
  tearDown(() => desktop.close());

  test('a phone reads the desktop library; both hear each other', () async {
    await desktop.repository.setSetting('from-desktop', {'v': 1});
    final phone = await desktop.phone();
    addTearDown(phone.close);
    expect(phone.hello.name, '测试桌面');
    expect(phone.hello.resourceKey, List.filled(32, 7));
    expect(await phone.repository.getSetting('from-desktop'), {'v': 1});

    final heardOnPhone = phone.repository.contentChanges.first;
    await desktop.repository.setSetting('later', {'v': 2});
    await heardOnPhone.timeout(_wait);

    final heardOnDesktop = desktop.repository.contentChanges.first;
    await phone.repository.setSetting('from-phone', {'v': 3});
    await heardOnDesktop.timeout(_wait);
    expect(await desktop.repository.getSetting('from-phone'), {'v': 3});
  });

  test('a second phone hears the first one\'s writes', () async {
    final first = await desktop.phone(), second = await desktop.phone();
    addTearDown(first.close);
    addTearDown(second.close);
    final heard = second.repository.contentChanges.first;
    await first.repository.setSetting('shared', {'v': 1});
    await heard.timeout(_wait);
  });

  test('a wrong key is refused; ten guesses lock the address out', () async {
    final wrong = ConnectLink(
      host: '127.0.0.1',
      port: desktop.host!.port,
      key: randomSecret(),
      fingerprint: testIdentity.fingerprint,
      name: 'x',
    );
    for (var i = 0; i < 10; i++) {
      await expectLater(
        RemoteSession.connect(wrong, appVersion: testVersion),
        throwsA(
          isA<RemoteRequestFailed>().having((e) => e.status, 'status', 401),
        ),
      );
    }
    await expectLater(
      desktop.phone(),
      throwsA(
        isA<RemoteRequestFailed>().having((e) => e.status, 'status', 429),
      ),
    );
  });

  test('a certificate other than the link\'s is refused', () async {
    final link = desktop.link;
    final forged = ConnectLink(
      host: link.host,
      port: link.port,
      key: link.key,
      fingerprint: 'a' * 64,
      name: link.name,
    );
    await expectLater(
      RemoteSession.connect(forged, appVersion: testVersion),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('different versions refuse to connect and say which', () async {
    await expectLater(
      desktop.phone(appVersion: '1.0.0+2'),
      throwsA(
        isA<RemoteVersionMismatch>().having(
          (e) => '$e',
          'message',
          '桌面 1.0.0+1，手机 1.0.0+2，请升级到同一版本',
        ),
      ),
    );
  });

  test('a dropped link is retried under the same repository', () async {
    final phone = await desktop.phone();
    addTearDown(phone.close);
    final repository = phone.repository;
    final lost = phone.statuses.firstWhere((s) => !s.connected);
    await desktop.stopHost();
    expect((await lost.timeout(_wait)).problem, '桌面已停止共享');
    await expectLater(
      repository.getSetting('x'),
      throwsA(isA<RemoteUnavailable>()),
    );
    await desktop.repository.setSetting('while-away', {'v': 1});
    final refreshed = repository.contentChanges.first;
    await desktop.startHost();
    await phone.statuses.firstWhere((s) => s.connected).timeout(_wait);
    await refreshed.timeout(_wait);
    expect(identical(phone.repository, repository), isTrue);
    expect(await repository.getSetting('while-away'), {'v': 1});
  });

  test(
    'a desktop upgraded mid-session stops the retries and says why',
    () async {
      final phone = await desktop.phone();
      addTearDown(phone.close);
      await desktop.stopHost();
      await desktop.startHost(appVersion: '1.0.1+2');
      final status = await phone.statuses
          .firstWhere((s) => s.problem?.contains('1.0.1+2') ?? false)
          .timeout(_wait);
      expect(status.connected, isFalse);
      expect(status.problem, contains(testVersion));
      // A loop still retrying would report the mismatch again.
      await expectLater(
        phone.statuses.skip(1).first.timeout(const Duration(milliseconds: 500)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );

  for (final (change, problem) in [
    ('a new key', '访问密钥无效，请重新扫码配对'),
    ('a new certificate', '桌面证书已更换，请重新扫码配对'),
  ]) {
    test('a desktop with $change stops the retries and says why', () async {
      final phone = await desktop.phone();
      addTearDown(phone.close);
      await desktop.stopHost();
      await desktop.startHost(
        accessKey: change == 'a new key' ? randomSecret() : null,
        identity: change == 'a new certificate' ? TlsIdentity.generate() : null,
      );
      final status = await phone.statuses
          .firstWhere((s) => s.problem == problem)
          .timeout(_wait);
      expect(status.connected, isFalse);
      await expectLater(
        phone.statuses.skip(1).first.timeout(const Duration(milliseconds: 500)),
        throwsA(isA<TimeoutException>()),
      );
    });
  }

  test('a phone gone mid-transaction leaves the desktop writable', () async {
    final phone = await desktop.phone();
    await phone.repository.getSetting('open');
    final tx = phone.executor.beginTransaction();
    await tx.ensureOpen(_User());
    await tx.runSelect('SELECT 1', []);
    await phone.close();
    await desktop.repository.setSetting('after', {'ok': true}).timeout(_wait);
  });

  test('a phone closed mid-reconnect hangs up the new link', () async {
    final phone = await desktop.phone();
    // Opened once, so a reconnect's `attach` waits on the desktop.
    await phone.repository.getSetting('open');
    final port = desktop.host!.port;
    await desktop.stopHost();
    // A desktop that stalls the phone's reconnect inside `_open` until the
    // phone has closed.
    final fake = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      port,
      testIdentity.serverContext,
    );
    addTearDown(() => fake.close(force: true));
    final db = Completer<WebSocket>(), events = Completer<WebSocket>();
    fake.listen((request) async {
      if (request.uri.path == '/v1/hello') {
        request.response.write(
          jsonEncode({
            'name': '测试桌面',
            'appVersion': testVersion,
            'resourceKey': base64Encode(List.filled(32, 7)),
          }),
        );
        await request.response.close();
      } else {
        final socket = await WebSocketTransformer.upgrade(request);
        (request.uri.path == '/v1/db' ? db : events).complete(socket);
      }
    });
    final dbSocket = await db.future.timeout(_wait);
    final eventsSocket = await events.future.timeout(_wait);
    // drift's server speaks first; the phone answers only with both its
    // sockets open, then waits in `attach` on answers held back here.
    final channel = driftChannel(dbSocket);
    final toPhone = StreamController<Object?>();
    final asked = Completer<void>(), release = Completer<void>();
    var answers = 0;
    unawaited(
      toPhone.stream
          .asyncMap((message) async {
            if (answers++ > 0) await release.future;
            return message;
          })
          .pipe(channel.sink),
    );
    final server = desktop.repository.remoteServer();
    addTearDown(server.shutdown);
    addTearDown(() => Future.wait([dbSocket.close(), eventsSocket.close()]));
    final served = server.serve(
      channel
          .changeStream(
            (stream) => stream.map((message) {
              if (!asked.isCompleted) asked.complete();
              return message;
            }),
          )
          .changeSink((_) => toPhone.sink),
    );
    await asked.future.timeout(_wait);
    await phone.close();
    release.complete();
    // Both links end: the phone hung up rather than keeping them.
    await Future.wait([served, eventsSocket.drain<void>()]).timeout(_wait);
  });
}
