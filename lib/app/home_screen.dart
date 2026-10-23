import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/bookshelf/bookshelf_screen.dart';
import '../features/resources/resource_library_screen.dart';
import '../features/settings/settings_screen.dart';
import 'widgets.dart';
import 'task_activity.dart';

/// Top-level destinations, in navigation order. The assistant is not one of
/// them: it always works on a single novel, so it lives in the novel workspace.
abstract final class HomeTab {
  static const shelf = 0, resources = 1, settings = 2;
}

const _destinations = <NavDestination>[
  (icon: FLucideIcons.libraryBig, label: '作品', badge: 0),
  (icon: FLucideIcons.folderOpen, label: '资源', badge: 0),
  (icon: FLucideIcons.settings, label: '设置', badge: 0),
];

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onExitRequested,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final Future<void> Function() onExitRequested;

  @override
  ConsumerState<HomeScreen> createState() => _HomeState();
}

class _HomeState extends ConsumerState<HomeScreen> {
  // Tabs are built on first visit and then kept alive, so filters and scroll
  // positions survive switching and nothing runs for a tab never opened.
  final _visited = <int>{};

  Widget _page(int index) => switch (index) {
    HomeTab.shelf => const BookshelfScreen(),
    HomeTab.resources => const ResourceLibraryScreen(),
    _ => const SettingsScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final selectedIndex = widget.selectedIndex;
    final active = ref.watch(
      activeTasksProvider.select((tasks) => tasks.value?.isNotEmpty ?? false),
    );
    _visited.add(selectedIndex);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return PopScope(
      canPop: selectedIndex == HomeTab.shelf && !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selectedIndex != HomeTab.shelf) {
          widget.onDestinationSelected(HomeTab.shelf);
        } else if (!didPop && active) {
          widget.onExitRequested();
        }
      },
      child: AppScaffold(
        sidebar: wide
            ? AppSidebar(
                selectedIndex: selectedIndex,
                onSelect: widget.onDestinationSelected,
                destinations: _destinations,
                header: const _Brand(),
                footerCount: 1,
              )
            : null,
        footer: wide
            ? null
            : AppBottomBar(
                selectedIndex: selectedIndex,
                onSelect: widget.onDestinationSelected,
                destinations: _destinations,
              ),
        child: IndexedStack(
          index: selectedIndex,
          children: [
            for (var i = 0; i < _destinations.length; i++)
              if (_visited.contains(i))
                TickerMode(
                  enabled: selectedIndex == i,
                  child: HeroMode(enabled: selectedIndex == i, child: _page(i)),
                )
              else
                const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}

/// The app's mark at the top of the sidebar.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colors.foreground,
              borderRadius: theme.style.borderRadius.md,
            ),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                FLucideIcons.libraryBig,
                size: 16,
                color: theme.colors.background,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              'SillyDraft',
              overflow: TextOverflow.ellipsis,
              style: theme.typography.body.md.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
                color: theme.colors.foreground,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
