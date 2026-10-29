import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

part 'usage_chart.dart';

const _codexCostNote = 'Codex 对话模型估算，未含生图工具费';

final usageProvider =
    FutureProvider<
      ({
        List<UsageTotal> months,
        List<UsageTotal> models,
        List<UsageTotal> tools,
        List<UsageTotal> books,
        List<UsageTotal> days,
      })
    >((ref) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider);
      return (
        months: await repo.usageByMonth(),
        models: await repo.usageByModel(),
        tools: await repo.usageByTool(),
        books: await repo.usageByBook(),
        days: await repo.usageByDay(),
      );
    });

/// ST shows three decimals for OpenRouter and four for the others.
String dollars(double cost) =>
    '\$${cost.toStringAsFixed(cost >= 1 || cost == 0 ? 2 : 4)}';

/// The settings line: all-time and this month's cost, and what is not in it.
({String title, String? note}) usageSummary(List<UsageTotal> months) {
  if (months.isEmpty) return (title: '还没有模型请求', note: null);
  final now = DateTime.now();
  final current = '${now.year}-${now.month.toString().padLeft(2, '0')}';
  final total = months.fold(0.0, (sum, m) => sum + m.cost);
  final month = months.where((m) => m.label == current).firstOrNull;
  final unpriced = months.fold(0, (sum, m) => sum + m.unpriced);
  final estimated = months.any((m) => m.costEstimated) ? '≈' : '';
  final notes = [
    if (months.any((m) => m.includesCodexConversation)) _codexCostNote,
    if (unpriced > 0) '另有 $unpriced 次请求没有价格',
  ];
  return (
    title:
        '累计 $estimated${dollars(total)} · 本月 '
        '${month?.costEstimated == true ? '≈' : ''}${dollars(month?.cost ?? 0)}',
    note: notes.isEmpty ? null : notes.join('\n'),
  );
}

class UsageScreen extends ConsumerWidget {
  const UsageScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    Widget group(String label, List<UsageTotal> totals) => FTileGroup(
      label: Text(label),
      children: [
        for (final t in totals)
          FTile(
            title: Text(
              t.label,
              overflow: TextOverflow.visible,
              softWrap: true,
            ),
            subtitle: Text(
              '${t.requests} 次${t.unpriced == 0 ? '' : '（${t.unpriced} 次无价格）'}'
              ' · 输入 ${t.estimated ? '≈' : ''}${t.inputTokens}'
              ' · 输出 ${t.estimated ? '≈' : ''}${t.outputTokens} token'
              '${t.includesCodexConversation ? '\n$_codexCostNote' : ''}',
              overflow: TextOverflow.visible,
              softWrap: true,
            ),
            suffix: Text(
              t.unpriced == t.requests
                  ? '无价格'
                  : '${t.costEstimated ? '≈' : ''}${dollars(t.cost)}',
            ),
          ),
      ],
    );
    return PageScaffold(
      title: '用量与成本',
      body: ContentLayout(
        maxWidth: 800,
        builder: (_, inset) => AsyncView(
          value: ref.watch(usageProvider),
          builder: (usage) => ListView(
            padding: inset + const EdgeInsets.all(24),
            children: [
              if (usage.months.isEmpty)
                const Text('还没有模型请求。每次请求结束后会记在这里。')
              else ...[
                _UsageChart(days: usage.days),
                const SizedBox(height: 24),
                group('按月', usage.months),
                const SizedBox(height: 24),
                group('按工具', usage.tools),
                const SizedBox(height: 24),
                group('按书籍', usage.books),
                const SizedBox(height: 24),
                group('按连接与模型', usage.models),
              ],
              const SizedBox(height: 16),
              Text(
                '工具按正文生成、写作助手、生图等用途分类。工具与书籍均为累计统计；历史记录缺少用途时列为“未分类工具”，未记录书籍或全局工具的请求列为“未归属书籍”。\n\n'
                '金额为美元。优先使用上游返回的成本；没有时，OpenRouter、ElectronHub、Chutes 按 SillyTavern 的做法用模型列表单价乘 token 数。Codex 生图按已知模型的标准 API 单价估算对话费用，标为“≈”，未含生图工具费，也不代表订阅实际扣费；未知模型或用量不完整时仍显示“无价格”。其余没有价格的请求不计入金额。文本请求缺少 token 数或输出后中断时，token 按字数估算并标为“≈”。',
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
