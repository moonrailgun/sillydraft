import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../editor/editor_screen.dart';
import '../editor/workspace_screen.dart';

final _searchProvider = FutureProvider.autoDispose.family<List<_Match>, String>(
  (ref, query) async {
    ref.watch(repositoryChangesProvider);
    final repository = ref.watch(repositoryProvider);
    final matches = <_Match>[];
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return matches;
    for (final novel in await repository.listNovels(includeArchived: true)) {
      if (!ref.mounted) return [];
      if ('${novel.title} ${novel.synopsis}'.toLowerCase().contains(needle)) {
        matches.add(_Match(novel: novel, excerpt: novel.synopsis));
      }
      final story = await repository.getStory(novel.activeBranchId);
      for (final scene in story.scenes) {
        final text = scene.content.text.replaceAll('\ufffc', '〔插画〕');
        final index = text.toLowerCase().indexOf(needle);
        if (index >= 0 || scene.title.toLowerCase().contains(needle)) {
          // Slice by characters for display, preserving surrogate pairs.
          final prefix = index <= 0 ? '' : text.substring(0, index);
          final start = (prefix.runes.length - 24).clamp(0, text.runes.length);
          matches.add(
            _Match(
              novel: novel,
              scene: scene,
              branch: story.branch.name,
              excerpt: String.fromCharCodes(text.runes.skip(start).take(180)),
            ),
          );
        }
        if (matches.length >= 200) return matches;
      }
    }
    return matches;
  },
);

class _Match {
  const _Match({
    required this.novel,
    required this.excerpt,
    this.scene,
    this.branch,
  });
  final Novel novel;
  final Scene? scene;
  final String excerpt;
  final String? branch;
}

class GlobalSearchScreen extends ConsumerStatefulWidget {
  const GlobalSearchScreen({super.key});
  @override
  ConsumerState<GlobalSearchScreen> createState() => _SearchState();
}

class _SearchState extends ConsumerState<GlobalSearchScreen> {
  String _query = '';
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('搜索作品与正文')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: TextField(
                key: const Key('global-search-field'),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '搜索所有作品的当前分支',
                  prefixIcon: Icon(Icons.search),
                  helperText: '包含已归档作品；最多显示 200 条结果。',
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            Expanded(
              child: AsyncView(
                value: ref.watch(_searchProvider(_query)),
                builder: (matches) => matches.isEmpty
                    ? Center(
                        child: Text(
                          _query.trim().isEmpty ? '输入书名、场景名或正文内容' : '没有找到相关内容',
                        ),
                      )
                    : ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final match = matches[index];
                          return ListTile(
                            leading: Icon(
                              match.scene == null
                                  ? Icons.book_outlined
                                  : Icons.notes,
                            ),
                            title: Text(
                              '${match.novel.title}${match.scene == null ? '' : ' · ${match.scene!.title}'}${match.novel.archived ? '（已归档）' : ''}',
                            ),
                            subtitle: Text(
                              '${match.branch == null ? '' : '${match.branch}\n'}${match.excerpt}',
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => match.scene == null
                                    ? NovelWorkspace(novelId: match.novel.id)
                                    : EditorScreen(scene: match.scene!),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
