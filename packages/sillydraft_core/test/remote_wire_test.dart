import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
// drift's remote protocol is experimental; both ends ship the same build.
// ignore: experimental_member_use
import 'package:drift/remote.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('drift messages survive JSON, bytes included', () {
    final message = [
      1,
      'a',
      Uint8List.fromList([0, 255]),
      [true, null, 2.5, Uint8List(0)],
    ];
    final back = decodeDriftMessage(
      jsonDecode(jsonEncode(encodeDriftMessage(message))),
    );
    expect(back, message);
    expect((back! as List)[2], isA<Uint8List>());
  });

  test('a repository works over a WebSocket, with large rows', () async {
    final dir = await Directory.systemTemp.createTemp('sd-wire');
    final desktop = StoryRepository.open('${dir.path}/library.sqlite');
    addTearDown(() async {
      await desktop.close();
      await dir.delete(recursive: true);
    });
    final big = 'x' * (5 * 1024 * 1024);
    await desktop.setSetting('big', {'text': big});
    final server = desktop.remoteServer();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.shutdown();
      await http.close(force: true);
    });
    http.listen(
      (request) async => server.serve(
        driftChannel(await WebSocketTransformer.upgrade(request)),
      ),
    );
    final socket = await WebSocket.connect('ws://127.0.0.1:${http.port}');
    final connection = await connectToRemoteAndInitialize(driftChannel(socket));
    final phone = StoryRepository.connect(connection.executor);
    expect((await phone.getSetting('big'))!['text'], big);
    await phone.setSetting('back', {'text': big});
    expect((await desktop.getSetting('back'))!['text'], big);
    final rows = await connection.executor.runSelect("SELECT x'00ff' AS b", []);
    expect(rows.single['b'], [0, 255]);
    await socket.close();
  });

  test(
    'a detached executor fails with the reason, then serves again',
    () async {
      final executor = ReconnectingExecutor();
      final repository = StoryRepository.connect(executor);
      addTearDown(repository.close);
      await expectLater(
        repository.getSetting('x'),
        throwsA(isA<RemoteUnavailable>()),
      );
      await executor.attach(NativeDatabase.memory());
      await repository.setSetting('x', {'v': 1});
      executor.detach('桌面已停止共享');
      await expectLater(
        repository.getSetting('x'),
        throwsA(
          isA<RemoteUnavailable>().having((e) => '$e', 'message', '桌面已停止共享'),
        ),
      );
      // A new connection is opened for the same database user (migrations
      // run here because this stand-in database is empty).
      await executor.attach(NativeDatabase.memory());
      expect(await repository.getSetting('x'), isNull);
    },
  );
}
