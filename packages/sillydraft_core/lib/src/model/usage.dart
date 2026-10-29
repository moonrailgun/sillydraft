/// Where a request's cost came from.
enum CostSource {
  /// The response reported it.
  upstream,

  /// ST's model-list prices for the source, times the tokens.
  stPricing,

  /// Other or unavailable; any estimate is described in the usage metadata.
  unknown,
}

/// Requests summed under one day, month, or connection and model.
final class UsageTotal {
  const UsageTotal({
    required this.label,
    required this.requests,
    required this.inputTokens,
    required this.outputTokens,
    required this.cost,
    required this.unpriced,
    required this.estimated,
    required this.costEstimated,
    this.includesCodexConversation = false,
  });
  final String label;
  final int requests, inputTokens, outputTokens;

  /// US dollars, summed over the priced requests only.
  final double cost;

  /// Requests without a cost.
  final int unpriced;

  /// Whether any token count in it is an estimate.
  final bool estimated;

  /// Whether [cost] includes estimated tokens or an API-equivalent cost.
  final bool costEstimated;

  /// Some image requests only include their conversation-model estimate.
  final bool includesCodexConversation;
}
