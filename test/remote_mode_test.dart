import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' hide ImageProvider;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sillydraft/app/app.dart';
import 'package:sillydraft/app/library_host.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/illustrations/asset_image.dart';
import 'package:sillydraft/features/remote/library_switcher.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import 'support/host.dart';

final _phone = TargetPlatformVariant.only(TargetPlatform.iOS);

/// Lets real socket traffic arrive, then builds, until [finder] shows.
Future<void> _settle(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  ConnectLink link({String name = '书房'}) => ConnectLink(
    host: '192.168.1.5',
    port: 8790,
    key: randomSecret(),
    fingerprint: 'b' * 64,
    name: name,
  );

  test('re-pairing a desktop replaces its entry', () async {
    final paired = PairedDesktops(MemorySecrets());
    await paired.save(link(name: '旧名'));
    final fresh = link();
    await paired.save(fresh);
    final all = await paired.list();
    expect(all, hasLength(1));
    expect(all.single.key, fresh.key);
    expect(all.single.name, '书房');
  });

  test('a corrupt paired entry is skipped', () async {
    final secrets = MemorySecrets();
    final good = link();
    await secrets.write(
      'remote/paired',
      jsonEncode(['sillydraft://connect?host=x', 7, '$good']),
    );
    expect((await PairedDesktops(secrets).list()).single.key, good.key);
  });

  test('a paired value that is not a list reads as none', () async {
    final secrets = MemorySecrets();
    for (final saved in ['{"a": 1}', '"x"', 'not json']) {
      await secrets.write('remote/paired', saved);
      expect(await PairedDesktops(secrets).list(), isEmpty);
    }
    await PairedDesktops(secrets).save(link());
    expect(await PairedDesktops(secrets).list(), hasLength(1));
  });

  testWidgets('a picture that failed to load is tried again on reconnect', (
    tester,
  ) async {
    final (:file, :bytes, :link, :shown) = await _picture(
      tester,
      missing: true,
    );
    await _settle(tester, find.text('图片暂不可用'));
    expect(find.text('图片暂不可用'), findsOneWidget);
    link.add((connected: false, problem: null));
    await _settle(tester, shown);
    expect(shown, findsNothing);
    await tester.runAsync(() => file.writeAsBytes(bytes));
    link.add((connected: true, problem: null));
    await _settle(tester, shown);
    expect(shown, findsOneWidget);
  });

  testWidgets('a shown picture stays while the link is down', (tester) async {
    final (:file, bytes: _, :link, :shown) = await _picture(
      tester,
      missing: false,
    );
    await _settle(tester, shown);
    expect(shown, findsOneWidget);
    // Its re-read fails, as a download would during the outage.
    await tester.runAsync(file.delete);
    link.add((connected: false, problem: null));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(shown, findsOneWidget);
  });

  testWidgets('a tablet keeps the library switcher when wide', (tester) async {
    tester.view.physicalSize = const Size(1366, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
    );
    addTearDown(services.close);
    await tester.pumpWidget(SillyDraftApp(services: services));
    await tester.pumpAndSettle();
    expect(find.byType(LibrarySwitcher), findsOneWidget);
  }, variant: _phone);

  testWidgets(
    'a phone lists paired desktops and warns before interrupting tasks',
    (tester) async {
      final repository = StoryRepository.memory();
      final novel = await repository.createNovel(title: '本机作品');
      await repository.createTask(
        branchId: novel.activeBranchId,
        kind: TaskKind.writing,
        input: const {},
      );
      final services = AppServices(
        repository: repository,
        secrets: MemorySecrets(),
      );
      addTearDown(services.close);
      await PairedDesktops(services.secrets).save(link());
      await tester.pumpWidget(SillyDraftApp(services: services));
      // The active-task spinner keeps animating while the dialogs open.
      Future<void> pumpActivity() async {
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await pumpActivity();
      await tester.tap(find.text('SillyDraft'));
      await pumpActivity();
      await tester.tap(find.textContaining('书房'));
      await pumpActivity();
      expect(find.textContaining('切换会中断 1 个本机任务'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await pumpActivity();
      expect(find.text('本机作品'), findsOneWidget);
    },
    variant: _phone,
  );

  testWidgets(
    'a remote library shows its desktop and keeps connections read-only',
    (tester) async {
      final (services, _) = await _desktopLibrary(tester);
      await tester.pumpWidget(SillyDraftApp(services: services));
      await _settle(tester, find.text('桌面作品'));
      expect(find.text('桌面：书房'), findsOneWidget);
      expect(find.text('桌面作品'), findsOneWidget);

      await _openSettings(tester);
      expect(find.byKey(const Key('settings-remote')), findsOneWidget);
      expect(find.text('添加连接'), findsNothing);
    },
    variant: _phone,
  );

  testWidgets(
    'leaving an unreachable desktop asks before dropping unsaved work',
    (tester) async {
      final (services, _) = await _desktopLibrary(tester);
      // What a reader's progress or an open editor does while the desktop
      // cannot be reached.
      final draft = Object();
      services.registerDraft(
        draft,
        () async => throw const RemoteUnavailable(),
      );
      addTearDown(() => services.unregisterDraft(draft));
      final repository = StoryRepository.memory();
      await repository.createNovel(title: '本机作品');
      final local = AppServices(
        repository: repository,
        secrets: services.secrets,
      );
      addTearDown(local.close);
      await tester.pumpWidget(
        SillyDraftApp(services: services, openLocal: () async => local),
      );
      await _settle(tester, find.text('桌面作品'));
      await _openSettings(tester);

      await tester.tap(find.text('切回本机'));
      await tester.pump(const Duration(milliseconds: 200));
      await _settle(tester, find.text('桌面已断开'));
      expect(find.textContaining('无法写回桌面'), findsOneWidget);
      // Shuts the link's sockets in real time, so the switch below closes
      // nothing under fake time.
      await tester.runAsync(services.remote!.close);
      await tester.tap(find.text('放弃并切换'));
      await tester.pump(const Duration(milliseconds: 200));
      await _settle(tester, find.text('本机作品'));
      expect(find.text('本机作品'), findsOneWidget);
      expect(find.text('SillyDraft'), findsOneWidget);
    },
    variant: _phone,
  );

  testWidgets('the disconnect bar leads back to this device', (tester) async {
    final (services, host) = await _desktopLibrary(tester);
    final draft = Object();
    services.registerDraft(draft, () async => throw const RemoteUnavailable());
    addTearDown(() => services.unregisterDraft(draft));
    final local = AppServices(
      repository: StoryRepository.memory(),
      secrets: services.secrets,
    );
    addTearDown(local.close);
    await tester.pumpWidget(
      SillyDraftApp(services: services, openLocal: () async => local),
    );
    await _settle(tester, find.text('桌面作品'));
    await tester.runAsync(host.close);
    await _settle(tester, find.text('桌面已停止共享'));

    // The bar sits above the app's navigator; its question opens there.
    await tester.tap(find.text('切回本机'));
    await tester.pump(const Duration(milliseconds: 200));
    await _settle(tester, find.text('桌面已断开'));
    expect(find.text('桌面已断开'), findsOneWidget);
    await tester.runAsync(services.remote!.close);
    await tester.tap(find.text('放弃并切换'));
    await tester.pump(const Duration(milliseconds: 200));
    await _settle(tester, find.text('SillyDraft'));
    expect(find.text('SillyDraft'), findsOneWidget);
    expect(find.text('桌面已停止共享'), findsNothing);
  }, variant: _phone);
}

/// An [AssetImageView] of a picture this device's library holds, under a
/// link status the test drives. With [missing] its file starts deleted, as
/// a download that failed while the link was down.
Future<
  ({
    File file,
    List<int> bytes,
    StreamController<RemoteStatus> link,
    Finder shown,
  })
>
_picture(WidgetTester tester, {required bool missing}) async {
  late AppServices services;
  late Directory dir;
  late StoryAsset asset;
  late File file;
  late List<int> bytes;
  await tester.runAsync(() async {
    dir = await Directory.systemTemp.createTemp('sd-picture');
    services = AppServices(
      repository: StoryRepository.memory(),
      secrets: MemorySecrets(),
      dataDirectory: dir,
    );
    final novel = await services.repository.createNovel(title: '插图');
    asset = await services.assets!.importImage(
      branchId: novel.activeBranchId,
      name: '图',
      bytes: img.encodePng(img.Image(width: 4, height: 4)),
    );
    file = services.assets!.hashFile(asset.hash);
    bytes = await file.readAsBytes();
    if (missing) await file.delete();
  });
  addTearDown(
    () => tester.runAsync(() async {
      await services.close();
      await dir.delete(recursive: true);
    }),
  );
  final link = StreamController<RemoteStatus>();
  // Not awaited: done only once the scope stops listening.
  addTearDown(() => unawaited(link.close()));
  await tester.pumpWidget(
    ProviderScope(
      // Only a change of link may try again.
      retry: (_, _) => null,
      overrides: [
        servicesProvider.overrideWithValue(services),
        remoteStatusProvider.overrideWith((ref) => link.stream),
      ],
      child: testHost(AssetImageView(assetId: asset.id)),
    ),
  );
  return (
    file: file,
    bytes: bytes,
    link: link,
    // Only the provider's error replaces the picture's Image.
    shown: find.descendant(
      of: find.byType(AssetImageView),
      matching: find.byType(Image),
    ),
  );
}

/// A paired desktop named 书房 holding 桌面作品, and this phone's view of
/// its library, over real loopback sockets; every bit of their I/O runs in
/// [WidgetTester.runAsync].
Future<(AppServices, RemoteHost)> _desktopLibrary(WidgetTester tester) async {
  late StoryRepository desktop;
  late RemoteHost host;
  late AppServices services;
  late Directory cache;
  // Real loopback traffic; the test binding's own HttpClient answers 400.
  final previous = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() => HttpOverrides.global = previous);
  await tester.runAsync(() async {
    final identity = TlsIdentity.generate();
    desktop = StoryRepository.memory();
    await desktop.createNovel(title: '桌面作品');
    cache = await Directory.systemTemp.createTemp('sd-remote-ui');
    final key = randomSecret();
    Future<ModelProvider> noText(ModelConnection _) async =>
        throw StateError('no model in this test');
    Future<ImageProvider> noImage(ModelConnection _) async =>
        throw StateError('no model in this test');
    host = await RemoteHost.start(
      identity: identity,
      name: '书房',
      appVersion: '1.0.0+1',
      address: InternetAddress.loopbackIPv4,
      port: 0,
      library: LibraryAccess(
        accessKey: key,
        repository: desktop,
        tasks: TaskRunner(repository: desktop, providerFactory: noText),
        assets: AssetLibrary(
          repository: desktop,
          directory: Directory('${cache.path}/desktop'),
        ),
        resourceKey: () async => List.filled(32, 1),
        connections: () async => [],
        providerFactory: noText,
        imageProviderFactory: noImage,
      ),
    );
    final session = await RemoteSession.connect(
      ConnectLink(
        host: '127.0.0.1',
        port: host.port,
        key: key,
        fingerprint: identity.fingerprint,
        name: '书房',
      ),
      appVersion: '1.0.0+1',
    );
    services = AppServices.remote(
      session,
      secrets: MemorySecrets(),
      cache: Directory('${cache.path}/phone'),
    );
  });
  addTearDown(
    () => tester.runAsync(() async {
      // A phone's library holds nothing but its link: no sharing host, and
      // its tasks run on the desktop. Closing the whole library here would
      // wait on futures a switch made under fake time.
      await services.remote!.close();
      await host.close();
      await desktop.close();
      await cache.delete(recursive: true);
    }),
  );
  return (services, host);
}

/// Taps the bottom navigation's 设置 and waits for the remote tile.
Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.text('设置'));
  // Runs out the tap's press-feedback timers.
  await tester.pump(const Duration(milliseconds: 200));
  await _settle(tester, find.byKey(const Key('settings-remote')));
}
