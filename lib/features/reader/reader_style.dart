import 'package:flutter/widgets.dart';

/// Page colours. Each pairs a background with a text colour that stays
/// comfortable for long reading, not just legible, and an amber for dialogue
/// after SillyTavern's quote colour (night uses ST's own), each at least 5:1
/// against its page.
enum ReaderTheme {
  paper('纸白', Color(0xfffbfaf7), Color(0xff34312e), Color(0xffa9520e)),
  sepia('羊皮纸', Color(0xfff1e8d7), Color(0xff3f362b), Color(0xff9a4709)),
  green('护眼', Color(0xffd4e7d1), Color(0xff2b3a2c), Color(0xff8c430a)),
  gray('灰调', Color(0xffe4e4e2), Color(0xff2f2f2f), Color(0xff964709)),
  night('夜间', Color(0xff20212a), Color(0xffc9c6bd), Color(0xffe18a24)),
  black('纯黑', Color(0xff000000), Color(0xff8f8f8a), Color(0xffb8742a));

  const ReaderTheme(this.label, this.background, this.foreground, this.quote);
  final String label;
  final Color background, foreground, quote;
  bool get dark => this == night || this == black;

  /// Faded text for italics, as ST greys them: the text colour taken a
  /// third of the way to the page.
  Color get italic => Color.lerp(foreground, background, .35)!;

  /// Selected text, tinted with the page's own text colour: the app
  /// theme's colour was near white on a light page in dark mode.
  Color get selection => foreground.withValues(alpha: .25);
}

/// Typefaces readers usually choose between. Each lists the common names of
/// that face on Apple, Windows, Android and Linux; whatever is installed wins.
enum ReaderFont {
  system('默认', null, []),
  serif('宋体', 'Songti SC', [
    'STSong',
    'Noto Serif CJK SC',
    'Noto Serif SC',
    'Source Han Serif SC',
    'SimSun',
    'serif',
  ]),
  sans('黑体', 'PingFang SC', [
    'Heiti SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'Microsoft YaHei',
    'sans-serif',
  ]),
  kai('楷体', 'Kaiti SC', ['STKaiti', 'KaiTi', 'AR PL UKai CN', 'serif']);

  const ReaderFont(this.label, this.family, this.fallback);
  final String label;
  final String? family;
  final List<String> fallback;
}

/// Everything the reader lets the author adjust, stored as one setting.
@immutable
final class ReaderStyle {
  const ReaderStyle({
    this.fontSize = 20,
    this.lineHeight = 1.9,
    this.paragraphSpacing = .6,
    this.letterSpacing = 0.5,
    this.margin = 28,
    this.indent = true,
    this.justify = true,
    this.theme = ReaderTheme.paper,
    this.autoNight = true,
    this.font = ReaderFont.serif,
    this.dim = 0,
    this.keepAwake = true,
    this.autoScrollSpeed = 40,
    this.highlightQuotes = true,
    this.dimItalics = true,
    this.autoDirections = true,
  });

  static const fontRange = (min: 12.0, max: 36.0);
  static const lineRange = (min: 1.2, max: 2.6);
  static const paragraphRange = (min: 0.0, max: 2.0);
  static const letterRange = (min: 0.0, max: 4.0);
  static const marginRange = (min: 8.0, max: 64.0);
  static const dimRange = (min: 0.0, max: .6);
  static const speedRange = (min: 10.0, max: 200.0);

  final double fontSize, lineHeight, letterSpacing, margin, dim;

  /// Space after each paragraph, in lines of body text.
  final double paragraphSpacing;
  final bool indent, justify, autoNight, keepAwake;
  final ReaderTheme theme;
  final ReaderFont font;

  /// Auto-scroll speed in logical pixels per second.
  final double autoScrollSpeed;

  /// Dialogue in quotes takes the theme's quote colour.
  final bool highlightQuotes;

  /// Italic text outside dialogue fades.
  final bool dimItalics;

  /// Reaching the end of the story proposes where it could go, when a model
  /// is set up for it.
  final bool autoDirections;

