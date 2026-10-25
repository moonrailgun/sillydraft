import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

class ParagraphComparison extends StatefulWidget {
  const ParagraphComparison({
    super.key,
    required this.beforeTitle,
    required this.afterTitle,
    required this.before,
    required this.after,
  });

  final String beforeTitle, afterTitle, before, after;

  @override
  State<ParagraphComparison> createState() => _ParagraphComparisonState();
}

class _ParagraphComparisonState extends State<ParagraphComparison> {
  late List<ParagraphChange> _changes;
  final _selected = <int>{};
  final _expanded = <ParagraphChange>{};

  @override
  void initState() {
    super.initState();
    _changes = compareParagraphs(widget.before, widget.after);
  }

  @override
  void didUpdateWidget(ParagraphComparison oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.before != widget.before || oldWidget.after != widget.after) {
      _changes = compareParagraphs(widget.before, widget.after);
      _selected.clear();
      _expanded.clear();
    }
  }

  Future<void> _copy() async {
    var index = 0;
    final text = StringBuffer();
    for (final change in _changes) {
      for (final paragraph in change.paragraphs) {
        if (_selected.contains(index++)) text.write(paragraph);
      }
    }
    try {
      await Clipboard.setData(ClipboardData(text: text.toString()));
      if (mounted) toast(context, '已复制选中片段');
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final removed = _changes
        .where((c) => c.kind == ParagraphChangeKind.removed)
        .fold(0, (n, c) => n + c.paragraphs.length);
    final added = _changes
        .where((c) => c.kind == ParagraphChangeKind.added)
        .fold(0, (n, c) => n + c.paragraphs.length);
    var index = 0;
    final groups = <Widget>[];
    for (final change in _changes) {
      groups.add(const SizedBox(height: 12));
      groups.add(_group(change, index));
      index += change.paragraphs.length;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${widget.beforeTitle} → ${widget.afterTitle}',
          style: theme.typography.body.md.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          removed == 0 && added == 0 ? '正文文字相同' : '删除 $removed 段 · 新增 $added 段',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FButton(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: _selected.isEmpty ? null : _copy,
              prefix: const Icon(FLucideIcons.copy),
              child: const Text('复制选中片段'),
            ),
            Text(
              '已选 ${_selected.length} 段 · 按显示顺序复制',
              style: theme.typography.body.sm.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ],
        ),
        ...groups,
      ],
    );
  }

  Widget _group(ParagraphChange change, int start) {
    final theme = context.theme;
    Widget paragraphs() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < change.paragraphs.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                label: '选择第 ${start + i + 1} 段',
                child: FCheckbox(
                  key: ValueKey('paragraph-select-${start + i}'),
                  value: _selected.contains(start + i),
                  onChange: (value) => setState(() {
                    if (value) {
                      _selected.add(start + i);
                    } else {
                      _selected.remove(start + i);
                    }
                  }),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  change.paragraphs[i]
                          .replaceFirst(RegExp(r'\r?\n$'), '')
                          .isEmpty
                      ? '（空段落）'
                      : change.paragraphs[i].replaceFirst(
                          RegExp(r'\r?\n$'),
                          '',
                        ),
                  style: theme.typography.body.md.copyWith(height: 1.8),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    if (change.kind == ParagraphChangeKind.unchanged) {
      return FAccordion(
        key: ObjectKey(change),
        control: FAccordionControl.lifted(
          expanded: (_) => _expanded.contains(change),
          onChange: (_, expanded) => setState(() {
            if (expanded) {
              _expanded.add(change);
            } else {
              _expanded.remove(change);
            }
          }),
        ),
        children: [
          FAccordionItem(
            title: Text('相同内容 · ${change.paragraphs.length} 段'),
            child: _expanded.contains(change) ? paragraphs() : const SizedBox(),
          ),
        ],
      );
    }
    final removed = change.kind == ParagraphChangeKind.removed;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: removed ? const Color(0x18cb655f) : const Color(0x184a996d),
        border: Border(
          left: BorderSide(
            width: 3,
            color: removed ? const Color(0xffcb655f) : const Color(0xff4a996d),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              removed
                  ? '删除 · ${widget.beforeTitle}'
                  : '新增 · ${widget.afterTitle}',
              style: theme.typography.body.sm.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            paragraphs(),
          ],
        ),
      ),
    );
  }
}
