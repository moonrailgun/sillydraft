import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';
import 'package:material_ui/material_ui.dart' as mui;

import '../features/bookshelf/novel_start.dart';
import '../features/bookshelf/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/resources/resource_library_screen.dart';
import 'desktop_commands.dart';
import 'home_screen.dart';
import 'services.dart';
import 'theme.dart';
import 'widgets.dart' show showError;

class SillyDraftApp extends StatelessWidget {
  const SillyDraftApp({super.key, required this.services});
  final AppServices services;
  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [servicesProvider.overrideWithValue(services)],
    child: const _App(),
  );
}

class _App extends ConsumerStatefulWidget {
  const _App();
  @override
  ConsumerState<_App> createState() => _AppState();
}

class _AppState extends ConsumerState<_App> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  int _selectedDestination = 0;

  void _selectDestination(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _selectedDestination = index);
  }

  void _error(Object error) {
    final context = _navigator.currentContext;
    if (context != null) showError(context, '保存未完成：$error');
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    try {
      await ref.read(servicesProvider).flushDrafts();
      return AppExitResponse.exit;
    } catch (e) {
      _error(e);
      return AppExitResponse.cancel;
    }
  }

  Future<void> _command(AppCommand command) async {
    final navigator = _navigator.currentState;
    if (navigator == null) return;
    try {
      if (command == AppCommand.save) {
        await ref.read(servicesProvider).flushDrafts();
      } else if (command == AppCommand.create) {
        await showNovelStart(navigator.context);
      } else if (!navigator.canPop() &&
          (command == AppCommand.resources || command == AppCommand.settings)) {
        _selectDestination(
          command == AppCommand.resources
              ? HomeTab.resources
              : HomeTab.settings,
        );
      } else {
        final screen = switch (command) {
          AppCommand.search => const GlobalSearchScreen(),
          AppCommand.resources => const ResourceLibraryScreen(),
          _ => const SettingsScreen(),
        };
        await navigator.push(MaterialPageRoute<void>(builder: (_) => screen));
      }
    } catch (e) {
      if (mounted) _error(e);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(
        ref.read(servicesProvider).flushDrafts().catchError((Object e) {
          if (mounted) _error(e);
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(settingProvider('appearance')).value?['mode'];
    return MaterialApp(
      navigatorKey: _navigator,
      builder: (context, child) => mui.Theme(
        data: materialUiTheme(Theme.brightnessOf(context)),
        child: FTheme(
          data: appTheme(Theme.brightnessOf(context)),
          child: FToaster(
            child: FTooltipGroup(
              child: Overlay.wrap(
                child: DesktopCommands(invoke: _command, child: child!),
              ),
            ),
          ),
        ),
      ),
      title: 'SillyDraft',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      // The SDK Material delegates serve the editor and routes; forui's list
      // adds its own strings plus package:material_ui's.
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
        ...FLocalizations.localizationsDelegates,
      ],
      theme: sdkMaterialTheme(Brightness.light),
      darkTheme: sdkMaterialTheme(Brightness.dark),
      themeMode: mode == 'dark'
          ? ThemeMode.dark
          : mode == 'light'
          ? ThemeMode.light
          : ThemeMode.system,
      home: HomeScreen(
        selectedIndex: _selectedDestination,
        onDestinationSelected: _selectDestination,
      ),
    );
  }
}
