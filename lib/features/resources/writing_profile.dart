import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import 'resource_library_screen.dart';

final resourcesProvider = FutureProvider<List<LibraryResource>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listResources(includeArchived: true);
});

class WritingContext {
  const WritingContext({
    this.preset,
    this.card,
    required this.userName,
    required this.persona,
    this.selectedOrderId,
    required this.books,
    required this.regex,
  });
  final ImportedPreset? preset;
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
    ImportedPreset? preset = data['presetId'] is String
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('角色卡与写作预设'),
      actions: [
        IconButton(
          tooltip: '资源库',
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => const ResourceLibraryScreen(),
            ),
          ),
          icon: const Icon(Icons.folder_open),
        ),
      ],
    ),
    body: _value == null
        ? const Center(child: CircularProgressIndicator())
        : AsyncView(
            value: ref.watch(resourcesProvider),
            builder: (resources) {
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
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('$key:${_value![key]}'),
                    isExpanded: true,
                    initialValue: items.any((r) => r.id == _value![key])
                        ? _value![key] as String?
                        : null,
                    decoration: InputDecoration(labelText: label),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('不使用 / 默认'),
                      ),
                      for (final r in items)
                        DropdownMenuItem(
                          value: r.id,
                          child: Text(
                            '${r.name}${r.archived ? ' · 已归档' : ''}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      if (v == null) {
                        _value!.remove(key);
                      } else {
                        _value![key] = v;
                      }
                      if (key == 'presetId') _value!.remove('selectedOrderId');
                    }),
                  ),
                );
              }

              final selected = resources
                  .where((r) => r.id == _value!['presetId'])
                  .firstOrNull;
              final preset = selected == null
                  ? null
                  : PresetImporter().decode(selected.data);
              return ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text('正文生成使用这里的配置。编辑助手的工具权限独立管理。'),
                  const SizedBox(height: 20),
                  select('cardId', '角色卡', ResourceKind.character),
                  select('presetId', '写作预设', ResourceKind.preset),
                  if (preset != null &&
                      preset.orderGroups.any((g) => g.characterId != null))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DropdownButtonFormField<int>(
                        initialValue: _value!['selectedOrderId'] as int?,
                        decoration: const InputDecoration(labelText: '提示词顺序组'),
                        items: [
                          const DropdownMenuItem<int>(
                            value: null,
                            child: Text('自动选择全局顺序 100001'),
                          ),
                          for (final group in preset.orderGroups)
                            if (group.characterId != null)
                              DropdownMenuItem(
                                value: group.characterId,
                                child: Text(
                                  '顺序组 ${group.characterId} · ${group.items.length} 项',
                                ),
                              ),
                        ],
                        onChanged: (v) =>
                            setState(() => _value!['selectedOrderId'] = v),
                      ),
                    ),
                  TextField(
                    controller: _user,
                    decoration: const InputDecoration(
                      labelText: '{{user}} 对应人物名',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _persona,
                    minLines: 2,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '主角身份 / Persona',
                    ),
                  ),
                  const SizedBox(height: 16),
                  ExpansionTile(
                    title: const Text('文本补全格式组合'),
                    subtitle: const Text(
                      'Context、Instruct、System Prompt、Reasoning',
                    ),
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
                  for (final kind in [
                    ResourceKind.worldBook,
                    ResourceKind.regex,
                  ])
                    ExpansionTile(
                      title: Text(
                        kind == ResourceKind.worldBook ? '额外世界书' : '全局正则',
                      ),
                      children: [
                        for (final r in resources.where(
                          (r) => r.kind == kind && !r.archived,
                        ))
                          CheckboxListTile(
                            title: Text(r.name),
                            value:
                                (_value![kind == ResourceKind.worldBook
                                                ? 'worldBookIds'
                                                : 'regexIds']
                                            as List? ??
                                        [])
                                    .contains(r.id),
                            onChanged: (v) => setState(() {
                              final key = kind == ResourceKind.worldBook
                                  ? 'worldBookIds'
                                  : 'regexIds';
                              final ids = List<String>.from(
                                _value![key] as List? ?? [],
                              );
                              if (v == true) {
                                ids.add(r.id);
                              } else {
                                ids.remove(r.id);
                              }
                              _value![key] = ids;
                            }),
                          ),
                      ],
                    ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('保存配置'),
                  ),
                ],
              );
            },
          ),
  );
}
