import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sillydraft/app/theme.dart';
import 'package:sillydraft/app/widgets.dart';

/// A bare app for widget tests that mount a single screen: forui needs its
/// theme, toaster and localizations above every page, as the real app has.
Widget testHost(Widget home, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: sdkMaterialTheme(brightness),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        ...FLocalizations.localizationsDelegates,
      ],
      supportedLocales: FLocalizations.supportedLocales,
      builder: (context, child) => FTheme(
        data: appTheme(brightness),
        child: FToaster(child: FTooltipGroup(child: child!)),
      ),
      home: home,
    );
