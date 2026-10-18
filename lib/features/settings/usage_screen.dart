import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

part 'usage_chart.dart';

final usageProvider =
    FutureProvider<
      ({
        List<UsageTotal> months,
        List<UsageTotal> models,
        List<UsageTotal> days,
      })
    >((ref) async {
      ref.watch(repositoryChangesProvider);
      final repo = ref.watch(repositoryProvider);
      return (
        months: await repo.usageByMonth(),
        models: await repo.usageByModel(),
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
  final month = months.where((m) => m.label == current).firstOrNull?.cost ?? 0;
  final unpriced = months.fold(0, (sum, m) => sum + m.unpriced);
  final estimated = months.any((m) => m.costEstimated) ? '≈' : '';
  return (
    title: '累计 $estimated${dollars(total)} · 本月 ${dollars(month)}',
    note: unpriced == 0 ? null : '另有 $unpriced 次请求没有价格',
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
            title: Text(t.label),
            subtitle: Text(
              '${t.requests} 次${t.unpriced == 0 ? '' : '（${t.unpriced} 次无价格）'}'
              ' · 输入 ${t.estimated ? '≈' : ''}${t.inputTokens}'
              ' · 输出 ${t.estimated ? '≈' : ''}${t.outputTokens} token',
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
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: AsyncView(
            value: ref.watch(usageProvider),
            builder: (usage) => ListView(
              padding: const EdgeInsets.all(24),
              children: [
                if (usage.months.isEmpty)
                  const Text('还没有模型请求。每次请求结束后会记在这里。')
                else ...[
                  _UsageChart(days: usage.days),
                  const SizedBox(height: 24),
                  group('按月', usage.months),
                  const SizedBox(height: 24),
                  group('按连接与模型', usage.models),
                ],
                const SizedBox(height: 16),
                Text(
                  '金额为美元。上游返回了成本就用上游的；没有时，OpenRouter、ElectronHub、Chutes 按 SillyTavern 的做法用模型列表单价乘 token 数；其余请求只记 token，算作“无价格”，不计入金额。上游没返回 token 数，或请求中途失败、取消时，token 按字数估算，标为“≈”。',
                  style: theme.typography.body.sm.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
