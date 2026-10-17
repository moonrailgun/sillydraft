part of 'story_repository.dart';

extension UsageOperations on StoryRepository {
  /// Records one request on [connection]. A request with an [executionId]
  /// is recorded once: a remote reconnect retrieves the same job.
  Future<void> recordUsage({
    required ModelConnection connection,
    required String kind,
    String? executionId,
    int? inputTokens,
    int? outputTokens,
    bool estimated = false,
    double? costUsd,
    required CostSource source,
    Map<String, dynamic> usage = const {},
  }) => _write(
    () => _execute(
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
        jsonEncode(usage),
      ],
    ),
    // Not story content: views that never read it need not reload.
    tasksOnly: true,
  );

  /// Totals per local calendar month, newest first, labelled `2026-10`.
  Future<List<UsageTotal>> usageByMonth() => _usageTotals(
    "strftime('%Y-%m', created_at / 1000, 'unixepoch', 'localtime')",
    'label DESC',
  );

  /// Totals per connection and model as they were named, costliest first.
  Future<List<UsageTotal>> usageByModel() => _usageTotals(
    "connection_name || ' · ' || model",
    'cost DESC, requests DESC',
  );

  Future<List<UsageTotal>> _usageTotals(String label, String order) async => [
    for (final r in await _rows(
      'SELECT $label AS label, COUNT(*) AS requests, '
      'COALESCE(SUM(input_tokens), 0) AS input, '
      'COALESCE(SUM(output_tokens), 0) AS output, '
      'COALESCE(SUM(cost_usd), 0.0) AS cost, '
      'SUM(cost_usd IS NULL) AS unpriced, MAX(tokens_estimated) AS estimated, '
      "MAX(tokens_estimated AND cost_source = 'stPricing') AS cost_estimated "
      'FROM usage_records GROUP BY label ORDER BY $order',
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
