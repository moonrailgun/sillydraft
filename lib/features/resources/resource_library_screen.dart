import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../remote/share_screen.dart';
import '../../app/widgets.dart';
import '../personas/persona_list_screen.dart';
import 'writing_profile.dart';
import 'card_start_screen.dart';
import 'preset_prompt_editor.dart';
import 'resource_preview.dart';

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
    final kind = await showAppSheet<ResourceKind>(
      context: context,
      title: '选择导入类型',
      builder: (context) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: FTileGroup(
          children: [
            for (final e in resourceLabels.entries)
              FTile(
                title: Text(e.value),
                suffix: const Icon(FLucideIcons.chevronRight),
                onPress: () => Navigator.pop(context, e.key),
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
      final confirm = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          maxWidth: 620,
          title: Text('导入 ${preview.name}'),
          body: Column(
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
              JsonTreeView(preview.raw),
            ],
          ),
          actions: [
            FButton(
              variant: FButtonVariant.outline,
              onPress: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FButton(
              onPress: () => Navigator.pop(context, true),
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
  Widget build(BuildContext context) {
    final theme = context.theme;
    return PageScaffold(
      title: '创作资源库',
      floatingActionButton: _busy
          ? const _BusyAction(label: '导入资源')
          : FloatingAction(
              icon: FLucideIcons.fileInput,
              label: '导入资源',
              onPress: _import,
            ),
      bottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
            child: FTextField(
              hint: '搜索角色卡、预设或世界书',
              prefixBuilder: (context, style, variants) => Padding(
                padding: const EdgeInsetsDirectional.only(start: 10),
                child: Icon(
                  FLucideIcons.search,
                  size: 16,
                  color: theme.colors.mutedForeground,
                ),
              ),
              control: FTextFieldControl.managed(
                onChange: (value) {
                  if (value.text != _query) {
                    setState(() => _query = value.text);
                  }
                },
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: [
                ChoicePill(
                  label: '全部',
                  selected: _kind == null,
                  onPress: () => setState(() => _kind = null),
                ),
                for (final e in resourceLabels.entries)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoicePill(
                      label: e.value,
                      selected: _kind == e.key,
                      onPress: () => setState(() => _kind = e.key),
                    ),
                  ),
                const SizedBox(width: 12),
                ChoicePill(
                  label: '包含归档',
                  icon: FLucideIcons.archive,
                  selected: _archived,
                  onPress: () => setState(() => _archived = !_archived),
                ),
              ],
            ),
          ),
        ],
      ),
      body: AsyncView(
        value: ref.watch(resourcesProvider),
        builder: (all) {
          final personaTile = FTile(
            prefix: const Icon(FLucideIcons.users),
            title: const Text('人设'),
            subtitle: const Text('{{user}} 的名字、外貌和参考图'),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const PersonaListScreen(),
              ),
            ),
          );
          final resources = all
              .where(
                (r) =>
                    (_kind == null || r.kind == _kind) &&
                    (_archived || !r.archived) &&
                    r.name.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();
          if (resources.isEmpty) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 110),
              children: [
                personaTile,
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    '导入 ST 角色卡和预设，作为故事的起点。\n支持 JSON、PNG 和 CHARX 角色卡。',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colors.mutedForeground),
                  ),
                ),
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 110),
            itemCount: resources.length + 1,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              if (i == 0) return personaTile;
              final r = resources[i - 1];
              return FTile(
                prefix: Icon(
                  r.kind == ResourceKind.character
                      ? FLucideIcons.user
                      : FLucideIcons.slidersHorizontal,
                ),
                title: Text(r.name),
                subtitle: Text(
                  '${resourceLabels[r.kind]} · ${dateLabel(r.createdAt)}${r.parentId == null ? '' : ' · 编辑版本'}${r.archived ? ' · 已归档' : ''}',
                ),
                suffix: const Icon(FLucideIcons.chevronRight),
                onPress: () => _open(r),
              );
            },
          );
        },
      ),
    );
  }
}

