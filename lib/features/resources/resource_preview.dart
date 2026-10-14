import 'package:flutter/material.dart' show SelectionArea;
import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

/// A section title with an optional muted note after it.
Widget previewHeading(BuildContext context, String title, [String? note]) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          text: title,
          style: context.theme.typography.body.md.copyWith(
            fontWeight: FontWeight.w600,
          ),
          children: [
            if (note != null)
              TextSpan(
                text: '  $note',
                style: context.theme.typography.body.sm.copyWith(
                  fontWeight: FontWeight.normal,
                  color: context.theme.colors.mutedForeground,
                ),
              ),
          ],
        ),
      ),
    );

/// One row of a [FoldGroup].
class FoldItem {
  const FoldItem(
    this.id,
    this.title,
    this.body, {
    this.note,
    this.details,
    this.enabled,
    this.mono = false,
  });
  final String id, title, body;

  /// A muted line above [body], such as an entry's keywords.
  final String? note;
  final String? details;

  /// Whether the row is on; null shows no state icon.
  final bool? enabled;
  final bool mono;
}

/// A tile group that participates in the page's lazy scroll layout.
class SliverTileGroup extends StatelessWidget {
  const SliverTileGroup({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) {
    final style = FTileGroupStyleData.of(context);
    final radius = context.theme.style.borderRadius.md;
    return DecoratedSliver(
      decoration: style.decoration,
      sliver: SliverPadding(
        padding: style.decoration.padding,
        sliver: SliverList.builder(
          itemCount: itemCount,
          itemBuilder: (context, index) => FInheritedItemData.merge(
            styles: FVariants.raw(
              style.tileStyles.base,
              style.tileStyles.variants,
            ),
            divider: FItemDivider.indented,
            dividerColor: style.dividerColor,
            dividerWidth: style.dividerWidth,
            index: index,
            last: index == itemCount - 1,
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.only(
                topLeft: index == 0 ? radius.topLeft : Radius.zero,
                topRight: index == 0 ? radius.topRight : Radius.zero,
                bottomLeft: index == itemCount - 1
                    ? radius.bottomLeft
                    : Radius.zero,
                bottomRight: index == itemCount - 1
                    ? radius.bottomRight
                    : Radius.zero,
              ),
              child: itemBuilder(context, index),
            ),
          ),
        ),
      ),
    );
  }
}

/// Read-only sliver rows whose text folds to two lines until tapped.
class FoldGroup extends StatefulWidget {
  const FoldGroup(this.items, {super.key});
  final List<FoldItem> items;
  @override
  State<FoldGroup> createState() => _FoldGroupState();
}

class _FoldGroupState extends State<FoldGroup> {
  final _open = <String>{};

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = TextStyle(color: theme.colors.mutedForeground);
    return SliverTileGroup(
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        final item = widget.items[index];
        final open = _open.contains(item.id);
        final body = item.body.trim().isEmpty ? '（空）' : item.body.trim();
        return FTile(
          key: ValueKey('fold-${item.id}'),
          prefix: item.enabled == null
              ? null
              : Icon(
                  item.enabled!
                      ? FLucideIcons.circleCheck
                      : FLucideIcons.circle,
                  color: item.enabled! ? null : theme.colors.mutedForeground,
                ),
          title: Text(item.title, style: item.enabled == false ? muted : null),
          subtitle: Text.rich(
            TextSpan(
              children: [
                if (item.note != null)
                  TextSpan(text: '${item.note}\n', style: muted),
                TextSpan(
                  // Folded rows lay out a slice, not a whole HTML greeting.
                  text: open || body.length <= 400
                      ? body
                      : body.substring(0, 400),
                  style: item.mono
                      ? const TextStyle(fontFamily: 'monospace')
                      : null,
                ),
              ],
            ),
            maxLines: open ? null : 2,
            softWrap: true,
            overflow: open ? TextOverflow.visible : TextOverflow.ellipsis,
          ),
          details: item.details == null ? null : Text(item.details!),
          onPress: () => setState(() {
            if (!_open.remove(item.id)) _open.add(item.id);
          }),
        );
      },
    );
  }
}

const _cardFields = {
  'description': '描述',
  'personality': '性格',
  'scenario': '场景',
  'mes_example': '对话示例',
  'system_prompt': '系统提示词',
  'post_history_instructions': '历史后指令',
  'creator_notes': '作者备注',
};

/// Slivers showing a card's settings, greetings, lorebook and regex.
class CharacterPreview extends StatelessWidget {
  const CharacterPreview(this.raw, {super.key});

