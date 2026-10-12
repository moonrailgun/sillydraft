import 'package:flutter/material.dart';
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
    child: Scaffold(
      appBar: AppBar(title: const Text('导出与备份')),
      body: SafeArea(
        child: AsyncView(
          value: ref.watch(novelProvider(widget.novelId)),
          builder: (Novel novel) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    novel.title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  const Text('阅读文件使用所选分支中已采纳的正文。'),
                  const SizedBox(height: 16),
                  AsyncView(
                    value: ref.watch(transferBranchesProvider(novel.id)),
                    builder: (List<StoryBranch> branches) =>
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _branch ?? novel.activeBranchId,
                          decoration: const InputDecoration(
                            labelText: '导出的故事分支',
                          ),
                          items: [
                            for (final b in branches)
                              DropdownMenuItem(
                                value: b.id,
                                child: Text(
                                  b.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _branch = v),
                        ),
                  ),
                  const SizedBox(height: 16),
                  for (final entry in {
                    PublicationFormat.text: '导出 TXT',
                    PublicationFormat.markdown: '导出 Markdown 与插图',
                    PublicationFormat.epub: '导出 EPUB',
                  }.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _export(novel, entry.key),
                        icon: const Icon(Icons.ios_share),
                        label: Text(entry.value),
                      ),
                    ),
                  const Text(
                    'TXT 用文字标记插图；Markdown 以 ZIP 携带图片；EPUB 包含目录、封面和插图。',
                  ),
                  const SizedBox(height: 28),
                  const Divider(),
                  const SizedBox(height: 16),
                  Text('完整项目备份', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  const Text(
                    '保存所有分支、正文版本、创作资料、任务记录、图片和已引用的 ST 原文件。用口令保护备份；口令遗失后无法恢复。模型密钥需在新设备重新配置。',
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: '备份口令（至少 12 个字符）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmation,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '再次输入备份口令'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _export(novel, null),
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('创建加密备份'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 20),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    const Text('正在准备文件，请稍候…'),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(_message!, semanticsLabel: _message),
                    ),
                  const SizedBox(height: 28),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cloud_sync_outlined),
                    title: const Text('多设备同步'),
                    subtitle: const Text('连接自己的同步空间，保留冲突副本'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy
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
            ),
          ),
        ),
      ),
    ),
  );
}
