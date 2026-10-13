import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../presets/preset_screen.dart';
import 'resource_library_screen.dart';

final resourcesProvider = FutureProvider<List<LibraryResource>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listResources(includeArchived: true);
});

/// Per-novel switch in `writing/<branch>`; absent means on.
const assistantUsesPresetKey = 'assistantUsesPreset';

class WritingContext {
  const WritingContext({
    this.preset,
    this.card,
    required this.userName,
    required this.persona,
    this.selectedOrderId,
    required this.books,
    required this.regex,
    this.assistantPreset,
  });
  final ImportedPreset? preset;

  /// The preset the editing assistant assembles its chat with: the bound
  /// chat preset, unless the author switched that off for this novel.
  final ImportedPreset? assistantPreset;
  final CharacterCard? card;
  final String userName, persona;
  final int? selectedOrderId;
  final List<ScopedWorldBook> books;
  final List<Map<String, dynamic>> regex;
  static Future<WritingContext> load(
    AppServices services,
    String branchId,
  ) async {
    final data =
        await services.repository.getSetting('writing/$branchId') ?? {};
    final override = (data['presetOverrides'] as Map?)?[data['presetId']];
    ImportedPreset? preset = override is Map<String, dynamic>
        ? PresetImporter().decode(override)
        : data['presetId'] is String
        ? await services.library.preset(data['presetId'] as String)
        : null;
    final parts = <String, dynamic>{};
    for (final entry in {
      'contextId': 'context',
      'instructId': 'instruct',
      'systemPromptId': 'sysprompt',
      'reasoningId': 'reasoning',
    }.entries) {
      if (data[entry.key] is String) {
        parts[entry.value] = (await services.repository.getResource(
          data[entry.key] as String,
        )).data;
      }
    }
    if (parts.isNotEmpty) {
      if (preset?.kind == PresetKind.chat ||
          preset?.kind == PresetKind.promptPack) {
        throw const FormatException('聊天预设不能与文本补全格式组件混用。请清除格式组件或选用文本补全预设。');
      }
      preset = PresetImporter().decode({
        ...?preset?.kind == PresetKind.bundle ? preset?.raw : null,
        if (preset != null && preset.kind != PresetKind.bundle)
          'preset': preset.raw,
        ...parts,
      });
    }
    final books = <ScopedWorldBook>[];
    for (final id in (data['worldBookIds'] as List? ?? [])) {
      final resource = await services.repository.getResource(id as String);
      books.add(
        ScopedWorldBook(WorldBook.fromJson(resource.data), branchId: branchId),
      );
    }
    final regex = <Map<String, dynamic>>[];
    for (final id in (data['regexIds'] as List? ?? [])) {
      final raw = (await services.repository.getResource(id as String)).data;
      regex.addAll(
        raw['scripts'] is List
            ? (raw['scripts'] as List).cast<Map<String, dynamic>>()
            : [raw],
      );
    }
    return WritingContext(
      preset: preset,
      assistantPreset:
          data[assistantUsesPresetKey] != false &&
              (preset?.kind == PresetKind.chat ||
                  preset?.kind == PresetKind.promptPack)
          ? preset
          : null,
      card: data['cardId'] is String
          ? await services.library.character(data['cardId'] as String)
          : null,
      userName: data['userName'] as String? ?? '主角',
      persona: data['persona'] as String? ?? '',
      selectedOrderId: data['selectedOrderId'] as int?,
      books: books,
      regex: regex,
    );
  }
}

class WritingProfileScreen extends ConsumerStatefulWidget {
  const WritingProfileScreen({super.key, required this.branchId});
  final String branchId;
  @override
  ConsumerState<WritingProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<WritingProfileScreen> {
  final _user = TextEditingController(), _persona = TextEditingController();
  Map<String, dynamic>? _value;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final value =
        await ref
            .read(repositoryProvider)
            .getSetting('writing/${widget.branchId}') ??
        {};
    if (!mounted) return;
    _user.text = value['userName'] as String? ?? '主角';
    _persona.text = value['persona'] as String? ?? '';
    setState(() => _value = value);
  }