  /// A V1 card root or a V2/V3 document.
  final Map<String, dynamic> raw;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final data = raw['spec'] != null && raw['data'] is Map<String, dynamic>
        ? raw['data'] as Map<String, dynamic>
        : raw;
    String text(String key) =>
        data[key] is String ? (data[key] as String).trim() : '';
    final tags = [
      if (data['tags'] is List)
        for (final t in data['tags'] as List)
          if (t is String && t.trim().isNotEmpty) t.trim(),
    ];
    final meta = [
      if (text('creator').isNotEmpty) '作者 ${text('creator')}',
      if (text('character_version').isNotEmpty)
        '版本 ${text('character_version')}',
    ];
    final fields = [
      for (final MapEntry(:key, :value) in _cardFields.entries)
        if (text(key).isNotEmpty) FoldItem(key, value, text(key)),
    ];
    final greetings = [
      text('first_mes'),
      if (data['alternate_greetings'] is List)
        for (final g in data['alternate_greetings'] as List)
          if (g is String) g,
    ];
    WorldBook? book;
    try {
      if (data['character_book'] is Map<String, dynamic>) {
        book = WorldBook.fromJson(
          data['character_book'] as Map<String, dynamic>,
        );
      }
    } on FormatException {
      // Shown in the raw view; the preview leaves it out.
    }
    final rules = DisplayContext.regexRulesOf(data['extensions']);
    const gap = SliverToBoxAdapter(child: SizedBox(height: 24));
    return SliverMainAxisGroup(
      slivers: [
        if (tags.isNotEmpty || meta.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final tag in tags)
                  FBadge(variant: FBadgeVariant.secondary, child: Text(tag)),
                if (meta.isNotEmpty)
                  Text(
                    meta.join(' · '),
                    style: theme.typography.body.sm.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
                  ),
              ],
            ),
          ),
          gap,
        ],
        if (fields.isNotEmpty) ...[
          SliverToBoxAdapter(child: previewHeading(context, '设定')),
          FoldGroup(fields),
          gap,
        ],
        if (greetings.any((g) => g.trim().isNotEmpty)) ...[
          SliverToBoxAdapter(
            child: previewHeading(context, '开场白', '共 ${greetings.length} 条'),
          ),
          FoldGroup([
            for (final (i, g) in greetings.indexed)
              FoldItem('greeting-$i', i == 0 ? '开场白' : '备用开场 $i', g),
          ]),
          gap,
        ],
        if (book != null && book.entries.isNotEmpty) ...[
          WorldBookPreview(book, title: '角色书'),
          gap,
        ],
        if (rules.isNotEmpty) RegexPreview(rules),
      ],
    );
  }
}

String _position(WorldBookEntry e) => switch (e.position) {
  0 => '角色前',
  1 => '角色后',
  2 => '作者注前',
  3 => '作者注后',
  4 => '深度 ${e.depth}',
  5 => '示例前',
  6 => '示例后',
  _ => '位置 ${e.position}',
};

/// Slivers showing a world book's entries in file order.
class WorldBookPreview extends StatelessWidget {
  const WorldBookPreview(this.book, {super.key, this.title = '条目'});
  final WorldBook book;
  final String title;
  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: previewHeading(
          context,
          title,
          '启用 ${book.entries.where((e) => e.enabled).length} / ${book.entries.length}',
        ),
      ),
      if (book.entries.isNotEmpty)
        FoldGroup([
          for (final (i, e) in book.entries.indexed)
            FoldItem(
              'entry-$i',
              e.comment.trim().isNotEmpty
                  ? e.comment.trim()
                  : e.keys.isNotEmpty
                  ? e.keys.join('、')
                  : '条目 ${e.id}',
              e.content,
              note: e.keys.isEmpty ? null : '关键词：${e.keys.join('、')}',
              details: '${e.constant ? '常驻 · ' : ''}${_position(e)}',
              enabled: e.enabled,
            ),
        ]),
    ],
  );
}

const _placements = {1: '用户输入', 2: 'AI 输出', 3: '快捷命令', 5: '世界书', 6: '推理'};

/// Slivers showing what each ST regex finds, what it writes, and where.
class RegexPreview extends StatelessWidget {
  const RegexPreview(this.rules, {super.key});
  final List<Map<String, dynamic>> rules;