/// The import button while an import runs: same place and label, with a
/// spinner and no action.
class _BusyAction extends StatelessWidget {
  const _BusyAction({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: context.theme.style.borderRadius.md,
      boxShadow: const [
        BoxShadow(
          color: Color(0x22000000),
          blurRadius: 16,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: FButton(
      mainAxisSize: MainAxisSize.min,
      onPress: null,
      prefix: const FCircularProgress(),
      child: Text(label),
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

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    LibraryResource resource,
  ) async {
    final yes = await confirmAction(
      context,
      title: '删除“${resource.name}”？',
      message: '资源和加密保存的原文件都会删除，不能撤销。仍被作品使用的资源不能删除。',
      confirmLabel: '删除资源',
      destructive: true,
    );
    if (!yes || !context.mounted) return;
    try {
      await ref.read(repositoryProvider).deleteResource(resource.id);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '资源详情',
    body: AsyncView(
      value: ref.watch(_resourceProvider(resourceId)),
      builder: (resource) {
        final theme = context.theme;
        final preset = resource.kind == ResourceKind.preset
            ? PresetImporter().decode(resource.data)
            : null;
        final header = SliverList.list(
          children: [
            Text(
              resource.name,
              style: theme.typography.body.xl2.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${resourceLabels[resource.kind]}${preset == null ? '' : ' · ${preset.kind.name}'} · ${resource.sourceHash.substring(0, 12)}',
              style: TextStyle(color: theme.colors.mutedForeground),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (resource.kind == ResourceKind.character)
                  FButton(
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            CardStartScreen(resourceId: resource.id),
                      ),
                    ),
                    prefix: const Icon(FLucideIcons.bookOpen),
                    child: const Text('从角色卡新建小说'),
                  ),
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ResourceEditScreen(resource: resource),
                    ),
                  ),
                  prefix: const Icon(FLucideIcons.squarePen),
                  child: const Text('编辑新版本'),
                ),
                FButton(
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => _export(context, resource),
                  prefix: const Icon(FLucideIcons.share),
                  child: const Text('导出 JSON'),
                ),
                FButton(
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => shareByQr(
                    context,
                    () => resourceShare(
                      ref.read(servicesProvider).library,
                      resource.id,
                    ),
                  ),
                  prefix: const Icon(FLucideIcons.qrCode),
                  child: const Text('扫码分享'),
                ),
                FButton(
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () async {
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
                  prefix: Icon(
                    resource.archived
                        ? FLucideIcons.archiveRestore
                        : FLucideIcons.archive,
                  ),
                  child: Text(resource.archived ? '恢复到资源库' : '归档'),
                ),
                // Like works on the bookshelf, only archived resources can be deleted.
                if (resource.archived)
                  FButton(
                    variant: FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: () => _delete(context, ref, resource),
                    prefix: const Icon(FLucideIcons.trash2),
                    child: const Text('删除'),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            if (preset != null && preset.diagnostics.isNotEmpty) ...[
              FTileGroup(
                children: [
                  for (final d in preset.diagnostics)
                    FTile(
                      title: Text(
                        d.message,
                        overflow: TextOverflow.visible,
                        softWrap: true,
                      ),
                      subtitle: Text('${d.severity.name} · ${d.code}'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text(
              '导出会保留未知字段并移除已识别凭据。角色卡附件保存在加密原文件中；此 JSON 导出不包含二进制附件。',
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 16),
          ],
        );
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(24),
              sliver: SliverMainAxisGroup(
                slivers: [header, _ResourceBody(resource, preset)],
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Slivers for a resource preview or its raw JSON as a foldable tree.
class _ResourceBody extends StatefulWidget {
  const _ResourceBody(this.resource, this.preset);
  final LibraryResource resource;
  final ImportedPreset? preset;
  @override
  State<_ResourceBody> createState() => _ResourceBodyState();
}

class _ResourceBodyState extends State<_ResourceBody> {
  bool _raw = false;

  Widget? _preview() {
    final data = widget.resource.data, preset = widget.preset;
    try {
      return switch (widget.resource.kind) {
        ResourceKind.character => CharacterPreview(data),
        ResourceKind.preset =>
          preset != null &&
                  (preset.prompts.isNotEmpty || _samplers(preset).isNotEmpty)
              ? _PresetPreview(preset)
              : null,
        ResourceKind.worldBook => WorldBookPreview(WorldBook.fromJson(data)),
        ResourceKind.regex => RegexPreview(RegexPreview.rulesOf(data)),
      };
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview();
    if (preview == null) {
      return SliverToBoxAdapter(child: JsonTreeView(widget.resource.data));
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Row(
            children: [
              ChoicePill(
                label: '预览',
                icon: FLucideIcons.eye,
                selected: !_raw,
                onPress: () => setState(() => _raw = false),
              ),
              const SizedBox(width: 8),
              ChoicePill(
                label: '原始 JSON',
                icon: FLucideIcons.braces,
                selected: _raw,
                onPress: () => setState(() => _raw = true),
              ),
            ],
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        if (_raw)
          SliverToBoxAdapter(child: JsonTreeView(widget.resource.data))
        else
          preview,
      ],
    );
  }
}

class ResourceEditScreen extends ConsumerStatefulWidget {
  const ResourceEditScreen({super.key, required this.resource});
  final LibraryResource resource;
  @override
  ConsumerState<ResourceEditScreen> createState() => _ResourceEditState();
}

class _ResourceEditState extends ConsumerState<ResourceEditScreen> {
  late bool _structured =
      widget.resource.kind == ResourceKind.preset &&
      PresetPromptEditor.supports(widget.resource.data);
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

  void _toggleStructured() {
    try {
      if (!_structured) {
        final value = jsonDecode(_text.text);
        if (value is! Map<String, dynamic> ||
            !PresetPromptEditor.supports(value)) {
          throw const FormatException('此配置没有 prompts 条目，请使用 JSON 编辑模板或采样参数');
        }
        PresetImporter().decode(value);
      }
      setState(() => _structured = !_structured);
    } catch (e) {
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '编辑资源新版本',
    actions: [
      FButton(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        mainAxisSize: MainAxisSize.min,
        onPress: _busy ? null : _save,
        child: const Text('保存新版本'),
      ),
    ],
    body: SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('已有小说仍使用原版本。保存后可在写作配置里选择新版本。原文件及附件会保留在原版本中。'),
          ),
          Expanded(
            child: _structured
                ? PresetPromptEditor(
                    value: jsonDecode(_text.text) as Map<String, dynamic>,
                    onChanged: (value) =>
                        _text.text = _jsonFormat.convert(value),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: FTextField(
                      control: FTextFieldControl.managed(controller: _text),
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      style: FTextFieldStyleDelta.delta(
                        contentTextStyle: FVariantsDelta.delta([
                          FVariantOperation.all(
                            const TextStyleDelta.delta(fontFamily: 'monospace'),
                          ),
                        ]),
                      ),
                    ),
                  ),
          ),
          if (widget.resource.kind == ResourceKind.preset)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Center(
                  child: FButton(
                    variant: FButtonVariant.ghost,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _toggleStructured,
                    prefix: Icon(
                      _structured
                          ? FLucideIcons.braces
                          : FLucideIcons.slidersHorizontal,
                    ),
                    child: Text(_structured ? '编辑完整 JSON' : '使用提示词条目编辑'),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// A formatting bundle keeps its samplers in its `preset` part.
Map<String, dynamic> _samplers(ImportedPreset preset) =>
    preset.parameters.isNotEmpty
    ? preset.parameters
    : preset.parts['preset']?.parameters ?? const {};

/// A read-only look at an ST preset: its sampler values, then its prompt
/// entries in the order generation uses them. Tapping an entry shows its
/// whole text.
class _PresetPreview extends StatefulWidget {
  const _PresetPreview(this.preset);
  final ImportedPreset preset;
  @override
  State<_PresetPreview> createState() => _PresetPreviewState();
}

class _PresetPreviewState extends State<_PresetPreview> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final preset = widget.preset;
    final samplers = _samplers(preset);
    List<PromptOrderItem> order;
    try {
      order = preset.selectOrder();
    } on PresetSelectionRequired {
      order = preset.orderGroups.first.items;
    }
    final prompts = {for (final p in preset.prompts) p.identifier: p};
    final placed = {for (final item in order) item.identifier};
    final on = {
      for (final item in order)
        if (item.enabled) item.identifier,
    };
    // The order's entries first, then any the order leaves out (never sent).
    final rows = [
      for (final item in order) ?prompts[item.identifier],
      for (final p in preset.prompts)
        if (!placed.contains(p.identifier)) p,
    ];
    return SliverMainAxisGroup(
      slivers: [
        if (samplers.isNotEmpty) ...[
          SliverToBoxAdapter(child: previewHeading(context, '采样参数')),
          SliverToBoxAdapter(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final MapEntry(:key, :value) in samplers.entries)
                  if (key == continuePrefillIgnored.path && value == true)
                    FTooltip(
                      tipBuilder: (_, _) => ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: Text(continuePrefillIgnored.message),
                      ),
                      child: _samplerBadge(
                        theme,
                        key,
                        value,
                        warning: const Icon(
                          FLucideIcons.triangleAlert,
                          key: Key('preset-ignored-continue_prefill'),
                          size: 14,
                          color: Color(0xFFEAB308),
                        ),
                      ),
                    )
                  else
                    _samplerBadge(theme, key, value),
              ],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
        if (rows.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: previewHeading(
              context,
              '提示词',
              '启用 ${rows.where((p) => on.contains(p.identifier)).length} / '
                  '${rows.length}'
                  '${preset.orderGroups.length > 1 ? ' · 按默认顺序组（共 ${preset.orderGroups.length} 组）' : ''}',
            ),
          ),
          SliverTileGroup(
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final p = rows[index];
              final open = _open.contains(p.identifier);
              final content = p.content.trim();
              return FTile(
                key: ValueKey('preset-prompt-${p.identifier}'),
                prefix: Icon(
                  on.contains(p.identifier)
                      ? FLucideIcons.circleCheck
                      : FLucideIcons.circle,
                  color: on.contains(p.identifier)
                      ? null
                      : theme.colors.mutedForeground,
                ),
                title: Text(
                  p.name,
                  style: on.contains(p.identifier)
                      ? null
                      : TextStyle(color: theme.colors.mutedForeground),
                ),
                subtitle: p.marker
                    ? const Text('动态标记 · 生成时填入')
                    : Text(
                        content.isEmpty
                            ? '（空）'
                            : open || content.length <= 400
                            ? content
                            : content.substring(0, 400),
                        maxLines: open ? null : 2,
                        softWrap: true,
                        overflow: open
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                      ),
                details: Text(
                  [
                    p.role,
                    if (p.injectionPosition == 1) '深度 ${p.depth}',
                  ].join(' · '),
                ),
                onPress: () => setState(() {
                  if (!_open.remove(p.identifier)) _open.add(p.identifier);
                }),
              );
            },
          ),
        ],
      ],
    );
  }
}

Widget _samplerBadge(
  FThemeData theme,
  String key,
  Object? value, {
  Widget? warning,
}) => FBadge(
  variant: FBadgeVariant.outline,
  child: Text.rich(
    TextSpan(
      children: [
        if (warning != null) ...[
          WidgetSpan(alignment: PlaceholderAlignment.middle, child: warning),
          const TextSpan(text: ' '),
        ],
        TextSpan(
          text: '$key  ',
          style: TextStyle(color: theme.colors.mutedForeground),
        ),
        TextSpan(
          text: _shortValue(value),
          style: TextStyle(color: theme.colors.foreground),
        ),
      ],
    ),
  ),
);

String _shortValue(Object? value) {
  final text = value is String ? value : jsonEncode(value);
  return text.length > 40 ? '${text.substring(0, 40)}…' : text;
}
