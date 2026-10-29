import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';

import '../../app/widgets.dart';
import 'reader_style.dart';

/// The reading settings panel. Changes apply to the page behind it as they
/// are made, so the author sees the result while adjusting.
Future<void> showReaderSettings(
  BuildContext context, {
  required ReaderStyle style,
  required ValueChanged<ReaderStyle> onChanged,
}) => showFSheet<void>(
  context: context,
  side: FLayout.btt,
  mainAxisMaxRatio: .62,
  // Keep the page visible: the point is to watch it change.
  style: FModalSheetStyleDelta.delta(
    barrierFilter: (_, animation) => ColorFilter.mode(
      Color.lerp(const Color(0x00000000), const Color(0x1F000000), animation)!,
      BlendMode.srcOver,
    ),
  ),
  builder: (context) => AppSheet(
    child: _ReaderSettings(style: style, onChanged: onChanged),
  ),
);

/// A forui slider over [min]..[max] that snaps to [divisions] steps and
/// reports values in that range, the way a divided Material slider did.
class ReaderSlider extends StatelessWidget {
  const ReaderSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.onChangeEnd,
    this.label,
    this.semanticLabel,
  });
  final double value, min, max;
  final int divisions;
  final ValueChanged<double> onChanged;

  /// Called when a drag, tap or key press settles on a value.
  final ValueChanged<double>? onChangeEnd;

  /// Shown above the thumb while it is dragged; none when null.
  final String? label;

  /// What assistive technology reads for a value; [label] by default.
  final String Function(double value)? semanticLabel;

  double _fraction(double v) =>
      max <= min ? 0 : ((v - min) / (max - min)).clamp(0.0, 1.0);

  double _snap(double fraction) =>
      (min + (fraction * divisions).round() * (max - min) / divisions).clamp(
        min,
        max,
      );

  String _semantics(double value) =>
      semanticLabel?.call(value) ?? label ?? value.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) => FSlider(
    control: FSliderControl.liftedContinuous(
      value: FSliderValue(max: _fraction(value.clamp(min, max))),
      stepPercentage: 1 / divisions,
      onChange: (v) {
        final next = _snap(v.max);
        if (next != value) onChanged(next);
      },
    ),
    tooltipControls: label == null
        ? const FSliderTooltipControls.disabled()
        : const FSliderTooltipControls(),
    tooltipBuilder: (_, _) => Text(label ?? ''),
    semanticFormatterCallback: (v) => _semantics(_snap(v.max)),
    semanticValueFormatterCallback: (f) => _semantics(_snap(f)),
    onEnd: onChangeEnd == null ? null : (v) => onChangeEnd!(_snap(v.max)),
  );
}

/// A small outlined button showing a glyph instead of an icon, labelled by
/// [tooltip] like an [IconAction].
class _GlyphAction extends StatelessWidget implements ActionLabel {
  const _GlyphAction({
    super.key,
    required this.glyph,
    required this.fontSize,
    required this.tooltip,
    required this.onPress,
  });
  final String glyph;
  final double fontSize;
  @override
  final String tooltip;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FTooltip(
    tipBuilder: (_, _) => Text(tooltip),
    child: FButton.icon(
      onPress: onPress,
      semanticsLabel: tooltip,
      child: Text(glyph, style: TextStyle(fontSize: fontSize, height: 1)),
    ),
  );
}

