import '../model/lore.dart';

/// An approved, chapter-scoped visual baseline shared by a batch of pictures.
final class VisualReference {
  VisualReference({
    required this.kind,
    required this.name,
    required this.prompt,
    this.entry,
    this.assetId,
  });
  final LoreKind kind;
  final String name, prompt;
  LoreEntry? entry;
  String? assetId;
  String get key => entry?.id ?? '${kind.name}:$name';
  Map<String, dynamic> get preview => {
    'kind': kind.name,
    'name': name,
    'prompt': prompt,
    'loreId': ?entry?.id,
    'defaultAssetId': ?(entry?.data['images'] as List?)?.firstOrNull,
    'assetId': ?assetId,
    'create': assetId == null,
  };
}

const sceneFields = [
  'id',
  'time',
  'location',
  'weather',
  'lighting',
  'layout',
  'props',
  'characters',
];

/// Unknown facts must be explicit, never silently omitted from the image request.
Map<String, dynamic> validateImageScene(Object? value) {
  if (value is! Map<String, dynamic> ||
      value.keys.any((k) => !sceneFields.contains(k))) {
    throw const FormatException('请提供完整的场景上下文');
  }
  for (final key in sceneFields) {
    if (value[key] is! String ||
        (value[key] as String).trim().isEmpty ||
        (value[key] as String).length > 2000) {
      throw FormatException('场景缺少 $key；原文未交代时明确填写 unspecified');
    }
  }
  return {for (final key in sceneFields) key: (value[key] as String).trim()};
}

/// An existing scene is immutable; a real transition needs a different id.
void checkSceneContinuity(
  Map<String, dynamic> scene,
  Map<String, dynamic>? previous,
) {
  if (previous == null) return;
  for (final key in sceneFields.where((k) => k != 'characters')) {
    if (scene[key] != previous[key]) {
      throw FormatException('同一场景的 $key 与已确认描述冲突，请复用原描述；正文明确转场时使用新的场景 id');
    }
  }
}

void validateSceneReferences(
  Map<String, dynamic> scene,
  List<VisualReference> references,
) {
  for (final (field, kind) in [
    ('characters', LoreKind.character),
    ('location', LoreKind.location),
  ]) {
    if (!['unspecified', 'none'].contains(scene[field]) &&
        !references.any((r) => r.kind == kind)) {
      throw FormatException('场景包含 $field，请提供对应人物或地点的固定外观描述 subjects');
    }
  }
}

String visualPrompt(
  String prompt,
  List<VisualReference> references,
  Map<String, dynamic>? scene, {
  bool tags = false,
  List<String> imageLabels = const [],
}) {
  final facts = [
    if (scene != null)
      for (final key in sceneFields.where((k) => k != 'id'))
        if (!['unspecified', 'none'].contains(scene[key]))
          tags ? '${scene[key]}' : '$key: ${scene[key]}',
    for (final ref in references)
      tags ? ref.prompt : '${ref.kind.name} ${ref.name}: ${ref.prompt}',
    for (final (i, label) in imageLabels.indexed)
      'Reference image ${i + 1}: $label',
  ];
  if (facts.isEmpty) return prompt;
  return tags
      ? [prompt, ...facts].join(', ')
      : '$prompt\n\nCanonical visual context (takes precedence over conflicting shorthand above; preserve identity and architecture; scene facts fix layout, props, weather and light; explicit current clothing/state in the shot overrides reference defaults; change only the requested action and framing):\n${facts.join('\n')}';
}
