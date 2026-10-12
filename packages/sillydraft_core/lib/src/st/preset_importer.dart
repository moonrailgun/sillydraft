import 'dart:convert';

import 'import_types.dart';

enum PresetKind {
  chat,
  promptPack,
  textCompletion,
  context,
  instruct,
  systemPrompt,
  reasoning,
  bundle,
  unknown,
}

final class PromptDefinition extends JsonSource {
  PromptDefinition._(
    super.raw, {
    required this.identifier,
    required this.name,
    required this.role,
    required this.content,
    required this.marker,
    required this.systemPrompt,
    required this.injectionPosition,
    required this.depth,
    required this.order,
    required this.triggers,
    required this.forbidOverrides,
  });
  final String identifier, name, role, content;
  final bool marker, systemPrompt, forbidOverrides;
  final int injectionPosition, depth, order;
  final List<String> triggers;

  factory PromptDefinition.fromJson(Map<String, dynamic> raw) {
    final id = stringField(raw, 'identifier');
    if (id.isEmpty) throw const FormatException('提示词缺少 identifier');
    return PromptDefinition._(
      raw,
      identifier: id,
      name: stringField(raw, 'name', fallback: id),
      role: stringField(raw, 'role', fallback: 'system'),
      content: stringField(raw, 'content'),
      marker: raw['marker'] == true,
      systemPrompt: raw['system_prompt'] == true,
      injectionPosition: intField(raw, 'injection_position', 0),
      depth: intField(raw, 'injection_depth', 4),
      order: intField(raw, 'injection_order', 100),
      triggers: stringList(raw['injection_trigger'], 'injection_trigger'),
      forbidOverrides: raw['forbid_overrides'] == true,
    );
  }
}

final class PromptOrderItem {
  const PromptOrderItem(this.identifier, this.enabled);
  final String identifier;
  final bool enabled;
}

final class PromptOrderGroup {
  PromptOrderGroup(this.characterId, List<PromptOrderItem> items)
    : items = List.unmodifiable(items);
  final int? characterId;
  final List<PromptOrderItem> items;
}

final class PresetSelectionRequired implements Exception {
  const PresetSelectionRequired();
  @override
  String toString() => '预设有角色专用顺序，请选择使用的顺序组';
}

final class ImportedPreset extends JsonSource {
  ImportedPreset._(
    super.raw, {
    required this.kind,
    required this.name,
    required this.prompts,
    required this.orderGroups,
    required this.parameters,
    required this.connectionFields,
    required this.parts,
    required this.diagnostics,
  });
  final PresetKind kind;
  final String name;
  final List<PromptDefinition> prompts;
  final List<PromptOrderGroup> orderGroups;
  final Map<String, dynamic> parameters;
  final Map<String, dynamic> connectionFields;
  final Map<String, ImportedPreset> parts;
  final List<CompatibilityDiagnostic> diagnostics;

  List<PromptOrderItem> selectOrder({int? characterId}) {
    if (characterId != null) {
      for (final group in orderGroups) {
        if (group.characterId == characterId) return group.items;
      }
      throw const PresetSelectionRequired();
    }
    for (final group in orderGroups) {
      if (group.characterId == 100001 ||
          (kind == PresetKind.promptPack && group.characterId == null)) {
        return group.items;
      }
    }
    if (orderGroups.isNotEmpty) throw const PresetSelectionRequired();
    return List.unmodifiable(
      prompts.map((p) => PromptOrderItem(p.identifier, true)),
    );
  }

  ImportedPreset withPrompt(PromptDefinition prompt) {
    final root = raw;
    final body = kind == PresetKind.promptPack
        ? jsonObject(root['data'], 'data')
        : root;
    body['prompts'] = [
      for (final p in prompts)
        if (p.identifier != prompt.identifier) p.raw,
      prompt.raw,
    ];
    return PresetImporter().decode(root, kindHint: kind);
  }
}

