import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/remote/share_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

void main() {
  final link = ReceiveLink(
    host: '192.168.1.5',
    port: 51000,
    // Fixed, not randomSecret(): a '-' in a random token is a line-break
    // opportunity, so the link text sometimes wraps one line taller and
    // pushes the key warning out of the lazily built share list.
    token: 't' * 43,
    fingerprint: 'a' * 64,
  );
  Future<NavigatorState> app(WidgetTester tester, AppServices services) async {
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    return tester.state<NavigatorState>(find.byType(Navigator).first);
  }

  testWidgets('a share page shows its code until it is received', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final received = Completer<void>();
    var closed = false;
    final navigator = await app(tester, services);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ShareScreen(
            containsKey: true,
            build: () async => connectionShare(
              ModelConnection(
                id: 'w',
                name: '写手',
                baseUrl: 'https://a/v1',
                model: 'm',
              ),
              'sk-1',
            ),
            offer: (_) async => (
              links: [link],
              received: received.future,
              close: () => closed = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.textContaining('含 API Key'), findsOneWidget);
    received.complete();
    await tester.pumpAndSettle();
    expect(find.text('已被接收'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('receiving a connection previews it and saves the key', (
    tester,
  ) async {
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    final navigator = await app(tester, services);
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => ReceiveScreen(
            link: link,
            fetch: (_) async => connectionShare(
              ModelConnection(
                id: 'w',
                name: '写手',
                baseUrl: 'https://a/v1',
                model: 'm',
              ),
              'sk-1',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('写手'), findsOneWidget);
    expect(find.textContaining('含 API Key'), findsOneWidget);
    // Where the key will be sent.
    expect(find.textContaining('https://a/v1'), findsOneWidget);
    await tester.tap(find.text('接收'));
    await tester.pumpAndSettle();
    expect((await services.connections()).single.name, '写手');
    expect(await services.secrets.read('model/w'), 'sk-1');
  });
}