class _ReaderSettings extends StatefulWidget {
  const _ReaderSettings({required this.style, required this.onChanged});
  final ReaderStyle style;
  final ValueChanged<ReaderStyle> onChanged;
  @override
  State<_ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<_ReaderSettings> {
  late var _style = widget.style;

  // Callbacks build on [_style], not a value captured at build time, so two
  // changes in one frame both land.
  void _set(ReaderStyle style) {
    setState(() => _style = style);
    widget.onChanged(style);
  }

  Widget _section(String title, Widget child, {String? value}) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.typography.body.sm.copyWith(
                    color: theme.colors.foreground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (value != null)
                Text(
                  value,
                  style: theme.typography.body.xs.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }

  Widget _slider(
    double value,
    ({double min, double max}) range,
    int divisions,
    ValueChanged<double> onChanged, {
    required String label,
  }) => ReaderSlider(
    value: value,
    min: range.min,
    max: range.max,
    divisions: divisions,
    label: label,
    onChanged: onChanged,
  );

  Widget _backgrounds({required bool dark}) {
    final theme = context.theme;
    final colors = theme.colors;
    final selected = dark ? _style.darkTheme : _style.lightTheme;
    final title = dark ? '暗色模式背景' : '亮色模式背景';
    return _section(
      title,
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          for (final t in ReaderTheme.values.where((t) => t.dark == dark))
            FTooltip(
              tipBuilder: (_, _) => Text(t.label),
              child: FTappable(
                key: Key('reader-theme-${t.name}'),
                semanticsLabel: '$title ${t.label}',
                selected: selected == t,
                onPress: () => _set(
                  dark
                      ? _style.copyWith(darkTheme: t)
                      : _style.copyWith(lightTheme: t),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: t.background,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected == t ? colors.primary : colors.border,
                          width: selected == t ? 3 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '文',
                        style: TextStyle(color: t.foreground, fontSize: 15),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.label,
                      style: theme.typography.body.xs.copyWith(
                        color: colors.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _switch(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: FSwitch(
      leadingLabel: true,
      label: Text(title),
      description: subtitle == null ? null : Text(subtitle),
      value: value,
      onChange: onChanged,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = _style;
    final theme = context.theme;
    final colors = theme.colors;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '阅读设置',
                style: theme.typography.body.lg.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            FButton(
              variant: FButtonVariant.ghost,
              size: FButtonSizeVariant.sm,
              mainAxisSize: MainAxisSize.min,
              onPress: () => _set(const ReaderStyle()),
              child: const Text('恢复默认'),
            ),
          ],
        ),
        _switch(
          '隐藏 HTML',
          s.hideHtml,
          (v) => _set(_style.copyWith(hideHtml: v)),
          subtitle: '隐藏 HTML 界面和片段',
        ),
        _switch(
          '隐藏插图',
          s.hideImages,
          (v) => _set(_style.copyWith(hideImages: v)),
          subtitle: '隐藏正文中的插图',
        ),
        _section(
          '字号',
          Row(
            children: [
              _GlyphAction(
                key: const Key('reader-font-smaller'),
                glyph: 'A−',
                fontSize: 14,
                tooltip: '字号减小',
                onPress: s.fontSize <= ReaderStyle.fontRange.min
                    ? null
                    : () =>
                          _set(_style.copyWith(fontSize: _style.fontSize - 1)),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _slider(
                    s.fontSize,
                    ReaderStyle.fontRange,
                    24,
                    (v) => _set(_style.copyWith(fontSize: v.roundToDouble())),
                    label: '${s.fontSize.round()}',
                  ),
                ),
              ),
              _GlyphAction(
                key: const Key('reader-font-larger'),
                glyph: 'A+',
                fontSize: 18,
                tooltip: '字号增大',
                onPress: s.fontSize >= ReaderStyle.fontRange.max
                    ? null
                    : () =>
                          _set(_style.copyWith(fontSize: _style.fontSize + 1)),
              ),
            ],
          ),
          value: '${s.fontSize.round()}',
        ),
        _section(
          '字体',
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in ReaderFont.values)
                FButton(
                  variant: s.font == f
                      ? FButtonVariant.primary
                      : FButtonVariant.outline,
                  size: FButtonSizeVariant.sm,
                  selected: s.font == f,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => _set(_style.copyWith(font: f)),
                  child: Text(
                    f.label,
                    style: TextStyle(
                      fontFamily: f.family,
                      fontFamilyFallback: f.fallback,
                    ),
                  ),
                ),
            ],
          ),
        ),
        _section(
          '主题',
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mode in ThemeMode.values)
                ChoicePill(
                  key: Key('reader-mode-${mode.name}'),
                  label: switch (mode) {
                    ThemeMode.system => '跟随系统',
                    ThemeMode.light => '亮色',
                    ThemeMode.dark => '暗色',
                  },
                  selected: s.themeMode == mode,
                  onPress: () => _set(_style.copyWith(themeMode: mode)),
                ),
            ],
          ),
        ),
        _backgrounds(dark: false),
        _backgrounds(dark: true),
        _section(
          '亮度',
          Row(
            children: [
              Icon(
                FLucideIcons.sunDim,
                size: 20,
                color: colors.mutedForeground,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _slider(
                    // The slider reads as brightness: right is brighter.
                    ReaderStyle.dimRange.max - s.dim,
                    ReaderStyle.dimRange,
                    12,
                    (v) => _set(
                      _style.copyWith(dim: ReaderStyle.dimRange.max - v),
                    ),
                    label: '${(100 - s.dim * 100).round()}%',
                  ),
                ),
              ),
              Icon(FLucideIcons.sun, size: 20, color: colors.mutedForeground),
            ],
          ),
          value: s.dim == 0 ? '原始' : '调暗 ${(s.dim * 100).round()}%',
        ),
        _section(
          '行距',
          _slider(
            s.lineHeight,
            ReaderStyle.lineRange,
            14,
            (v) => _set(_style.copyWith(lineHeight: v)),
            label: s.lineHeight.toStringAsFixed(1),
          ),
          value: s.lineHeight.toStringAsFixed(1),
        ),
        _section(
          '段距',
          _slider(
            s.paragraphSpacing,
            ReaderStyle.paragraphRange,
            10,
            (v) => _set(_style.copyWith(paragraphSpacing: v)),
            label: s.paragraphSpacing.toStringAsFixed(1),
          ),
          value: s.paragraphSpacing == 0
              ? '无'
              : '${s.paragraphSpacing.toStringAsFixed(1)} 行',
        ),
        _section(
          '字间距',
          _slider(
            s.letterSpacing,
            ReaderStyle.letterRange,
            8,
            (v) => _set(_style.copyWith(letterSpacing: v)),
            label: s.letterSpacing.toStringAsFixed(1),
          ),
          value: s.letterSpacing.toStringAsFixed(1),
        ),
        _section(
          '页边距',
          _slider(
            s.margin,
            ReaderStyle.marginRange,
            14,
            (v) => _set(_style.copyWith(margin: v.roundToDouble())),
            label: '${s.margin.round()}',
          ),
          value: '${s.margin.round()}',
        ),
        const SizedBox(height: 14),
        _switch(
          '首行缩进',
          s.indent,
          (v) => _set(_style.copyWith(indent: v)),
          subtitle: '段首空两格',
        ),
        _switch('两端对齐', s.justify, (v) => _set(_style.copyWith(justify: v))),
        _switch(
          '对白高亮',
          s.highlightQuotes,
          (v) => _set(_style.copyWith(highlightQuotes: v)),
          subtitle: '引号内的对白用强调色显示',
        ),
        _switch(
          '斜体淡化',
          s.dimItalics,
          (v) => _set(_style.copyWith(dimItalics: v)),
          subtitle: '斜体（含 *星号* 包裹的文字）颜色变淡',
        ),
        _switch(
          '读到结尾自动构思走向',
          s.autoDirections,
          (v) => _set(_style.copyWith(autoDirections: v)),
          subtitle: '已配置整理模型时，读到全书末尾自动提出三种走向（会调用一次模型）',
        ),
        _switch(
          '阅读时屏幕常亮',
          s.keepAwake,
          (v) => _set(_style.copyWith(keepAwake: v)),
        ),
        _section(
          '自动滚动速度',
          _slider(
            s.autoScrollSpeed,
            ReaderStyle.speedRange,
            19,
            (v) => _set(_style.copyWith(autoScrollSpeed: v.roundToDouble())),
            label: '${s.autoScrollSpeed.round()}',
          ),
          value: '${s.autoScrollSpeed.round()}',
        ),
      ],
    );
  }
}
