import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/bookshelf/bookshelf_screen.dart';
import '../features/bookshelf/novel_dialog.dart';
import '../features/bookshelf/search_screen.dart';
import '../features/editor/workspace_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/resources/resource_library_screen.dart';
import 'desktop_commands.dart';
import 'services.dart';

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
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  void _error(Object error) => _messenger.currentState?.showSnackBar(
    SnackBar(content: Text('保存未完成：$error')),
  );

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
        final novel = await showNovelDialog(navigator.context);
        if (novel != null && mounted) {
          await navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => NovelWorkspace(novelId: novel.id),
            ),
          );
        }
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
      scaffoldMessengerKey: _messenger,
      builder: (context, child) => Overlay.wrap(
        child: DesktopCommands(invoke: _command, child: child!),
      ),
      title: 'SillyDraft · 胡闹草稿',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: mode == 'dark'
          ? ThemeMode.dark
          : mode == 'light'
          ? ThemeMode.light
          : ThemeMode.system,
      home: const BookshelfScreen(),
    );
  }
}

ThemeData _theme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff7060ad),
    brightness: brightness,
    surface: dark ? const Color(0xff1b1b24) : const Color(0xfffaf9f6),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xff24242e) : Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    textTheme: Typography.material2021().black.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .6),
      thickness: .7,
    ),
  );
}
