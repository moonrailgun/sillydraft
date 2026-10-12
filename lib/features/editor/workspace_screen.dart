import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../bookshelf/novel_dialog.dart';
import '../reader/reader_screen.dart';
import 'editor_screen.dart';
import '../agent/agent_screen.dart';

final novelProvider = FutureProvider.family<Novel, String>((ref, id) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).getNovel(id);
});

class NovelWorkspace extends ConsumerStatefulWidget {
  const NovelWorkspace({super.key, required this.novelId});
  final String novelId;
  @override
  ConsumerState<NovelWorkspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends ConsumerState<NovelWorkspace> {
  String? _selected;
  void _edit(Scene scene) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => EditorScreen(scene: scene)),
  );
  Future<void> _addChapter(StorySnapshot story) async {
    final name = await askText(
      context,
      title: '新增章节',
      initial: '第${story.chapters.length + 1}章',
    );
    if (name == null || !mounted) return;
    try {
      await ref
          .read(repositoryProvider)
          .createChapter(branchId: story.branch.id, title: name);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addScene(StorySnapshot story, String? chapterId) async {
    if (chapterId == null) return;
    final name = await askText(context, title: '新增场景', initial: '新的场景');
    if (name == null || !mounted) return;
    try {
      final scene = await ref
          .read(repositoryProvider)
          .createScene(
            branchId: story.branch.id,
            chapterId: chapterId,
            title: name,
          );
      if (mounted) {
        setState(() => _selected = scene.id);
        _edit(scene);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AsyncView(
    value: ref.watch(novelProvider(widget.novelId)),
    builder: (novel) => AsyncView(
      value: ref.watch(storyProvider(novel.activeBranchId)),
      builder: _buildStory,
    ),
  );

  Widget _buildStory(StorySnapshot story) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final goal =
        ref.watch(settingProvider('goal/${story.novel.id}')).value?['words']
            as int? ??
        0;
    final selected =
        story.scenes.where((s) => s.id == _selected).firstOrNull ??
        story.scenes.firstOrNull;
    final outline = ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          story.novel.genre,
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
        const SizedBox(height: 8),
        Text(
          story.novel.title,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        Text(
          '${countCharacters(story.text)} 字 · ${story.chapters.length} 章 · ${story.branch.name}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (goal > 0) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: (int.parse(countCharacters(story.text)) / goal).clamp(0, 1),
            semanticsLabel: '写作目标进度',
          ),
          const SizedBox(height: 6),
          Text('目标 $goal 字', style: Theme.of(context).textTheme.bodySmall),
        ],
        if (story.novel.synopsis.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              story.novel.synopsis,
              style: TextStyle(
                height: 1.6,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: Text(
                '正文目录',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton(
              onPressed: () => _addChapter(story),
              tooltip: '新增章节',
              icon: const Icon(Icons.playlist_add_rounded),
            ),
          ],
        ),
        if (story.chapters.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('先创建一个章节，开始你的故事。'),
          ),
        for (final chapter in story.chapters)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(
                      chapter.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    trailing: PopupMenuButton<String>(
                      tooltip: '章节操作',
                      onSelected: (value) async {
                        if (value == 'add') {
                          _addScene(story, chapter.id);
                        } else {
                          final name = await askText(
                            context,
                            title: '章节名称',
                            initial: chapter.title,
                          );
                          if (name != null) {
                            await ref
                                .read(repositoryProvider)
                                .renameChapter(
                                  branchId: story.branch.id,
                                  chapterId: chapter.id,
                                  title: name,
                                );
                          }
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'add', child: Text('新增场景')),
                        PopupMenuItem(value: 'rename', child: Text('重命名章节')),
                      ],
                    ),
                  ),
                  for (final scene in story.scenesInChapter(chapter.id))
                    ListTile(
                      selected: wide && selected?.id == scene.id,
                      selectedTileColor: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: .35),
                      leading: const Icon(Icons.notes_rounded, size: 20),
                      title: Text(scene.title.isEmpty ? '未命名场景' : scene.title),
                      subtitle: Text(
                        '${countCharacters(scene.content.text)} 字',
                      ),
                      trailing: IconButton(
                        tooltip: '编辑正文',
                        icon: const Icon(Icons.edit_outlined, size: 19),
                        onPressed: () => _edit(scene),
                      ),
                      onTap: () {
                        if (wide) {
                          setState(() => _selected = scene.id);
                        } else {
                          _edit(scene);
                        }
                      },
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 90),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('作品工作区'),
        actions: [
          IconButton(
            tooltip: '创作助手',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => AgentScreen(
                  branchId: story.branch.id,
                  sceneId: selected?.id,
                ),
              ),
            ),
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
          IconButton(
            key: const Key('open-reader'),
            tooltip: '阅读',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => ReaderScreen(branchId: story.branch.id),
              ),
            ),
            icon: const Icon(Icons.chrome_reader_mode_outlined),
          ),
          IconButton(
            tooltip: '作品信息',
            onPressed: () => showNovelDialog(context, novel: story.novel),
            icon: const Icon(Icons.more_horiz_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: wide
            ? Row(
                children: [
                  SizedBox(width: 320, child: outline),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: selected == null
                        ? const Center(child: Text('选择一个场景'))
                        : Padding(
                            padding: const EdgeInsets.all(40),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        selected.title,
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall,
                                      ),
                                    ),
                                    FilledButton.icon(
                                      onPressed: () => _edit(selected),
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        size: 18,
                                      ),
                                      label: const Text('编辑正文'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 32),
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      selected.content.text.trim().isEmpty
                                          ? '这一幕，等待你的第一句话。'
                                          : selected.content.text,
                                      style: const TextStyle(
                                        fontSize: 18,
                                        height: 1.9,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ],
              )
            : outline,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => story.chapters.isEmpty
            ? _addChapter(story)
            : _addScene(story, selected?.chapterId ?? story.chapters.last.id),
        icon: const Icon(Icons.add),
        label: Text(story.chapters.isEmpty ? '新增章节' : '新增场景'),
      ),
    );
  }
}
