import 'dart:typed_data';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../editor/workspace_screen.dart';
import 'file_gateway.dart';

class RestoreBackupScreen extends ConsumerStatefulWidget {
  const RestoreBackupScreen({super.key});
  @override
  ConsumerState<RestoreBackupScreen> createState() => _RestoreState();
}

class _RestoreState extends ConsumerState<RestoreBackupScreen> {
  final _passphrase = TextEditingController();
  Uint8List? _bytes;
  BackupContents? _preview;
  bool _busy = false;
  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    try {
      final bytes = await ref.read(transferFilesProvider).chooseBackup();
      if (bytes != null && mounted) {
        setState(() {
          _bytes = bytes;
          _preview = null;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _read() async {
    setState(() => _busy = true);
    try {
      final preview = await ref
          .read(servicesProvider)
          .backups
          .read(_bytes!, passphrase: _passphrase.text);
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    setState(() => _busy = true);
    try {
      final novel = await ref
          .read(servicesProvider)
          .backups
          .restoreContents(_preview!);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => NovelWorkspace(novelId: novel.id),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: PageScaffold(
      title: '恢复项目备份',
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text('恢复后会新增一部独立作品，包含备份中的分支和历史。当前书架中的作品会保留。'),
                const SizedBox(height: 24),
                FButton(
                  variant: FButtonVariant.outline,
                  onPress: _busy ? null : _choose,
                  prefix: const Icon(FLucideIcons.folderOpen),
                  child: const Text('选择备份文件'),
                ),
                if (_bytes != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '已选择备份 · ${(_bytes!.length / 1024).toStringAsFixed(1)} KB',
                  ),
                  const SizedBox(height: 16),
                  FTextField(
                    key: const Key('restore-passphrase'),
                    control: FTextFieldControl.managed(controller: _passphrase),
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    label: const Text('备份口令'),
                  ),
                  const SizedBox(height: 16),
                  FButton(
                    onPress: _busy ? null : _read,
                    child: const Text('解锁并预览'),
                  ),
                ],
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: FProgress(),
                  ),
                if (_preview case final preview?) ...[
                  const SizedBox(height: 24),
                  FCard(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preview.snapshot.title,
                            style: context.theme.typography.body.lg.copyWith(
                              fontWeight: FontWeight.w600,
                              color: context.theme.colors.foreground,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${preview.branchCount} 个分支 · ${preview.assetCount} 张图片',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'ST 原文件会使用本机的资源密钥重新加密。未完成的生成任务会标为中断，模型密钥需重新配置。',
                            style: context.theme.typography.body.sm.copyWith(
                              color: context.theme.colors.mutedForeground,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FButton(
                    onPress: _busy ? null : _restore,
                    prefix: const Icon(FLucideIcons.archiveRestore),
                    child: const Text('恢复为独立作品'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
