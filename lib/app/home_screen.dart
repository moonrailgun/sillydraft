import 'package:flutter/widgets.dart';

import '../features/bookshelf/bookshelf_screen.dart';
import '../features/resources/resource_library_screen.dart';
import '../features/settings/settings_screen.dart';
import 'widgets.dart';

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> {
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
    _visited.add(selectedIndex);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return PopScope(
      canPop: selectedIndex == HomeTab.shelf,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selectedIndex != HomeTab.shelf) {
          widget.onDestinationSelected(HomeTab.shelf);
        }
      },
      child: AppScaffold(
        sidebar: wide
            ? AppSidebar(
                selectedIndex: selectedIndex,
                onSelect: widget.onDestinationSelected,
                destinations: _destinations,
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