  /// The theme to paint with: night when the system is dark and the author
  /// reads on a light page with [autoNight] on.
  ReaderTheme effectiveTheme(Brightness platform) =>
      autoNight && platform == Brightness.dark && !theme.dark
      ? ReaderTheme.night
      : theme;

  ReaderStyle copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? letterSpacing,
    double? margin,
    bool? indent,
    bool? justify,
    ReaderTheme? theme,
    bool? autoNight,
    ReaderFont? font,
    double? dim,
    bool? keepAwake,
    double? autoScrollSpeed,
    bool? highlightQuotes,
    bool? dimItalics,
    bool? autoDirections,
  }) => ReaderStyle(
    fontSize: fontSize ?? this.fontSize,
    lineHeight: lineHeight ?? this.lineHeight,
    paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    margin: margin ?? this.margin,
    indent: indent ?? this.indent,
    justify: justify ?? this.justify,
    theme: theme ?? this.theme,
    autoNight: autoNight ?? this.autoNight,
    font: font ?? this.font,
    dim: dim ?? this.dim,
    keepAwake: keepAwake ?? this.keepAwake,
    autoScrollSpeed: autoScrollSpeed ?? this.autoScrollSpeed,
    highlightQuotes: highlightQuotes ?? this.highlightQuotes,
    dimItalics: dimItalics ?? this.dimItalics,
    autoDirections: autoDirections ?? this.autoDirections,
  );

  Map<String, Object> toJson() => {
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'letterSpacing': letterSpacing,
    'margin': margin,
    'indent': indent,
    'justify': justify,
    'theme': theme.name,
    'autoNight': autoNight,
    'font': font.name,
    'dim': dim,
    'keepAwake': keepAwake,
    'autoScrollSpeed': autoScrollSpeed,
    'highlightQuotes': highlightQuotes,
    'dimItalics': dimItalics,
    'autoDirections': autoDirections,
  };

  /// Reads a stored setting, keeping defaults for anything missing and
  /// clamping out-of-range values. The old `sepia`/`paper`/`night` names
  /// carry over.
  factory ReaderStyle.fromJson(Map<String, dynamic>? json) {
    const d = ReaderStyle();
    if (json == null) return d;
    double number(String key, double fallback, ({double min, double max}) r) =>
        ((json[key] as num?)?.toDouble() ?? fallback).clamp(r.min, r.max);
    T named<T extends Enum>(List<T> values, String key, T fallback) =>
        values.where((v) => v.name == json[key]).firstOrNull ?? fallback;
    return ReaderStyle(
      fontSize: number('fontSize', d.fontSize, fontRange),
      lineHeight: number('lineHeight', d.lineHeight, lineRange),
      paragraphSpacing: number(
        'paragraphSpacing',
        d.paragraphSpacing,
        paragraphRange,
      ),
      letterSpacing: number('letterSpacing', d.letterSpacing, letterRange),
      margin: number('margin', d.margin, marginRange),
      indent: json['indent'] as bool? ?? d.indent,
      justify: json['justify'] as bool? ?? d.justify,
      theme: named(ReaderTheme.values, 'theme', d.theme),
      autoNight: json['autoNight'] as bool? ?? d.autoNight,
      font: named(ReaderFont.values, 'font', d.font),
      dim: number('dim', d.dim, dimRange),
      keepAwake: json['keepAwake'] as bool? ?? d.keepAwake,
      autoScrollSpeed: number('autoScrollSpeed', d.autoScrollSpeed, speedRange),
      highlightQuotes: json['highlightQuotes'] as bool? ?? d.highlightQuotes,
      dimItalics: json['dimItalics'] as bool? ?? d.dimItalics,
      autoDirections: json['autoDirections'] as bool? ?? d.autoDirections,
    );
  }

  TextStyle body(Color color) => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    letterSpacing: letterSpacing,
    color: color,
    fontFamily: font.family,
    fontFamilyFallback: font.fallback,
  );

  @override
  bool operator ==(Object other) => other is ReaderStyle && _key == other._key;
  @override
  int get hashCode => _key.hashCode;
  String get _key => toJson().toString();
}
