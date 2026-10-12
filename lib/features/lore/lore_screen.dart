import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import '../maps/map_screen.dart';
import '../maps/relationship_graph.dart';
import 'lore_edit_screen.dart';
import 'lore_providers.dart';
import 'variables_screen.dart';

class LoreScreen extends ConsumerStatefulWidget {
  const LoreScreen({super.key, required this.branchId, this.throughSceneId});
  final String branchId;
  final String? throughSceneId;
  @override
  ConsumerState<LoreScreen> createState() => _LoreState();
}

class _LoreState extends ConsumerState<LoreScreen> {
  late String? _through = widget.throughSceneId;
  LoreKind? _kind;
  int _tab = 0;
  bool _archived = false, _analyzing = false;
  String _query = '';
  Future<void> _edit({LoreEntry? entry, LoreKind? kind}) async {
    final story = await ref.read(repositoryProvider).getStory(widget.branchId);
    if (!mounted) return;
    final anchor = _through ?? story.scenes.lastOrNull?.id;
    if (entry?.kind == LoreKind.map && entry?.deleted == false) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => StoryMapScreen(entry: entry!, atSceneId: anchor),
        ),
      );
    } else {
      await Navigator.push<LoreEntry>(
        context,
        MaterialPageRoute(
          builder: (_) => LoreEditScreen(
            branchId: widget.branchId,
            entry: entry,
            atSceneId: anchor,
            kind: kind ?? _kind ?? LoreKind.world,
          ),
        ),
      );
    }
  }

  Future<void> _analyze() async {
    setState(() => _analyzing = true);
    try {
      final services = ref.read(servicesProvider),
          connection = await ref
              .read(servicesProvider)
              .connectionFor('analysis');
      if (connection == null) throw const FormatException('请先在模型设置里配置整理模型。');
      final task = await services.writing.analyze(
        branchId: widget.branchId,
        connection: connection,
      );
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Widget _list(List<LoreEntry> entries, {bool timeline = false}) {
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            '这里记录故事背后的人物、设定和线索。\n手动添加资料，或从正文整理后逐条采纳。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final entry = entries[i];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: Icon(
              entry.sourceStale
                  ? Icons.history_toggle_off
                  : entry.kind == LoreKind.character
                  ? Icons.person_outline
                  : entry.kind == LoreKind.foreshadow
                  ? Icons.visibility_outlined
                  : entry.kind == LoreKind.map
                  ? Icons.map_outlined
                  : Icons.notes,
            ),
            title: Text(entry.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                Text(
                  '${loreLabels[entry.kind]} · ${certaintyLabels[entry.certainty]}${entry.deleted ? ' · 已归档' : ''}${entry.sourceStale ? ' · 待复核' : ''}${timeline ? ' · ${loreStatusLabels[entry.data['status']] ?? '进行中'}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (entry.data['storyTime'] is String &&
                    (entry.data['storyTime'] as String).isNotEmpty)
                  Text(entry.data['storyTime'] as String),
                const SizedBox(height: 8),
                Text(
                  entry.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _edit(entry: entry),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = (branchId: widget.branchId, sceneId: _through),
        story = ref.watch(storyProvider(widget.branchId));
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('故事资料'),
          actions: [
            IconButton(
              tooltip: '从整部正文提取资料',
              onPressed: _analyzing ? null : _analyze,
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              tooltip: '故事变量',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => VariablesScreen(
                    branchId: widget.branchId,
                    sceneId: _through,
                  ),
                ),
              ),
              icon: const Icon(Icons.data_object),
            ),
          ],
          bottom: TabBar(
            onTap: (v) => setState(() => _tab = v),
            tabs: const [
              Tab(text: '资料'),
              Tab(text: '时间线'),
              Tab(text: '关系'),
              Tab(text: '地图'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: '添加资料',
          onPressed: () => _edit(
            kind: _tab == 2
                ? LoreKind.relationship
                : _tab == 3
                ? LoreKind.map
                : _tab == 1
                ? LoreKind.foreshadow
                : null,
          ),
          child: const Icon(Icons.add),
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: AsyncView(
                  value: story,
                  builder: (story) => DropdownButtonFormField<String>(
                    initialValue: _through,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '资料截至哪个故事位置'),
                    hint: const Text('当前故事末尾'),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('当前故事末尾'),
                      ),
                      for (final s in story.scenes)
                        DropdownMenuItem(
                          value: s.id,
                          child: Text(
                            s.title.isEmpty ? '未命名场景' : s.title,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _through = v),
                  ),
                ),
              ),
              Expanded(
                child: AsyncView(
                  value: ref.watch(loreProvider(scope)),
                  builder: (all) {
                    final active = all.where((e) => !e.deleted).toList(),
                        entries = all
                            .where(
                              (e) =>
                                  (_archived || !e.deleted) &&
                                  (_kind == null || e.kind == _kind) &&
                                  '${e.name} ${e.content}'.contains(_query),
                            )
                            .toList();
                    final timeline = active
                        .where(
                          (e) =>
                              e.kind == LoreKind.event ||
                              e.kind == LoreKind.foreshadow,
                        )
                        .toList();
                    final positions = {
                      for (final (i, s)
                          in (story.value?.scenes ?? <Scene>[]).indexed)
                        s.id: i,
                    };
                    timeline.sort(
                      (a, b) => (positions[a.atSceneId] ?? -1).compareTo(
                        positions[b.atSceneId] ?? -1,
                      ),
                    );
                    return TabBarView(
                      children: [
                        Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                              child: TextField(
                                decoration: const InputDecoration(
                                  hintText: '搜索资料',
                                  prefixIcon: Icon(Icons.search),
                                ),
                                onChanged: (v) => setState(() => _query = v),
                              ),
                            ),
                            SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 8,
                              ),
                              child: Row(
                                children: [
                                  ChoiceChip(
                                    label: const Text('全部'),
                                    selected: _kind == null,
                                    onSelected: (_) =>
                                        setState(() => _kind = null),
                                  ),
                                  for (final e in loreLabels.entries)
                                    Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: ChoiceChip(
                                        label: Text(e.value),
                                        selected: _kind == e.key,
                                        onSelected: (_) =>
                                            setState(() => _kind = e.key),
                                      ),
                                    ),
                                  const SizedBox(width: 8),
                                  FilterChip(
                                    label: const Text('包含归档'),
                                    selected: _archived,
                                    onSelected: (v) =>
                                        setState(() => _archived = v),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(child: _list(entries)),
                          ],
                        ),
                        _list(timeline, timeline: true),
                        RelationshipGraph(
                          key: ValueKey(scope),
                          entries: active,
                          onOpen: (entry) => _edit(entry: entry),
                        ),
                        _list(
                          active.where((e) => e.kind == LoreKind.map).toList(),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
