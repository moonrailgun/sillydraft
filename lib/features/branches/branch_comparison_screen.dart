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
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '分支比较',
    body: AsyncView(
      value: ref.watch(storyProvider(leftId)),
      builder: (left) => AsyncView(
        value: ref.watch(storyProvider(rightId)),
        builder: (right) {
          final theme = context.theme;
          final leftChapters = {for (final s in left.chapters) s.id: s},
              rightChapters = {for (final s in right.chapters) s.id: s};
          final ids = {...leftChapters.keys, ...rightChapters.keys};
          final changed = ids
              .where(
                (id) =>
                    leftChapters[id]?.revisionId !=
                        rightChapters[id]?.revisionId ||
                    leftChapters[id]?.title != rightChapters[id]?.title,
              )
              .toList();
          Widget panel(String title, String text) => FCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: theme.typography.body.sm.copyWith(
                      color: theme.colors.mutedForeground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SelectableText(text, style: const TextStyle(height: 1.8)),
                ],
              ),
            ),
          );
          Widget pair(Widget a, Widget b) => LayoutBuilder(
            builder: (_, bounds) => bounds.maxWidth >= 800
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: a),
                      const SizedBox(width: 12),
                      Expanded(child: b),
                    ],
                  )
                : Column(children: [a, const SizedBox(height: 12), b]),
          );
          final ll =
                  ref
                      .watch(loreProvider((branchId: leftId, chapterId: null)))
                      .value ??
                  <LoreEntry>[],
              rr =
                  ref
                      .watch(loreProvider((branchId: rightId, chapterId: null)))
                      .value ??
                  <LoreEntry>[];
          String describe(LoreEntry? e) => e == null
              ? '无此资料'
              : '${e.name} · ${certaintyLabels[e.certainty]}${e.deleted ? ' · 已归档' : ''}\n${e.content}';
          final loreIds = {...ll.map((e) => e.id), ...rr.map((e) => e.id)};
          final heading = theme.typography.body.xl.copyWith(
            fontWeight: FontWeight.w600,
          );
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '${left.branch.name} ↔ ${right.branch.name}',
                style: heading,
              ),
              const SizedBox(height: 12),
              Text(
                '正文不同的章节：${changed.length} · 左 ${left.chapters.length} 章 / 右 ${right.chapters.length} 章',
              ),
              for (final id in changed) ...[
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    rightChapters[id]?.title ?? leftChapters[id]!.title,
                    style: theme.typography.body.md.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                pair(
                  panel(
                    left.branch.name,
                    leftChapters[id]?.content.text ?? '此分支无此章节',
                  ),
                  panel(
                    right.branch.name,
                    rightChapters[id]?.content.text ?? '此分支无此章节',
                  ),
                ),
              ],
              const SizedBox(height: 28),
              Text('旁路资料', style: heading),
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
                    return FAccordion(
                      children: [
                        FAccordionItem(
                          title: Text(b?.name ?? a!.name),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              panel(left.branch.name, describe(a)),
                              const SizedBox(height: 12),
                              panel(right.branch.name, describe(b)),
                            ],
                          ),
                        ),
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