  @override
  void dispose() {
    _user.dispose();
    _persona.dispose();
    super.dispose();
  }

  /// The preset panel owns the preset binding; take its result back so saving
  /// this page cannot restore a stale choice.
  Future<void> _openPresets() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PresetScreen(branchId: widget.branchId),
      ),
    );
    final latest =
        await ref
            .read(repositoryProvider)
            .getSetting('writing/${widget.branchId}') ??
        {};
    if (!mounted) return;
    setState(() {
      for (final key in [
        'presetId',
        'presetOverrides',
        'selectedOrderId',
        assistantUsesPresetKey,
      ]) {
        if (latest.containsKey(key)) {
          _value![key] = latest[key];
        } else {
          _value!.remove(key);
        }
      }
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await ref.read(repositoryProvider).setSetting(
        'writing/${widget.branchId}',
        {..._value!, 'userName': _user.text.trim(), 'persona': _persona.text},
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '角色卡与世界书',
    actions: [
      HeaderIconAction(
        tooltip: '资源库',
        onPress: () => Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => const ResourceLibraryScreen(),
          ),
        ),
        icon: FLucideIcons.folderOpen,
      ),
    ],
    body: _value == null
        ? const Center(child: FCircularProgress())
        : AsyncView(
            value: ref.watch(resourcesProvider),
            builder: (resources) {
              final theme = context.theme;
              Widget select(
                String key,
                String label,
                ResourceKind kind, {
                PresetKind? presetKind,
              }) {
                final items = resources
                    .where(
                      (r) =>
                          r.kind == kind &&
                          (!r.archived || r.id == _value![key]) &&
                          (presetKind == null ||
                              PresetImporter().decode(r.data).kind ==
                                  presetKind),
                    )
                    .toList();
                String name(LibraryResource r) =>
                    '${r.name}${r.archived ? ' · 已归档' : ''}';
                final names = {for (final r in items) r.id: name(r)};
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: FSelect<String>.rich(
                    key: ValueKey('$key:${_value![key]}'),
                    label: Text(label),
                    format: (id) => names[id] ?? '不使用 / 默认',
                    control: FSelectControl<String>.lifted(
                      value: names.containsKey(_value![key])
                          ? _value![key] as String
                          : _none,
                      onChange: (v) => setState(() {
                        if (v == null || v == _none) {
                          _value!.remove(key);
                        } else {
                          _value![key] = v;
                        }
                        if (key == 'presetId') {
                          _value!.remove('selectedOrderId');
                        }
                      }),
                    ),
                    children: [
                      FSelectItem<String>(
                        title: const Text('不使用 / 默认'),
                        value: _none,
                      ),
                      for (final r in items)
                        FSelectItem<String>(
                          title: Text(name(r), overflow: TextOverflow.ellipsis),
                          value: r.id,
                        ),
                    ],
                  ),
                );
              }

              final selected = resources
                  .where((r) => r.id == _value!['presetId'])
                  .firstOrNull;
              final preset = selected == null
                  ? null
                  : PresetImporter().decode(
                      (_value!['presetOverrides'] as Map?)?[selected.id]
                              as Map<String, dynamic>? ??
                          selected.data,
                    );
              String orderLabel(int? id) {
                if (id == null) return '自动选择全局顺序 100001';
                final group = preset?.orderGroups
                    .where((g) => g.characterId == id)
                    .firstOrNull;
                return '顺序组 $id · ${group?.items.length ?? 0} 项';
              }

              Widget checks(ResourceKind kind) {
                final key = kind == ResourceKind.worldBook
                    ? 'worldBookIds'
                    : 'regexIds';
                final ids = _value![key] as List? ?? [];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final r in resources.where(
                      (r) => r.kind == kind && !r.archived,
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: FCheckbox(
                          label: Text(r.name),
                          value: ids.contains(r.id),
                          onChange: (v) => setState(() {
                            final next = List<String>.from(
                              _value![key] as List? ?? [],
                            );
                            if (v) {
                              next.add(r.id);
                            } else {
                              next.remove(r.id);
                            }
                            _value![key] = next;
                          }),
                        ),
                      ),
                  ],
                );
              }

              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text('正文生成使用这里的配置。编辑助手的工具权限独立管理。'),
                  const SizedBox(height: 20),
                  select('cardId', '角色卡', ResourceKind.character),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: FTile(
                      key: const Key('open-preset-panel'),
                      prefix: const Icon(FLucideIcons.slidersHorizontal),
                      title: Text('预设：${selected?.name ?? '未选择'}'),
                      subtitle: Text(
                        (_value!['presetOverrides'] as Map?)?.containsKey(
                                  selected?.id,
                                ) ==
                                true
                            ? '已自定义 · 仅当前分支生效'
                            : '调整参数和提示词，自动保存到当前分支',
                      ),
                      suffix: const Icon(FLucideIcons.chevronRight),
                      onPress: _openPresets,
                    ),
                  ),
                  if (preset != null &&
                      preset.orderGroups.any((g) => g.characterId != null))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: FSelect<int?>.rich(
                        label: const Text('提示词顺序组'),
                        hint: orderLabel(null),
                        format: orderLabel,
                        control: FSelectControl<int?>.lifted(
                          value: _value!['selectedOrderId'] as int?,
                          onChange: (v) =>
                              setState(() => _value!['selectedOrderId'] = v),
                        ),
                        children: [
                          FSelectItem<int?>(
                            title: Text(orderLabel(null)),
                            value: null,
                          ),
                          for (final group in preset.orderGroups)
                            if (group.characterId != null)
                              FSelectItem<int?>(
                                title: Text(orderLabel(group.characterId)),
                                value: group.characterId,
                              ),
                        ],
                      ),
                    ),
                  FTextField(
                    control: FTextFieldControl.managed(controller: _user),
                    label: const Text('{{user}} 对应人物名'),
                  ),
                  const SizedBox(height: 16),
                  FTextField(
                    control: FTextFieldControl.managed(controller: _persona),
                    minLines: 2,
                    maxLines: 5,
                    label: const Text('主角身份 / Persona'),
                  ),
                  const SizedBox(height: 16),
                  FAccordion(
                    children: [
                      FAccordionItem(
                        title: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('文本补全格式组合'),
                            Text(
                              'Context、Instruct、System Prompt、Reasoning',
                              style: theme.typography.body.sm.copyWith(
                                color: theme.colors.mutedForeground,
                                fontWeight: FontWeight.normal,
                              ),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            select(
                              'contextId',
                              'Context 模板',
                              ResourceKind.preset,
                              presetKind: PresetKind.context,
                            ),
                            select(
                              'instructId',
                              'Instruct 模板',
                              ResourceKind.preset,
                              presetKind: PresetKind.instruct,
                            ),
                            select(
                              'systemPromptId',
                              'System Prompt',
                              ResourceKind.preset,
                              presetKind: PresetKind.systemPrompt,
                            ),
                            select(
                              'reasoningId',
                              'Reasoning',
                              ResourceKind.preset,
                              presetKind: PresetKind.reasoning,
                            ),
                          ],
                        ),
                      ),
                      FAccordionItem(
                        title: const Text('额外世界书'),
                        child: checks(ResourceKind.worldBook),
                      ),
                      FAccordionItem(
                        title: const Text('全局正则'),
                        child: checks(ResourceKind.regex),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FButton(
                    onPress: _busy ? null : _save,
                    child: const Text('保存配置'),
                  ),
                ],
              );
            },
          ),
  );
}

/// The "not used" choice of a resource select.
const _none = '';
