part of 'story_repository.dart';

extension UsageOperations on StoryRepository {
  /// Records one request on [connection]. A request with an [executionId]
  /// is recorded once: a remote reconnect retrieves the same job.
  Future<void> recordUsage({
    required ModelConnection connection,
    required String kind,
    String? purpose,
    String? branchId,
    String? executionId,
    int? inputTokens,
    int? outputTokens,
    bool estimated = false,
    double? costUsd,
    required CostSource source,
    Map<String, dynamic> usage = const {},
  }) => _write(
    () async {
      final book = branchId == null
          ? null
          : (await _rows(
              'SELECT novels.id, novels.title FROM novels '
              'JOIN branches ON branches.novel_id = novels.id '
              'WHERE branches.id = ?',
              [branchId],
            )).firstOrNull;
      await _execute(
        'INSERT OR IGNORE INTO usage_records (id,execution_id,created_at,connection_id,connection_name,protocol,model,kind,input_tokens,output_tokens,tokens_estimated,cost_usd,cost_source,usage_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        [
          const Uuid().v4(),
          executionId,
          DateTime.now().millisecondsSinceEpoch,
          connection.id,
          connection.name,
          connection.protocol.name,
          connection.model,
          kind,
          inputTokens,
          outputTokens,
          estimated ? 1 : 0,
          costUsd,
          source.name,
          jsonEncode({
            ...usage,
            // Local attribution survives deletion without changing upstream usage.
            'sillydraft': {
              'purpose': ?purpose,
              if (book != null) 'bookId': book['id'],
              if (book != null) 'bookTitle': book['title'],
            },
          }),
        ],
      );
    },
    // Not story content: views that never read it need not reload.
    tasksOnly: true,
  );

  /// Totals per local calendar month, newest first, labelled `2026-10`.
  Future<List<UsageTotal>> usageByMonth() => _usageTotals(
    "strftime('%Y-%m', created_at / 1000, 'unixepoch', 'localtime')",
    'label DESC',
  );

  /// Totals per local calendar day, oldest first, labelled `2026-10-19`.
  Future<List<UsageTotal>> usageByDay() => _usageTotals(
    "strftime('%Y-%m-%d', created_at / 1000, 'unixepoch', 'localtime')",
    'label ASC',
  );

  /// Totals per connection and model as they were named, costliest first.
  Future<List<UsageTotal>> usageByModel() => _usageTotals(
    "connection_name || ' · ' || model",
    'cost DESC, requests DESC',
  );

  /// Totals per feature, including requests too old to have attribution.
  Future<List<UsageTotal>> usageByTool() => _usageTotals(
    "CASE json_extract(usage_json, '\$.sillydraft.purpose') "
        "WHEN 'writing' THEN '正文生成' "
        "WHEN 'rewrite' THEN '正文改写' "
        "WHEN 'branches' THEN '分支构思' "
        "WHEN 'analysis' THEN '资料提取' "
        "WHEN 'agent' THEN '写作助手' "
        "WHEN 'sidecar' THEN '旁路整理' "
        "WHEN 'illustration' THEN '生图' "
        "WHEN 'compaction' THEN '上下文摘要' "
        "WHEN 'quality' THEN '审读与返修' "
        "WHEN 'title' THEN '标题生成' "
        "WHEN 'persona' THEN '人设生成' "
        "WHEN 'connectionTest' THEN '连接测试' "
        "ELSE CASE kind WHEN 'image' THEN '生图' ELSE '未分类工具' END END",
    'cost DESC, requests DESC, label',
  );

  /// Book IDs, not titles: two books with the same name remain separate.
  Future<List<UsageTotal>> usageByBook() => _usageTotals(
    "COALESCE((SELECT title FROM novels WHERE id = $_bookId), "
        "MAX(json_extract(usage_json, '\$.sillydraft.bookTitle')) || '（已删除）', "
        "'未归属书籍')",
    'cost DESC, requests DESC, label',
    groupBy: _bookId,
  );

  static const _bookId = "json_extract(usage_json, '\$.sillydraft.bookId')";

  Future<List<UsageTotal>> _usageTotals(
    String label,
    String order, {
    String groupBy = 'label',
  }) async => [
    for (final r in await _rows(
      'SELECT $label AS label, COUNT(*) AS requests, '
      'COALESCE(SUM(input_tokens), 0) AS input, '
      'COALESCE(SUM(output_tokens), 0) AS output, '
      'COALESCE(SUM(cost_usd), 0.0) AS cost, '
      'SUM(cost_usd IS NULL) AS unpriced, MAX(tokens_estimated) AS estimated, '
      "MAX(tokens_estimated AND cost_source = 'stPricing') AS cost_estimated "
      'FROM usage_records GROUP BY $groupBy ORDER BY $order',
    ))
      UsageTotal(
        label: r['label'] as String,
        requests: r['requests'] as int,
        inputTokens: r['input'] as int,
        outputTokens: r['output'] as int,
        cost: (r['cost'] as num).toDouble(),
        unpriced: r['unpriced'] as int,
        estimated: r['estimated'] == 1,
        costEstimated: r['cost_estimated'] == 1,
      ),
  ];
}