const _parameterKeys = {
  'temperature',
  'temp',
  'top_p',
  'top_k',
  'top_a',
  'min_p',
  'typical_p',
  'tfs',
  'frequency_penalty',
  'presence_penalty',
  'repetition_penalty',
  'rep_pen',
  'rep_pen_range',
  'rep_pen_slope',
  'rep_pen_decay',
  'freq_pen',
  'presence_pen',
  'openai_max_tokens',
  'openai_max_context',
  'max_tokens',
  'max_length',
  'max_context_length',
  'truncation_length',
  'seed',
  'stop',
  'stop_sequence',
  'banned_tokens',
  'logit_bias',
  'logit_bias_preset',
  'stream_openai',
  'streaming',
  'n',
  'min_length',
  'do_sample',
  'num_beams',
  'length_penalty',
  'early_stopping',
  'no_repeat_ngram_size',
  'encoder_rep_pen',
  'penalty_alpha',
  'skew',
  'epsilon_cutoff',
  'eta_cutoff',
  'temperature_last',
  'dynatemp',
  'min_temp',
  'max_temp',
  'dynatemp_exponent',
  'smoothing_factor',
  'smoothing_curve',
  'mirostat_mode',
  'mirostat_tau',
  'mirostat_eta',
  'samplers',
  'sampler_order',
  'sampler_priority',
  'grammar_string',
  'json_schema',
  'reasoning_effort',
  'include_reasoning',
  'continue_prefill',
  'assistant_prefill',
  'claude_assistant_prefill',
};
const _connectionKeys = {
  'reverse_proxy',
  'proxy_password',
  'custom_url',
  'custom_headers',
  'custom_include_headers',
  'custom_include_body',
  'custom_exclude_body',
  'api_key',
  'api_url',
  'server_url',
  'endpoint',
  'headers',
};

final class PresetImporter {
  const PresetImporter({this.maxBytes = 8 * 1024 * 1024});
  final int maxBytes;

