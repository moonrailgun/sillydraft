import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/services.dart';
import 'app/theme.dart';
import 'app/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(SillyDraftApp(services: await AppServices.open()));
  } catch (error) {
    runApp(_StartupError(error: error));
  }
}

/// Shown when the local library cannot be opened, before the real app exists.
class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: sdkMaterialTheme(Brightness.light),
    darkTheme: sdkMaterialTheme(Brightness.dark),
    localizationsDelegates: FLocalizations.localizationsDelegates,
    supportedLocales: FLocalizations.supportedLocales,
    builder: (context, child) =>
        FTheme(data: appTheme(Theme.brightnessOf(context)), child: child!),
    home: Builder(
      builder: (context) => AppScaffold(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FLucideIcons.circleAlert,
                  size: 40,
                  color: context.theme.colors.error,
                ),
                const SizedBox(height: 20),
                Text(
                  '暂时无法打开本地资料库',
                  style: context.theme.typography.body.lg.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(error.toString(), textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: main,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
