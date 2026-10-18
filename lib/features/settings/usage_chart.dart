part of 'usage_screen.dart';

enum _UsageMetric {
  cost('成本'),
  tokens('Token'),
  requests('调用次数');

  const _UsageMetric(this.label);
  final String label;

  double value(UsageTotal? day) => switch (this) {
    cost => day?.cost ?? 0,
    tokens => ((day?.inputTokens ?? 0) + (day?.outputTokens ?? 0)).toDouble(),
    requests => (day?.requests ?? 0).toDouble(),
  };

  String format(double value) => switch (this) {
    cost => dollars(value),
    tokens => '${value.toInt()} token',
    requests => '${value.toInt()} 次',
  };

  String describe(UsageTotal? day) {
    if (day == null) return '无请求';
    if (this == cost && day.unpriced == day.requests) return '无价格';
    final estimated = this == cost
        ? day.costEstimated
        : this == tokens && day.estimated;
    return '${estimated ? '≈' : ''}${format(value(day))}'
        '${this == cost && day.unpriced > 0 ? ' · ${day.unpriced} 次无价格' : ''}';
  }
}

class _UsageChart extends StatefulWidget {
  const _UsageChart({required this.days});
  final List<UsageTotal> days;

  @override
  State<_UsageChart> createState() => _UsageChartState();
}

class _UsageChartState extends State<_UsageChart> {
  _UsageMetric _metric = _UsageMetric.cost;
  int _selected = 29;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final colors = theme.colors;
    final now = DateTime.now();
    // Calendar arithmetic keeps the slots aligned across daylight saving changes.
    final dates = List.generate(
      30,
      (i) => DateTime(
        now.year,
        now.month,
        now.day - 29 + i,
      ).toIso8601String().substring(0, 10),
    );
    final byDate = {for (final day in widget.days) day.label: day};
    final days = [for (final date in dates) byDate[date]];
    final values = days.map(_metric.value).toList();
    final maximum = values.fold(0.0, (max, v) => v > max ? v : max);
    final muted = theme.typography.body.xs.copyWith(
      color: colors.mutedForeground,
    );

    return FCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '近 30 天',
            style: theme.typography.body.lg.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '每日${_metric.label}${_metric == _UsageMetric.cost ? '（美元）' : ''}',
            style: muted,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final metric in _UsageMetric.values)
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  variant: _metric == metric
                      ? FButtonVariant.primary
                      : FButtonVariant.outline,
                  onPress: () => setState(() => _metric = metric),
                  child: Text(metric.label),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text(_metric.format(maximum), style: muted),
          const SizedBox(height: 4),
          SizedBox(
            height: 160,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (var i = 0; i < 3; i++)
                      Container(height: 1, color: colors.border),
                  ],
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < days.length; i++)
                      Expanded(
                        child: Semantics(
                          label: '${dates[i]} · ${_metric.describe(days[i])}',
                          selected: i == _selected,
                          button: true,
                          child: FTooltip(
                            tipBuilder: (_, _) => Text(
                              '${dates[i]} · ${_metric.describe(days[i])}',
                            ),
                            child: FTappable(
                              key: ValueKey('usage-day-${dates[i]}'),
                              onPress: () => setState(() => _selected = i),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                color: i == _selected ? colors.secondary : null,
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  width: double.infinity,
                                  height: maximum == 0
                                      ? 0
                                      : 160 * values[i] / maximum,
                                  decoration: BoxDecoration(
                                    color: i == _selected
                                        ? colors.primary
                                        : colors.primary.withValues(alpha: 0.6),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text('0', style: muted),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(dates.first.substring(5), style: muted),
              Text(dates[14].substring(5), style: muted),
              Text('今日', style: muted),
            ],
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              '${_selected == 29 ? '今日' : dates[_selected]} · ${_metric.describe(days[_selected])}',
            ),
          ),
          const SizedBox(height: 4),
          Text('点击柱子查看当天数据 · Token 为输入与输出合计', style: muted),
        ],
      ),
    );
  }
}