  ImportedPreset decode(Map<String, dynamic> input, {PresetKind? kindHint}) {
    final encoded = jsonEncode(input);
    if (utf8.encode(encoded).length > maxBytes) {
      throw const FormatException('预设文件过大');
    }
    final raw = jsonDecode(encoded) as Map<String, dynamic>;
    final kind = kindHint ?? _detect(raw);
    final diagnostics = <CompatibilityDiagnostic>[];
    final parts = <String, ImportedPreset>{};
    if (kind == PresetKind.bundle) {
      const hints = {
        'context': PresetKind.context,
        'instruct': PresetKind.instruct,
        'sysprompt': PresetKind.systemPrompt,
        'preset': PresetKind.textCompletion,
        'reasoning': PresetKind.reasoning,
      };
      for (final e in hints.entries) {
        if (raw[e.key] != null) {
          parts[e.key] = decode(
            jsonObject(raw[e.key], e.key),
            kindHint: e.value,
          );
        }
      }
      if (raw['srw'] != null) {
        diagnostics.add(
          const CompatibilityDiagnostic('srw_unsupported', '聊天样式规则保留，尚未执行'),
        );
      }
    }
    final body = kind == PresetKind.promptPack
        ? jsonObject(raw['data'], 'data')
        : raw;
    final prompts = <PromptDefinition>[];
    if ([PresetKind.chat, PresetKind.promptPack].contains(kind)) {
      final entries = body['prompts'];
      if (entries != null && entries is! List) {
        throw const FormatException('prompts 必须是数组');
      }
      if (entries is List) {
        if (entries.length > 4096) throw const FormatException('提示词条目过多');
        for (final value in entries) {
          prompts.add(PromptDefinition.fromJson(jsonObject(value, 'prompts')));
        }
      }
      const legacy = {
        'main_prompt': 'main',
        'nsfw_prompt': 'nsfw',
        'jailbreak_prompt': 'jailbreak',
      };
      for (final e in legacy.entries) {
        if (body[e.key] is String && (body[e.key] as String).isNotEmpty) {
          final existing = prompts
              .where((p) => p.identifier == e.value)
              .firstOrNull;
          prompts.removeWhere((p) => p.identifier == e.value);
          prompts.add(
            PromptDefinition.fromJson({
              ...?existing?.raw,
              'identifier': e.value,
              'role': 'system',
              'system_prompt': true,
              'content': body[e.key],
            }),
          );
        }
      }
      if (entries == null) {
        for (final id in [
          'worldInfoBefore',
          'charDescription',
          'charPersonality',
          'scenario',
          'personaDescription',
          'worldInfoAfter',
          'dialogueExamples',
          'chatHistory',
        ]) {
          prompts.add(
            PromptDefinition.fromJson({
              'identifier': id,
              'marker': true,
              'role': 'system',
            }),
          );
        }
      }
    }
    final ids = <String>{};
    for (final prompt in prompts) {
      if (!ids.add(prompt.identifier)) {
        diagnostics.add(
          CompatibilityDiagnostic(
            'duplicate_prompt',
            '重复提示词标识：${prompt.identifier}',
            severity: DiagnosticSeverity.error,
          ),
        );
      }
      if (!['system', 'user', 'assistant'].contains(prompt.role)) {
        diagnostics.add(
          CompatibilityDiagnostic(
            'unsupported_role',
            '不支持提示词角色：${prompt.role}',
            severity: DiagnosticSeverity.error,
          ),
        );
      }
    }
    final groups = <PromptOrderGroup>[];
    final orders = body['prompt_order'];
    if (orders != null) {
      if (orders is! List) throw const FormatException('prompt_order 必须是数组');
      if (kind == PresetKind.promptPack) {
        groups.add(PromptOrderGroup(null, _order(orders)));
      } else {
        for (final value in orders) {
          final group = jsonObject(value, 'prompt_order');
          final items = group['order'];
          if (items is! List) throw const FormatException('顺序组缺少 order');
          groups.add(
            PromptOrderGroup(
              intField(group, 'character_id', 100001),
              _order(items),
            ),
          );
        }
      }
    }
    for (final group in groups) {
      final seen = <String>{};
      for (final item in group.items) {
        if (!ids.contains(item.identifier)) {
          diagnostics.add(
            CompatibilityDiagnostic(
              'unknown_prompt',
              '顺序引用不存在的提示词：${item.identifier}',
            ),
          );
        }
        if (!seen.add(item.identifier)) {
          diagnostics.add(
            CompatibilityDiagnostic(
              'duplicate_order',
              '顺序中重复引用：${item.identifier}',
              severity: DiagnosticSeverity.error,
            ),
          );
        }
      }
    }
    final connections = <String, dynamic>{
      for (final e in raw.entries)
        if (_connectionKeys.contains(e.key)) e.key: e.value,
    };
    if (connections.values.any((v) => v != null && v != '')) {
      diagnostics.add(
        const CompatibilityDiagnostic(
          'connection_not_applied',
          '导入连接字段未应用，继续使用已配置的模型连接',
        ),
      );
    }
    if (kind == PresetKind.unknown) {
      diagnostics.add(
        const CompatibilityDiagnostic(
          'unknown_preset',
          '未识别的预设格式；仅保留原始数据',
          severity: DiagnosticSeverity.error,
        ),
      );
    }
    return ImportedPreset._(
      raw,
      kind: kind,
      name: stringField(raw, 'name', fallback: '导入的预设'),
      prompts: List.unmodifiable(prompts),
      orderGroups: List.unmodifiable(groups),
      parameters: Map.unmodifiable({
        for (final e in body.entries)
          if (_parameterKeys.contains(e.key)) e.key: e.value,
      }),
      connectionFields: Map.unmodifiable(connections),
      parts: Map.unmodifiable(parts),
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  PresetKind _detect(Map<String, dynamic> raw) {
    if (raw['data'] is Map &&
        (raw['data'] as Map).containsKey('prompts') &&
        raw.containsKey('version')) {
      return PresetKind.promptPack;
    }
    if ([
      'instruct',
      'context',
      'sysprompt',
      'preset',
      'reasoning',
    ].any((k) => raw[k] is Map)) {
      return PresetKind.bundle;
    }
    if ([
      'prompts',
      'prompt_order',
      'main_prompt',
      'nsfw_prompt',
      'jailbreak_prompt',
      'chat_completion_source',
      'openai_max_tokens',
    ].any(raw.containsKey)) {
      return PresetKind.chat;
    }
    if (raw.containsKey('story_string')) return PresetKind.context;
    if (raw.containsKey('input_sequence') ||
        raw.containsKey('output_sequence')) {
      return PresetKind.instruct;
    }
    if (raw.containsKey('prefix') && raw.containsKey('suffix')) {
      return PresetKind.reasoning;
    }
    if (raw.containsKey('content')) return PresetKind.systemPrompt;
    if (['temp', 'rep_pen', 'top_k', 'temperature'].any(raw.containsKey)) {
      return PresetKind.textCompletion;
    }
    return PresetKind.unknown;
  }

  List<PromptOrderItem> _order(List<dynamic> raw) => raw.map((value) {
    final item = jsonObject(value, 'order');
    return PromptOrderItem(
      stringField(item, 'identifier'),
      item['enabled'] == true,
    );
  }).toList();
}
