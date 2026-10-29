import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../editor/workspace_screen.dart';
import 'file_gateway.dart';
import 'sync_screen.dart';

final transferBranchesProvider =
    FutureProvider.family<List<StoryBranch>, String>((ref, id) {
      ref.watch(repositoryChangesProvider);
      return ref.watch(repositoryProvider).listBranches(id);
    });

class TransferScreen extends ConsumerStatefulWidget {
  const TransferScreen({super.key, required this.novelId});
  final String novelId;
  @override
  ConsumerState<TransferScreen> createState() => _TransferState();
}

class _TransferState extends ConsumerState<TransferScreen> {
  String? _branch, _message;
  bool _busy = false;
  final _password = TextEditingController(),
      _confirmation = TextEditingController();
  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _export(Novel novel, PublicationFormat? format) async {
    if (format == null &&
        (_password.text.runes.length < 12 ||
            _password.text != _confirmation.text)) {
      showError(context, const FormatException('请输入至少 12 个字符的口令，并确认两次输入一致'));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final services = ref.read(servicesProvider);
      await services.flushDrafts();
      final file = format == null
          ? PublicationFile(
              filename: '${safePublicationName(novel.title)}.sillydraft',
              mimeType: 'application/octet-stream',
              bytes: await services.backups.create(
                novel.id,
                passphrase: _password.text,
              ),
            )
          : await services.publications.export(
              branchId: _branch ?? novel.activeBranchId,
              format: format,
            );
      if (!mounted) return;
      final saved = await ref.read(transferFilesProvider).save(context, file);
      if (mounted) setState(() => _message = saved ? '已交给系统保存或分享' : '已取消保存');
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
      title: '导出与备份',
      body: SafeArea(
        top: false,
        child: AsyncView(
          value: ref.watch(novelProvider(widget.novelId)),
          builder: (Novel novel) {
            final theme = context.theme;
            final heading = theme.typography.body.lg.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colors.foreground,
            );
            return ContentLayout(
              maxWidth: 720,
              builder: (_, inset) => ListView(
                padding: inset + const EdgeInsets.all(24),
                children: [
                  Text(
                    novel.title,
                    style: theme.typography.body.xl2.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colors.foreground,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('阅读文件使用所选分支中已采纳的正文。'),
                  const SizedBox(height: 16),
                  AsyncView(
                    value: ref.watch(transferBranchesProvider(novel.id)),
                    builder: (List<StoryBranch> branches) {
                      final names = {for (final b in branches) b.id: b.name};
                      return FSelect<String>.rich(
                        label: const Text('导出的故事分支'),
                        enabled: !_busy,
                        format: (id) => names[id] ?? '',
                        control: FSelectControl.lifted(
                          value: _branch ?? novel.activeBranchId,
                          onChange: (v) {
                            if (v != null) setState(() => _branch = v);
                          },
                        ),
                        children: [
                          for (final b in branches)
                            FSelectItem<String>(
                              title: Text(
                                b.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                              value: b.id,
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  for (final entry in {
                    PublicationFormat.text: '导出 TXT',
                    PublicationFormat.markdown: '导出 Markdown 与插图',
                    PublicationFormat.epub: '导出 EPUB',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: FButton(
                        variant: FButtonVariant.outline,
                        onPress: _busy ? null : () => _export(novel, entry.key),
                        prefix: const Icon(FLucideIcons.share),
                        child: Text(entry.value),
                      ),
                    ),
                  const Text(
                    'TXT 用文字标记插图；Markdown 以 ZIP 携带图片；EPUB 包含目录、封面和插图。',
                  ),
                  const SizedBox(height: 28),
                  const FDivider(),
                  const SizedBox(height: 16),
                  Text('完整项目备份', style: heading),
                  const SizedBox(height: 12),
                  const Text(
                    '保存所有分支、正文版本、创作资料、任务记录、图片和已引用的 ST 原文件。用口令保护备份；口令遗失后无法恢复。模型密钥需在新设备重新配置。',
                  ),
                  const SizedBox(height: 16),
                  FTextField(
                    control: FTextFieldControl.managed(controller: _password),
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    label: const Text('备份口令（至少 12 个字符）'),
                  ),
                  const SizedBox(height: 12),
                  FTextField(
                    control: FTextFieldControl.managed(
                      controller: _confirmation,
                    ),
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    label: const Text('再次输入备份口令'),
                  ),
                  const SizedBox(height: 16),
                  FButton(
                    onPress: _busy ? null : () => _export(novel, null),
                    prefix: const Icon(FLucideIcons.lock),
                    child: const Text('创建加密备份'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 20),
                    const FProgress(),
                    const SizedBox(height: 8),
                    const Text('正在准备文件，请稍候…'),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_message!, semanticsLabel: _message),
                    ),
                  const SizedBox(height: 28),
                  FTile(
                    prefix: const Icon(FLucideIcons.cloudSync),
                    title: const Text('多设备同步'),
                    subtitle: const Text('连接自己的同步空间，保留冲突副本'),
                    suffix: const Icon(FLucideIcons.chevronRight),
                    onPress: _busy
                        ? null
                        : () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  ProjectSyncScreen(novelId: novel.id),
                            ),
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