  /// The rules of a regex resource: one script, or a `scripts` bundle.
  static List<Map<String, dynamic>> rulesOf(Map<String, dynamic> raw) =>
      raw['scripts'] is List
      ? [
          for (final rule in raw['scripts'] as List)
            if (rule is Map<String, dynamic>) rule,
        ]
      : [raw];

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: previewHeading(
          context,
          '正则脚本',
          '启用 ${rules.where((r) => r['disabled'] != true).length} / ${rules.length}',
        ),
      ),
      FoldGroup([
        for (final (i, rule) in rules.indexed)
          FoldItem(
            'regex-$i',
            rule['scriptName'] is String &&
                    (rule['scriptName'] as String).trim().isNotEmpty
                ? (rule['scriptName'] as String).trim()
                : '正则 ${i + 1}',
            '${rule['findRegex'] ?? ''}\n→ ${rule['replaceString'] ?? ''}',
            details: [
              if (rule['placement'] is List)
                for (final p in rule['placement'] as List) ?_placements[p],
              if (rule['markdownOnly'] == true) '仅显示',
              if (rule['promptOnly'] == true) '仅提示词',
            ].join('、'),
            enabled: rule['disabled'] != true,
            mono: true,
          ),
      ]),
    ],
  );
}

/// A foldable tree of JSON: objects and arrays open on tap, strings show
/// their real line breaks and fold when long.
class JsonTreeView extends StatelessWidget {
  const JsonTreeView(this.value, {super.key});
  final Object? value;
  @override
  Widget build(BuildContext context) => SelectionArea(
    child: DefaultTextStyle.merge(
      style: context.theme.typography.body.sm.copyWith(
        fontFamily: 'monospace',
        color: context.theme.colors.foreground,
      ),
      child: _JsonNode(null, value, depth: 0),
    ),
  );
}

class _JsonNode extends StatefulWidget {
  const _JsonNode(this.name, this.value, {required this.depth});
  final String? name;
  final Object? value;
  final int depth;
  @override
  State<_JsonNode> createState() => _JsonNodeState();
}

class _JsonNodeState extends State<_JsonNode> {
  /// Containers start open near the root unless they are large; strings
  /// start folded.
  late bool _open = switch (widget.value) {
    final Map<String, dynamic> m => widget.depth < 2 && m.length <= 100,
    final List<dynamic> l => widget.depth < 2 && l.length <= 100,
    _ => false,
  };

  void _toggle() => setState(() => _open = !_open);

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    final muted = TextStyle(color: colors.mutedForeground);
    final name = widget.name == null
        ? null
        : TextSpan(text: '${widget.name}: ', style: muted);
    final value = widget.value;
    if (value is Map || value is List) {
      final children = value is Map
          ? [for (final e in value.entries) ('${e.key}', e.value)]
          : [for (final (i, v) in (value as List).indexed) ('$i', v)];
      final summary = value is Map
          ? '{ ${children.length} 项 }'
          : '[ ${children.length} 项 ]';
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTappable(
            onPress: children.isEmpty ? null : _toggle,
            child: Row(
              children: [
                Icon(
                  _open ? FLucideIcons.chevronDown : FLucideIcons.chevronRight,
                  size: 14,
                  color: colors.mutedForeground,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        ?name,
                        TextSpan(text: summary, style: muted),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_open && children.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 6, top: 2, bottom: 2),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: colors.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (key, child) in children)
                    _JsonNode(key, child, depth: widget.depth + 1),
                ],
              ),
            ),
        ],
      );
    }
    final accent = colors.brightness == Brightness.dark
        ? const Color(0xFF7AB8FF)
        : const Color(0xFF1F6FC5);
    final text = value is String
        ? value.replaceAll('\r\n', '\n')
        : '${value ?? 'null'}';
    final long =
        value is String &&
        (text.length > 300 || '\n'.allMatches(text).length > 4);
    final folded = long && !_open;
    final leaf = Padding(
      padding: const EdgeInsets.only(left: 18, top: 1, bottom: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                ?name,
                TextSpan(
                  text: text.isEmpty
                      ? '""'
                      : folded
                      ? text.substring(0, 300.clamp(0, text.length))
                      : text,
                  style: value is String ? null : TextStyle(color: accent),
                ),
              ],
            ),
            maxLines: folded ? 5 : null,
            overflow: folded ? TextOverflow.ellipsis : null,
          ),
          if (long)
            Text(folded ? '展开全部 · ${text.length} 字' : '收起', style: muted),
        ],
      ),
    );
    return long ? FTappable(onPress: _toggle, child: leaf) : leaf;
  }
}
