import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import 'writing_profile.dart';

const resourceLabels = {
  ResourceKind.character: '角色卡',
  ResourceKind.preset: 'ST 预设',
  ResourceKind.worldBook: '世界书',
  ResourceKind.regex: '正则脚本',
};
const _jsonFormat = JsonEncoder.withIndent('  ');

class ResourceLibraryScreen extends ConsumerStatefulWidget {
  const ResourceLibraryScreen({super.key});
  @override
  ConsumerState<ResourceLibraryScreen> createState() => _LibraryState();
}

class _LibraryState extends ConsumerState<ResourceLibraryScreen> {
  ResourceKind? _kind;
  bool _busy = false, _archived = false;
  String _query = '';
  Future<void> _import() async {
    final kind = await showModalBottomSheet<ResourceKind>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(title: Text('选择导入类型')),
            for (final e in resourceLabels.entries)
              ListTile(
                title: Text(e.value),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(context, e.key),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: resourceLabels[kind],
            extensions: kind == ResourceKind.character
                ? ['json', 'png', 'charx']
                : ['json'],
            uniformTypeIdentifiers: const ['public.data'],
          ),
        ],
      );
      if (file == null) return;
      if (await file.length() > 32 * 1024 * 1024) {
        throw const FormatException('资源不能超过 32 MB');
      }
      final bytes = await file.readAsBytes(),
          library = ref.read(servicesProvider).library;
      final preview = library.inspect(bytes, filename: file.name, kind: kind);
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('导入 ${preview.name}'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(resourceLabels[kind]!),
                  const SizedBox(height: 12),
                  for (final d in preview.diagnostics)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(d.message),
                    ),
                  const Text('未知字段会保留；连接凭据不会自动启用。原文件加密保存。'),
                  const SizedBox(height: 16),
                  SelectableText(_previewJson(preview.raw)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入资源'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      final resource = await library.import(
        bytes,
        filename: file.name,
        kind: kind,
      );
      if (mounted) _open(resource);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(LibraryResource resource) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ResourceDetailScreen(resourceId: resource.id),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('创作资源库')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _busy ? null : _import,
      icon: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(),
            )
          : const Icon(Icons.file_open_outlined),
      label: const Text('导入资源'),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: TextField(
            decoration: const InputDecoration(
              hintText: '搜索角色卡、预设或世界书',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: _kind == null,
                onSelected: (_) => setState(() => _kind = null),
              ),
              for (final e in resourceLabels.entries)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoiceChip(
                    label: Text(e.value),
                    selected: _kind == e.key,
                    onSelected: (_) => setState(() => _kind = e.key),
                  ),
                ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('包含归档'),
                selected: _archived,
                onSelected: (v) => setState(() => _archived = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncView(
            value: ref.watch(resourcesProvider),
            builder: (all) {
              final resources = all
                  .where(
                    (r) =>
                        (_kind == null || r.kind == _kind) &&
                        (_archived || !r.archived) &&
                        r.name.toLowerCase().contains(_query.toLowerCase()),
                  )
                  .toList();
              if (resources.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      '导入 ST 角色卡和预设，作为故事的起点。\n支持 JSON、PNG 和 CHARX 角色卡。',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 110),
                itemCount: resources.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  final r = resources[i];
                  return Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.all(16),
                      leading: Icon(
                        r.kind == ResourceKind.character
                            ? Icons.person_outline
                            : Icons.tune,
                      ),
                      title: Text(r.name),
                      subtitle: Text(
                        '${resourceLabels[r.kind]} · ${dateLabel(r.createdAt)}${r.parentId == null ? '' : ' · 编辑版本'}${r.archived ? ' · 已归档' : ''}',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(r),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

final _resourceProvider = FutureProvider.family<LibraryResource, String>((
  ref,
  id,
) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getResource(id);
});

class ResourceDetailScreen extends ConsumerWidget {
  const ResourceDetailScreen({super.key, required this.resourceId});
  final String resourceId;
  Future<void> _export(BuildContext context, LibraryResource resource) async {
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(_jsonFormat.convert(resource.exportJson())),
      );
      final filename =
          '${resource.name.replaceAll(RegExp(r'[^\p{L}\p{N}_-]', unicode: true), '_')}.json';
      final file = XFile.fromData(
        bytes,
        mimeType: 'application/json',
        name: filename,
      );
      if (Platform.isAndroid || Platform.isIOS) {
        final box = context.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(
          ShareParams(
            files: [file],
            fileNameOverrides: [filename],
            sharePositionOrigin: box == null
                ? null
                : box.localToGlobal(Offset.zero) & box.size,
          ),
        );
      } else {
        final location = await getSaveLocation(suggestedName: filename);
        if (location != null) await file.saveTo(location.path);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('资源详情')),
    body: AsyncView(
      value: ref.watch(_resourceProvider(resourceId)),
      builder: (resource) {
        final preset = resource.kind == ResourceKind.preset
            ? PresetImporter().decode(resource.data)
            : null;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              resource.name,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              '${resourceLabels[resource.kind]}${preset == null ? '' : ' · ${preset.kind.name}'} · ${resource.sourceHash.substring(0, 12)}',
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ResourceEditScreen(resource: resource),
                    ),
                  ),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑新版本'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _export(context, resource),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('导出 JSON'),
                ),
                TextButton(
                  onPressed: () async {
                    try {
                      await ref
                          .read(repositoryProvider)
                          .archiveResource(
                            resource.id,
                            archived: !resource.archived,
                          );
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  child: Text(resource.archived ? '恢复到资源库' : '归档'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (preset != null) ...[
              for (final d in preset.diagnostics)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.message),
                  subtitle: Text('${d.severity.name} · ${d.code}'),
                ),
              Text(
                '提示词 ${preset.prompts.length} 项 · 顺序组 ${preset.orderGroups.length} 组',
              ),
              const SizedBox(height: 12),
            ],
            const Text('导出会保留未知字段并移除已识别凭据。角色卡附件保存在加密原文件中；此 JSON 导出不包含二进制附件。'),
            const SizedBox(height: 16),
            SelectableText(_previewJson(resource.data)),
          ],
        );
      },
    ),
  );
}

class ResourceEditScreen extends ConsumerStatefulWidget {
  const ResourceEditScreen({super.key, required this.resource});
  final LibraryResource resource;
  @override
  ConsumerState<ResourceEditScreen> createState() => _ResourceEditState();
}

class _ResourceEditState extends ConsumerState<ResourceEditScreen> {
  late final _text = TextEditingController(
    text: _jsonFormat.convert(widget.resource.data),
  );
  bool _busy = false;
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final raw = jsonDecode(_text.text);
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('需要 JSON 对象');
      }
      final next = await ref
          .read(servicesProvider)
          .library
          .edit(widget.resource.id, raw);
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ResourceDetailScreen(resourceId: next.id),
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('编辑资源新版本'),
      actions: [
        TextButton(onPressed: _busy ? null : _save, child: const Text('保存新版本')),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('已有小说仍使用原版本。保存后可在写作配置里选择新版本。原文件及附件会保留在原版本中。'),
          ),
          Expanded(
            child: TextField(
              controller: _text,
              maxLines: null,
              expands: true,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(20),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

String _previewJson(Map<String, dynamic> value) {
  final text = _jsonFormat.convert(value);
  return text.length > 24000
      ? '${text.substring(0, 24000)}\n… 预览已截短，完整内容仍可编辑和导出。'
      : text;
}
