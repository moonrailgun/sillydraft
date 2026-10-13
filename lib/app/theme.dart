import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' as mui;

/// Inter (forui's face) has no CJK glyphs, so Chinese text falls back to the
/// platform's own Chinese UI fonts instead of a random system font.
const _cjkFallback = [
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Noto Sans SC',
  'Source Han Sans SC',
  'WenQuanYi Micro Hei',
];

/// Phones and tablets get forui's touch sizing; desktops get the denser
/// desktop sizing.
bool get touchPlatform => const {
  TargetPlatform.android,
  TargetPlatform.iOS,
  TargetPlatform.fuchsia,
}.contains(defaultTargetPlatform);

final _themes = <Brightness, FThemeData>{};

/// The app's forui theme: the neutral palette with Chinese font fallback.
FThemeData appTheme(Brightness brightness) =>
    _themes.putIfAbsent(brightness, () {
      final colors = brightness == Brightness.dark
          ? FColors.neutralDark
          : FColors.neutralLight;
      final touch = touchPlatform;
      final face = FTypeface.inherit(
        colors: colors,
        touch: touch,
        fontFamilyFallback: _cjkFallback,
      );
      return FThemeData(
        colors: colors,
        touch: touch,
        typography: FTypography(display: face, body: face),
        debugLabel: 'SillyDraft ${brightness.name}',
      );
    });

final _uiThemes = <Brightness, mui.ThemeData>{};

/// forui renders its text fields through package:material_ui, so the forui
/// subtree gets that package's theme derived from the forui theme.
mui.ThemeData materialUiTheme(Brightness brightness) => _uiThemes.putIfAbsent(
  brightness,
  () => appTheme(brightness).toApproximateMaterialTheme(),
);

final _sdkThemes = <Brightness, ThemeData>{};

/// The SDK Material theme for what still renders through
/// package:flutter/material (the rich-text editor, routes, selection menus),
/// colored from the same forui palette so nothing looks out of place.
ThemeData sdkMaterialTheme(Brightness brightness) =>
    _sdkThemes.putIfAbsent(brightness, () {
      final c = appTheme(brightness).colors;
      final scheme = ColorScheme(
        brightness: brightness,
        primary: c.primary,
        onPrimary: c.primaryForeground,
        secondary: c.secondary,
        onSecondary: c.secondaryForeground,
        error: c.error,
        onError: c.errorForeground,
        surface: c.background,
        onSurface: c.foreground,
        onSurfaceVariant: c.mutedForeground,
        surfaceContainerLowest: c.background,
        surfaceContainerLow: c.muted,
        surfaceContainer: c.muted,
        surfaceContainerHigh: c.secondary,
        surfaceContainerHighest: c.secondary,
        outline: c.border,
        outlineVariant: c.border,
      );
      return ThemeData(
        useMaterial3: true,
        brightness: brightness,
        colorScheme: scheme,
        scaffoldBackgroundColor: c.background,
        canvasColor: c.background,
        dividerColor: c.border,
        splashFactory: NoSplash.splashFactory,
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: c.primary,
          selectionColor: c.primary.withValues(alpha: .2),
        ),
        fontFamilyFallback: _cjkFallback,
      );
    });
