import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import '../maps/map_screen.dart';
import '../maps/relationship_graph.dart';
import 'lore_edit_screen.dart';
import 'lore_providers.dart';
import 'sidecar.dart';
import 'variables_screen.dart';

class LoreScreen extends ConsumerStatefulWidget {
  const LoreScreen({
    super.key,
    required this.branchId,
    this.throughChapterId,
    this.embedded = false,
  });
  final String branchId;
  final String? throughChapterId;
  final bool embedded;
  @override
  ConsumerState<LoreScreen> createState() => _LoreState();
}

const _tabLabels = ['资料', '时间线', '关系', '地图'];

class _LoreState extends ConsumerState<LoreScreen> {
  late String? _through = widget.throughChapterId;
  LoreKind? _kind;
  int _tab = 0;
  bool _archived = false, _analyzing = false;
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit({LoreEntry? entry, LoreKind? kind}) async {
    final story = await ref.read(repositoryProvider).getStory(widget.branchId);
    if (!mounted) return;
    final anchor = _through ?? story.chapters.lastOrNull?.id;
    if (entry?.kind == LoreKind.map && entry?.deleted == false) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => StoryMapScreen(entry: entry!, atChapterId: anchor),
        ),
      );
    } else {
      await Navigator.push<LoreEntry>(
        context,
        MaterialPageRoute(
          builder: (_) => LoreEditScreen(
            branchId: widget.branchId,
            entry: entry,
            atChapterId: anchor,
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

  /// A header action: forui header styling on a full page, a plain icon
  /// button when the workspace hosts this screen without a header.
  Widget _action(IconData icon, String tooltip, VoidCallback? onPress) =>
      widget.embedded
      ? IconAction(icon: icon, tooltip: tooltip, onPress: onPress)
      : HeaderIconAction(icon: icon, tooltip: tooltip, onPress: onPress);

  Widget _list(
    List<LoreEntry> entries, {
    bool timeline = false,
    Map<String, String> titles = const {},
  }) {
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
        final theme = context.theme;
        return FTile(
          prefix: Icon(
            entry.sourceStale
                ? FLucideIcons.history
                : entry.kind == LoreKind.character
                ? FLucideIcons.user
                : entry.kind == LoreKind.foreshadow
                ? FLucideIcons.eye
                : entry.kind == LoreKind.map
                ? FLucideIcons.map
                : FLucideIcons.notebookText,
          ),
          title: Text(entry.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              Text(
                '${loreLabels[entry.kind]} · ${certaintyLabels[entry.certainty]}${entry.deleted ? ' · 已归档' : ''}${entry.sourceStale ? ' · 待复核' : ''}${timeline ? ' · ${loreStatusLabels[entry.data['status']] ?? '进行中'}' : ''}${entry.provenance['type'] == 'sidecar' ? ' · ${switch (titles[entry.provenance['chapterId']]) {
                        final String t => '$t · ',
                        _ => '',
                      }}旁路整理' : ''}',
                overflow: TextOverflow.visible,
                style: theme.typography.body.xs.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
              if (entry.data['storyTime'] is String &&
                  (entry.data['storyTime'] as String).isNotEmpty)
                Text(
                  entry.data['storyTime'] as String,
                  overflow: TextOverflow.visible,
                ),
              const SizedBox(height: 8),
              Text(entry.content, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
          suffix: const Icon(FLucideIcons.chevronRight),
          onPress: () => _edit(entry: entry),
        );
      },
    );
  }

  Widget _page(List<LoreEntry> all, StorySnapshot? story, LoreScope scope) {
    final active = all.where((e) => !e.deleted).toList();
    final titles = {
      for (final c in story?.chapters ?? const <Chapter>[]) c.id: c.title,
    };
    switch (_tab) {
      case 1:
        final timeline = active
            .where(
              (e) => e.kind == LoreKind.event || e.kind == LoreKind.foreshadow,
            )
            .toList();
        final positions = {
          for (final (i, s) in (story?.chapters ?? <Chapter>[]).indexed)
            s.id: i,
        };
        timeline.sort(
          (a, b) => (positions[a.atChapterId] ?? -1).compareTo(
            positions[b.atChapterId] ?? -1,
          ),
        );
        return _list(timeline, timeline: true, titles: titles);
      case 2:
        return RelationshipGraph(
          key: ValueKey(scope),
          entries: active,
          onOpen: (entry) => _edit(entry: entry),
        );
      case 3:
        return _list(
          active.where((e) => e.kind == LoreKind.map).toList(),
          titles: titles,
        );
    }
    final entries = all
        .where(
          (e) =>
              (_archived || !e.deleted) &&
              (_kind == null || e.kind == _kind) &&
              '${e.name} ${e.content}'.contains(_query),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: FTextField(
            control: FTextFieldControl.managed(
              controller: _search,
              onChange: (v) {
                if (v.text != _query) setState(() => _query = v.text);
              },
            ),
            hint: '搜索资料',
            prefixBuilder: (context, style, variants) =>
                FTextField.prefixIconBuilder(
                  context,
                  style,
                  variants,
                  const Icon(FLucideIcons.search),
                ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              ChoicePill(
                label: '全部',
                selected: _kind == null,
                onPress: () => setState(() => _kind = null),
              ),
              for (final e in loreLabels.entries)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ChoicePill(
                    label: e.value,
                    selected: _kind == e.key,
                    onPress: () => setState(() => _kind = e.key),
                  ),
                ),
              const SizedBox(width: 8),
              ChoicePill(
                label: '包含归档',
                selected: _archived,
                onPress: () => setState(() => _archived = !_archived),
              ),
            ],
          ),
        ),
        Expanded(child: _list(entries, titles: titles)),
      ],
    );
  }

  /// Runs the sidecar again on the chapter this page is looking from.
  Future<void> _resync(StorySnapshot story) async {
    try {
      final chapterId = _through ?? story.chapters.lastOrNull?.id;
      if (chapterId == null) throw const FormatException('还没有章节可以整理');
      final task = await startSidecar(
        ref.read(servicesProvider),
        branchId: widget.branchId,
        chapterId: chapterId,
        manual: true,
      );
      if (task != null && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = (branchId: widget.branchId, chapterId: _through),
        story = ref.watch(storyProvider(widget.branchId));
    return PageScaffold(
      title: '故事资料',
      embedded: widget.embedded,
      actions: [
        _action(
          FLucideIcons.sparkles,
          '从整部正文提取资料',
          _analyzing ? null : _analyze,
        ),
        _action(
          FLucideIcons.refreshCw,
          '重新整理本章',
          story.value == null ? null : () => _resync(story.value!),
        ),
        _action(
          FLucideIcons.braces,
          '故事变量',
          () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => VariablesScreen(
                branchId: widget.branchId,
                chapterId: _through,
              ),
            ),
          ),
        ),
      ],
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        child: FTabs(
          control: FTabControl.lifted(
            index: _tab,
            onChange: (v) => setState(() => _tab = v),
          ),
          children: [
            for (final label in _tabLabels)
              FTabEntry(label: Text(label), child: const SizedBox.shrink()),
          ],
        ),
      ),
      floatingActionButton: FloatingAction(
        icon: FLucideIcons.plus,
        label: '添加资料',
        onPress: () => _edit(
          kind: _tab == 2
              ? LoreKind.relationship
              : _tab == 3
              ? LoreKind.map
              : _tab == 1
              ? LoreKind.foreshadow
              : null,
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: AsyncView(
                value: story,
                builder: (story) {
                  String chapterTitle(Chapter s) =>
                      s.title.isEmpty ? '未命名章节' : s.title;
                  return FSelect<String>.rich(
                    label: const Text('资料截至哪个故事位置'),
                    hint: '当前故事末尾',
                    control: FSelectControl<String>.lifted(
                      value: _through ?? '',
                      onChange: (v) => setState(
                        () => _through = v == null || v.isEmpty ? null : v,
                      ),
                    ),
                    format: (id) => id.isEmpty
                        ? '当前故事末尾'
                        : story.chapters
                                  .where((s) => s.id == id)
                                  .map(chapterTitle)
                                  .firstOrNull ??
                              '未命名章节',
                    children: [
                      FSelectItem<String>(
                        title: const Text('当前故事末尾'),
                        value: '',
                      ),
                      for (final s in story.chapters)
                        FSelectItem<String>(
                          title: Text(
                            chapterTitle(s),
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: s.id,
                        ),
                    ],
                  );
                },
              ),
            ),
            Expanded(
              child: AsyncView(
                value: ref.watch(loreProvider(scope)),
                builder: (all) => _page(all, story.value, scope),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
