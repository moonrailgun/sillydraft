import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../lore/lore_providers.dart';

class BranchComparisonScreen extends ConsumerWidget {
  const BranchComparisonScreen({
    super.key,
    required this.leftId,
    required this.rightId,
  });
  final String leftId, rightId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('分支比较')),
    body: AsyncView(
      value: ref.watch(storyProvider(leftId)),
      builder: (left) => AsyncView(
        value: ref.watch(storyProvider(rightId)),
        builder: (right) {
          final leftScenes = {for (final s in left.scenes) s.id: s},
              rightScenes = {for (final s in right.scenes) s.id: s};
          final ids = {...leftScenes.keys, ...rightScenes.keys};
          final changed = ids
              .where(
                (id) =>
                    leftScenes[id]?.revisionId != rightScenes[id]?.revisionId ||
                    leftScenes[id]?.title != rightScenes[id]?.title,
              )
              .toList();
          Widget panel(String title, String text) => Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 12),
                  SelectableText(text, style: const TextStyle(height: 1.8)),
                ],
              ),
            ),
          );
          final ll =
                  ref
                      .watch(loreProvider((branchId: leftId, sceneId: null)))
                      .value ??
                  <LoreEntry>[],
              rr =
                  ref
                      .watch(loreProvider((branchId: rightId, sceneId: null)))
                      .value ??
                  <LoreEntry>[];
          String describe(LoreEntry? e) => e == null
              ? '无此资料'
              : '${e.name} · ${certaintyLabels[e.certainty]}${e.deleted ? ' · 已归档' : ''}\n${e.content}';
          final loreIds = {...ll.map((e) => e.id), ...rr.map((e) => e.id)};
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${left.branch.name} ↔ ${right.branch.name}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                '正文不同的场景：${changed.length} · 左 ${left.scenes.length} 幕 / 右 ${right.scenes.length} 幕',
              ),
              for (final id in changed) ...[
                const SizedBox(height: 20),
                Text(
                  rightScenes[id]?.title ?? leftScenes[id]!.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                LayoutBuilder(
                  builder: (_, bounds) {
                    final a = panel(
                          left.branch.name,
                          leftScenes[id]?.content.text ?? '此分支无此场景',
                        ),
                        b = panel(
                          right.branch.name,
                          rightScenes[id]?.content.text ?? '此分支无此场景',
                        );
                    return bounds.maxWidth >= 800
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: a),
                              Expanded(child: b),
                            ],
                          )
                        : Column(children: [a, b]);
                  },
                ),
              ],
              const SizedBox(height: 28),
              Text('旁路资料', style: Theme.of(context).textTheme.titleLarge),
              for (final id in loreIds)
                Builder(
                  builder: (_) {
                    final a = ll.where((e) => e.id == id).firstOrNull,
                        b = rr.where((e) => e.id == id).firstOrNull;
                    if (a?.name == b?.name &&
                        a?.content == b?.content &&
                        a?.certainty == b?.certainty &&
                        a?.deleted == b?.deleted &&
                        a?.data.toString() == b?.data.toString()) {
                      return const SizedBox();
                    }
                    return ExpansionTile(
                      title: Text(b?.name ?? a!.name),
                      children: [
                        panel(left.branch.name, describe(a)),
                        panel(right.branch.name, describe(b)),
                      ],
                    );
                  },
                ),
            ],
          );
        },
      ),
    ),
  );
}
