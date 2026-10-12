import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum AppCommand { save, create, search, settings, resources }

class AppCommandIntent extends Intent {
  const AppCommandIntent(this.command);
  final AppCommand command;
}

/// Shares commands between native menus and hardware keyboards (including
/// keyboards attached to phones/tablets). Text editing remains focus-scoped.
class DesktopCommands extends StatelessWidget {
  const DesktopCommands({super.key, required this.child, required this.invoke});
  final Widget child;
  final void Function(AppCommand) invoke;

  @override
  Widget build(BuildContext context) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final desktop =
        mac ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    const labels = {
      AppCommand.create: '新建作品',
      AppCommand.save: '保存正文',
      AppCommand.search: '搜索作品与正文',
      AppCommand.resources: '创作资源库',
      AppCommand.settings: '设置',
    };
    const keys = {
      AppCommand.create: LogicalKeyboardKey.keyN,
      AppCommand.save: LogicalKeyboardKey.keyS,
      AppCommand.search: LogicalKeyboardKey.keyF,
      AppCommand.resources: LogicalKeyboardKey.keyO,
      AppCommand.settings: LogicalKeyboardKey.comma,
    };
    SingleActivator shortcut(AppCommand c, {bool? useMeta}) => SingleActivator(
      keys[c]!,
      meta: useMeta ?? mac,
      control: !(useMeta ?? mac),
      shift: c == AppCommand.search,
    );
    void edit(Intent intent) {
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused != null) Actions.maybeInvoke(focused, intent);
    }

    const editItems = <String, Intent>{
      '撤销': UndoTextIntent(SelectionChangedCause.keyboard),
      '重做': RedoTextIntent(SelectionChangedCause.keyboard),
      '剪切': CopySelectionTextIntent.cut(SelectionChangedCause.keyboard),
      '复制': CopySelectionTextIntent.copy,
      '粘贴': PasteTextIntent(SelectionChangedCause.keyboard),
      '全选': SelectAllTextIntent(SelectionChangedCause.keyboard),
    };
    Widget content = child;
    if (mac) {
      content = PlatformMenuBar(
        menus: [
          PlatformMenu(
            label: 'SillyDraft',
            menus: [
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.about,
              ),
              PlatformMenuItem(
                label: '设置…',
                shortcut: shortcut(AppCommand.settings),
                onSelected: () => invoke(AppCommand.settings),
              ),
              const PlatformMenuItemGroup(
                members: [
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.servicesSubmenu,
                  ),
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.hide,
                  ),
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.hideOtherApplications,
                  ),
                  PlatformProvidedMenuItem(
                    type: PlatformProvidedMenuItemType.showAllApplications,
                  ),
                ],
              ),
              const PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.quit,
              ),
            ],
          ),
          PlatformMenu(
            label: '文件',
            menus: [
              for (final c in [
                AppCommand.create,
                AppCommand.save,
                AppCommand.resources,
              ])
                PlatformMenuItem(
                  label: labels[c]!,
                  shortcut: shortcut(c),
                  onSelected: () => invoke(c),
                ),
            ],
          ),
          PlatformMenu(
            label: '编辑',
            menus: [
              for (final entry in editItems.entries)
                PlatformMenuItem(
                  label: entry.key,
                  onSelected: () => edit(entry.value),
                ),
              PlatformMenuItem(
                label: labels[AppCommand.search]!,
                shortcut: shortcut(AppCommand.search),
                onSelected: () => invoke(AppCommand.search),
              ),
            ],
          ),
          const PlatformMenu(
            label: '窗口',
            menus: [
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.minimizeWindow,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.zoomWindow,
              ),
              PlatformProvidedMenuItem(
                type: PlatformProvidedMenuItemType.toggleFullScreen,
              ),
            ],
          ),
        ],
        child: content,
      );
    } else if (desktop) {
      content = Column(
        children: [
          MenuBar(
            children: [
              SubmenuButton(
                menuChildren: [
                  for (final entry in labels.entries)
                    MenuItemButton(
                      shortcut: shortcut(entry.key),
                      onPressed: () => invoke(entry.key),
                      child: Text(entry.value),
                    ),
                  MenuItemButton(
                    onPressed: () => ServicesBinding.instance.exitApplication(
                      AppExitType.cancelable,
                    ),
                    child: const Text('退出'),
                  ),
                ],
                child: const Text('文件'),
              ),
              SubmenuButton(
                menuChildren: [
                  for (final entry in editItems.entries)
                    MenuItemButton(
                      onPressed: () => edit(entry.value),
                      child: Text(entry.key),
                    ),
                ],
                child: const Text('编辑'),
              ),
            ],
          ),
          Expanded(child: content),
        ],
      );
    }
    return Shortcuts(
      shortcuts: {
        for (final c in AppCommand.values) ...{
          shortcut(c, useMeta: false): AppCommandIntent(c),
          shortcut(c, useMeta: true): AppCommandIntent(c),
        },
      },
      child: Actions(
        actions: {
          AppCommandIntent: CallbackAction<AppCommandIntent>(
            onInvoke: (intent) {
              invoke(intent.command);
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: content),
      ),
    );
  }
}
