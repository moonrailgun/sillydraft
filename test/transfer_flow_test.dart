import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';
import 'package:sillydraft/features/transfer/file_gateway.dart';
import 'package:sillydraft/features/transfer/transfer_screen.dart';
import 'package:sillydraft/features/transfer/restore_screen.dart';
import 'package:sillydraft/features/transfer/sync_screen.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

class _Files implements TransferFileGateway {
  Uint8List? selected;
  PublicationFile? exported;
  @override
  Future<Uint8List?> chooseBackup() async => selected;
  @override
  Future<bool> save(BuildContext context, PublicationFile file) async {
    exported = file;
    return true;
  }
}

void main() {
  testWidgets(
    'connected sync cannot silently replace its saved decryption passphrase',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sillydraft-sync-ui-'),
      );
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
        dataDirectory: dir,
      );
      addTearDown(() async {
        await services.close();
        await dir!.delete(recursive: true);
      });
      final novel = await services.repository.createNovel(title: '正在同步的作品');
      await services.repository.setSetting('syncConfig/${novel.id}', {
        'url': 'http://127.0.0.1:1/story.sillydraft',
        'authType': 'none',
      });
      await services.repository.setSetting('syncState/${novel.id}', {
        'remoteEtag': '"known"',
        'localFingerprint': 'known',
      });
      await services.secrets.write(
        'sync/${novel.id}/passphrase',
        'original shared passphrase',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(services)],
          child: MaterialApp(home: ProjectSyncScreen(novelId: novel.id)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, '项目同步口令（至少 12 个字符）'),
        'different new passphrase',
      );
      await tester.scrollUntilVisible(
        find.text('保存配置并同步'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('保存配置并同步'));
      await tester.pumpAndSettle();
      expect(
        await services.secrets.read('sync/${novel.id}/passphrase'),
        'original shared passphrase',
      );
      expect(find.textContaining('更换口令请使用新的同步地址'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'phone export shares the selected manuscript and keeps the project editable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sillydraft-transfer-ui-'),
      );
      final services = AppServices(
        repository: StoryRepository.memory(),
        secrets: MemorySecrets(),
        dataDirectory: dir,
      );
      addTearDown(() async {
        await services.close();
        await dir!.delete(recursive: true);
      });
      final n = await services.repository.createNovel(title: '可以导出的小说');
      final c = await services.repository.createChapter(
        branchId: n.activeBranchId,
        title: '第一章',
      );
      final s = await services.repository.createScene(
        branchId: n.activeBranchId,
        chapterId: c.id,
        content: ManuscriptContent.plainText('海雾升起。'),
      );
      final files = _Files();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            servicesProvider.overrideWithValue(services),
            transferFilesProvider.overrideWithValue(files),
          ],
          child: MaterialApp(home: TransferScreen(novelId: n.id)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('导出 TXT'));
      await tester.pumpAndSettle();
      expect(files.exported!.filename, endsWith('.txt'));
      expect(utf8.decode(files.exported!.bytes), contains('海雾升起。'));
      expect(
        (await services.repository.getScene(
          branchId: s.branchId,
          sceneId: s.id,
        )).revisionId,
        s.revisionId,
      );
      expect(find.text('已交给系统保存或分享'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'restoring an encrypted backup previews its contents and preserves existing books',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late AppServices services;
      final files = _Files();
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('sillydraft-restore-ui-');
        services = AppServices(
          repository: StoryRepository.memory(),
          secrets: MemorySecrets(),
          dataDirectory: dir,
        );
        final n = await services.repository.createNovel(title: '备份里的作品');
        final backup = ProjectBackup(
          repository: services.repository,
          assets: services.assets!,
          resources: services.library,
        );
        files.selected = await backup.create(
          n.id,
          passphrase: 'correct horse battery staple',
        );
        await services.repository.createNovel(title: '现有作品');
      });
      addTearDown(() async {
        await services.close();
        await dir.delete(recursive: true);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            servicesProvider.overrideWithValue(services),
            transferFilesProvider.overrideWithValue(files),
          ],
          child: const MaterialApp(home: RestoreBackupScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择备份文件'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('restore-passphrase')),
        'correct horse battery staple',
      );
      await tester.tap(find.text('解锁并预览'));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        if (find.text('恢复为独立作品').evaluate().isNotEmpty) break;
      }
      expect(find.text('备份里的作品'), findsOneWidget);
      expect((await services.repository.listNovels()).length, 2);
      await tester.tap(find.text('恢复为独立作品'));
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if ((await services.repository.listNovels()).length == 3) break;
      }
      await tester.pumpAndSettle();
      expect((await services.repository.listNovels()).length, 3);
      expect(
        (await services.repository.listNovels()).any((n) => n.title == '现有作品'),
        true,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
