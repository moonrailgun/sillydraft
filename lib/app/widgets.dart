import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forui/forui.dart';

import 'task_activity.dart';
import 'theme.dart';

export 'package:forui/forui.dart';

/// Shared UI building blocks on top of forui.
///
/// Conventions for the whole app:
/// * Icons come from [FLucideIcons] only.
/// * Colors and text styles come from `context.theme.colors` and
///   `context.theme.typography`, never from Material's `Theme.of`.
/// * Icon-only buttons are [IconAction] (or [HeaderIconAction] in a header) so
///   every one has a hover tooltip and tests can find it by its label.
/// * Dialogs go through [showAppDialog] + [AppDialog]; one-line questions
///   through [confirmAction] and [askText]; feedback through [toast].

class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.retry,
  });
  final AsyncValue<T> value;
  final Widget Function(T) builder;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => value.when(
    skipLoadingOnRefresh: true,
    skipLoadingOnReload: true,
    data: builder,
    loading: () => const Center(child: FCircularProgress()),
    error: (error, _) => ErrorPane(message: error.toString(), retry: retry),
  );
}

/// Centers content via inner padding so scroll viewports fill their pane.
class ContentLayout extends StatelessWidget {
  const ContentLayout({
    super.key,
    required this.maxWidth,
    required this.builder,
  });

  final double maxWidth;
  final Widget Function(BuildContext context, EdgeInsets inset) builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) => builder(
      context,
      EdgeInsets.symmetric(
        horizontal: bounds.maxWidth > maxWidth
            ? (bounds.maxWidth - maxWidth) / 2
            : 0,
      ),
    ),
  );
}

class ErrorPane extends StatelessWidget {
  const ErrorPane({super.key, required this.message, this.retry});
  final String message;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(FLucideIcons.circleAlert, size: 28, color: colors.error),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (retry != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: FButton(
                  mainAxisSize: MainAxisSize.min,
                  onPress: retry,
                  child: const Text('重试'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A control that tests find by the label shown in its tooltip, the way
/// `find.byTooltip` found Material buttons. See `findAction` in test/support.
abstract interface class ActionLabel {
  String get tooltip;
}

/// An icon-only button with a hover tooltip. [tooltip] is also its semantic
/// label, and widget tests find it with `findAction(tooltip)`.
class IconAction extends StatelessWidget implements ActionLabel {
  const IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
    this.variant = FButtonVariant.ghost,
    this.selected = false,
    this.size = 18,
  });
  final IconData icon;
  @override
  final String tooltip;
  final VoidCallback? onPress;
  final FButtonVariant variant;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) => _iconButton(
    icon: icon,
    tooltip: tooltip,
    onPress: onPress,
    variant: variant,
    selected: selected,
    size: size,
  );
}

/// The icon button body shared by [IconAction] and the out-of-header
/// fallback of [HeaderIconAction]; not an [ActionLabel] itself, so a control
/// is found once by its label.
Widget _iconButton({
  required IconData icon,
  required String tooltip,
  required VoidCallback? onPress,
  FButtonVariant variant = FButtonVariant.ghost,
  bool selected = false,
  double size = 18,
}) => FTooltip(
  tipBuilder: (_, _) => Text(tooltip),
  child: FButton.icon(
    variant: variant,
    selected: selected,
    onPress: onPress,
    semanticsLabel: tooltip,
    child: Icon(icon, size: size),
  ),
);

/// Whether [context] sits inside an [FHeader] (header actions need one).
bool _inHeader(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<FHeaderData>() != null;

/// [IconAction] for an [FHeader]'s `suffixes`. Outside a header (an embedded
/// page's title row) it renders as a plain [IconAction], so the same actions
/// list works in both [PageScaffold] modes.
class HeaderIconAction extends StatelessWidget implements ActionLabel {
  const HeaderIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPress,
  });
  final IconData icon;
  @override
  final String tooltip;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    if (!_inHeader(context)) {
      return _iconButton(icon: icon, tooltip: tooltip, onPress: onPress);
    }
    return FTooltip(
      tipBuilder: (_, _) => Text(tooltip),
      child: FHeaderAction(
        icon: Icon(icon),
        onPress: onPress,
        semanticsLabel: tooltip,
      ),
    );
  }
}

/// The back button of a pushed page. Pops the current route.
class AppBackButton extends StatelessWidget implements ActionLabel {
  const AppBackButton({super.key, this.onPress});
  @override
  String get tooltip => '返回';

  /// Defaults to `Navigator.maybePop`.
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FTooltip(
    tipBuilder: (_, _) => const Text('返回'),
    child: FHeaderAction.back(
      semanticsLabel: '返回',
      onPress: onPress ?? () => Navigator.maybePop(context),
    ),
  );
}

/// A full-screen page: forui scaffold with a nested header, a back button when
/// the route can pop, and optional floating action.
///
/// Embedded pages (a section of the novel workspace or the 助手 tab) drop the
/// header for a slim in-body title row, because the host owns the chrome.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.bottom,
    this.floatingActionButton,
    this.embedded = false,
    this.leading,
    this.titleWidget,
  });
  final String title;

  /// Replaces the plain [title] text in the header, e.g. a title with a
  /// subtitle line.
  final Widget? titleWidget;
  final Widget body;

  /// Header suffixes: [HeaderIconAction]s, popover menus, small buttons.
  final List<Widget> actions;

  /// Shown under the header and above [body], e.g. a tab strip or filters.
  final Widget? bottom;
  final Widget? floatingActionButton;
  final bool embedded;

  /// Replaces the automatic back button.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?bottom,
        Expanded(child: body),
      ],
    );
    if (embedded) {
      return AppScaffold(
        resizeToAvoidBottomInset: false,
        floatingActionButton: floatingActionButton,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: DefaultTextStyle.merge(
                      style: context.theme.typography.body.lg.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                      child: titleWidget ?? Text(title),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            Expanded(child: content),
          ],
        ),
      );
    }
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    return AppScaffold(
      header: FHeader.nested(
        // Material's AppBar capped title scaling the same way, so large
        // system text does not push the header actions off screen.
        title: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.34,
          child: titleWidget ?? Text(title),
        ),
        prefixes: [?leading ?? (canPop ? const AppBackButton() : null)],
        suffixes: [...actions, const TaskActivityAction()],
      ),
      floatingActionButton: floatingActionButton,
      child: content,
    );
  }
}

/// [FScaffold] without forui's default child padding, plus a transparent
/// [Material] so the few Material-only pieces (rich-text editor, selectable
/// text menus) still find their ancestor, and an optional floating action.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    required this.child,
    this.header,
    this.footer,
    this.sidebar,
    this.floatingActionButton,
    this.childPad = false,
    this.resizeToAvoidBottomInset = true,
  });
  final Widget child;
  final Widget? header, footer, sidebar, floatingActionButton;
  final bool childPad;

  /// Keep true for a top-level page. A scaffold nested inside another page
  /// passes false, or the keyboard height is subtracted twice.
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    Widget body = child;
    if (floatingActionButton != null) {
      body = Stack(
        children: [
          Positioned.fill(child: body),
          Positioned(
            right: 20,
            bottom: 20,
            child: SafeArea(child: floatingActionButton!),
          ),
        ],
      );
    }
    return FScaffold(
      header: header,
      footer: footer,
      sidebar: sidebar,
      childPad: childPad,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      child: Material(type: MaterialType.transparency, child: body),
    );
  }
}

/// A primary floating button with an icon and a label.
class FloatingAction extends StatelessWidget {
  const FloatingAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPress,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPress;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: context.theme.style.borderRadius.md,
      boxShadow: const [
        BoxShadow(
          color: Color(0x22000000),
          blurRadius: 16,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: FButton(
      mainAxisSize: MainAxisSize.min,
      onPress: onPress,
      prefix: Icon(icon),
      child: Text(label),
    ),
  );
}

/// One entry of a [MenuAction].
typedef MenuEntry = ({
  String label,
  VoidCallback onPress,
  IconData? icon,
  bool destructive,
});

/// Shorthand for a [MenuEntry].
MenuEntry menuEntry(
  String label,
  VoidCallback onPress, {
  IconData? icon,
  bool destructive = false,
}) => (label: label, onPress: onPress, icon: icon, destructive: destructive);

/// An icon button that opens a popover menu: the forui replacement for
/// `PopupMenuButton`. [tooltip] labels the trigger as in [IconAction].
class MenuAction extends StatelessWidget implements ActionLabel {
  const MenuAction({
    super.key,
    required this.tooltip,
    required this.entries,
    this.icon = FLucideIcons.ellipsisVertical,
    this.header = false,
    this.enabled = true,
    this.child,
  });
  @override
  final String tooltip;
  final List<MenuEntry> entries;

  /// When false the trigger is disabled and the menu cannot open.
  final bool enabled;
  final IconData icon;

  /// Styles the trigger as an [FHeaderAction] when inside an [FHeader];
  /// elsewhere it falls back to the plain icon button.
  final bool header;

  /// A custom trigger; the whole child toggles the menu.
  final Widget? child;

  @override
  Widget build(BuildContext context) => FPopoverMenu(
    menuAnchor: Alignment.topRight,
    childAnchor: Alignment.bottomRight,
    menuBuilder: (context, controller, _) => [
      FItemGroup(
        children: [
          for (final entry in entries)
            FItem(
              prefix: entry.icon == null ? null : Icon(entry.icon),
              title: Text(entry.label),
              variant: entry.destructive
                  ? FItemVariant.destructive
                  : FItemVariant.primary,
              onPress: () {
                controller.hide();
                entry.onPress();
              },
            ),
        ],
      ),
    ],
    builder: (context, controller, _) => FTooltip(
      tipBuilder: (_, _) => Text(tooltip),
      child: child != null
          ? FTappable(
              semanticsLabel: tooltip,
              onPress: enabled ? controller.toggle : null,
              child: child!,
            )
          : (header && _inHeader(context)
                ? FHeaderAction(
                    icon: Icon(icon),
                    semanticsLabel: tooltip,
                    onPress: enabled ? controller.toggle : null,
                  )
                : FButton.icon(
                    variant: FButtonVariant.ghost,
                    semanticsLabel: tooltip,
                    onPress: enabled ? controller.toggle : null,
                    child: Icon(icon, size: 18),
                  )),
    ),
  );
}

/// A small toggle for filters and single choices: the forui replacement for
/// `ChoiceChip` / `FilterChip`.
class ChoicePill extends StatelessWidget {
  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onPress,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback? onPress;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => FButton(
    variant: selected ? FButtonVariant.primary : FButtonVariant.outline,
    size: FButtonSizeVariant.sm,
    selected: selected,
    mainAxisSize: MainAxisSize.min,
    onPress: onPress,
    prefix: icon == null ? null : Icon(icon),
    child: Text(label),
  );
}

/// Shows [builder]'s content in a forui bottom sheet ([AppSheet] panel):
/// the replacement for `showModalBottomSheet`.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  double? mainAxisMaxRatio = 0.85,
}) => showFSheet<T>(
  context: context,
  side: FLayout.btt,
  mainAxisMaxRatio: mainAxisMaxRatio,
  builder: (context) => AppSheet(
    title: title,
    child: Builder(builder: builder),
  ),
);

/// The panel of an [showAppSheet] sheet: rounded top, drag handle, optional
/// title, then the content.
class AppSheet extends StatelessWidget {
  const AppSheet({super.key, required this.child, this.title});
  final Widget child;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colors.background,
        border: Border(top: BorderSide(color: theme.colors.border)),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 6),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colors.border,
                    borderRadius: theme.style.borderRadius.pill,
                  ),
                ),
              ),
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                  child: Text(
                    title!,
                    style: theme.typography.body.lg.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dialogs

class _DialogAnimation extends InheritedWidget {
  const _DialogAnimation({required this.animation, required super.child});
  final Animation<double> animation;
  @override
  bool updateShouldNotify(_DialogAnimation old) => old.animation != animation;
}

/// Shows a forui dialog route; [builder] normally returns an [AppDialog].
/// Pop it with `Navigator.pop(context, result)` as with `showDialog`.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showFDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context, _, animation) => _DialogAnimation(
    animation: animation,
    child: Builder(builder: builder),
  ),
);

/// A dialog with a title, an optional scrollable body and a row of actions.
/// Put the dismissive action first and the main action last.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.body,
    this.actions = const [],
    this.maxWidth = 480,
  });
  final Widget title;
  final Widget? body;
  final List<Widget> actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final animation = context
        .dependOnInheritedWidgetOfExactType<_DialogAnimation>()
        ?.animation;
    // Phones trade side padding for line width.
    final side = EdgeInsets.symmetric(horizontal: touchPlatform ? 16 : 24);
    return FDialog(
      animation: animation,
      constraints: BoxConstraints(minWidth: 280, maxWidth: maxWidth),
      // Side padding sits on each part, not the column, so the body's
      // scroll view spans the full width and its scrollbar hugs the edge.
      builder: (context, style) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: side,
              child: DefaultTextStyle.merge(
                style: style.titleTextStyle,
                child: title,
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 10),
              Flexible(
                child: SingleChildScrollView(
                  padding: side,
                  child: DefaultTextStyle.merge(
                    style: style.bodyTextStyle,
                    child: body!,
                  ),
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 20),
              Padding(
                padding: side,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final action in actions)
                      action is FButton
                          ? IntrinsicWidth(child: action)
                          : action,
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks a yes/no question. Resolves to true only when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text(title),
        body: message == null ? null : Text(message),
        actions: [
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => Navigator.pop(context, false),
            child: Text(cancelLabel),
          ),
          FButton(
            variant: destructive
                ? FButtonVariant.destructive
                : FButtonVariant.primary,
            onPress: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;

Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '名称',
  int maxLines = 1,
  bool allowEmpty = false,
}) => showAppDialog<String>(
  context: context,
  builder: (context) => _TextDialog(
    title: title,
    initial: initial,
    label: label,
    maxLines: maxLines,
    allowEmpty: allowEmpty,
  ),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.maxLines,
    required this.allowEmpty,
  });
  final String title, initial, label;
  final int maxLines;

  /// Whether an empty answer is one, as a name that may be left blank.
  final bool allowEmpty;
  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = controller.text.trim();
    if (text.isNotEmpty || widget.allowEmpty) Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(widget.title),
    body: FTextField(
      control: FTextFieldControl.managed(controller: controller),
      autofocus: true,
      maxLines: widget.maxLines,
      label: Text(widget.label),
      onSubmit: (_) => _submit(),
    ),
    actions: [
      FButton(
        variant: FButtonVariant.outline,
        onPress: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FButton(onPress: _submit, child: const Text('保存')),
    ],
  );
}

// ---------------------------------------------------------------------------
// Feedback

/// A short message in a forui toast.
void toast(BuildContext context, String message, {String? description}) {
  if (!context.mounted) return;
  showFToast(
    context: context,
    title: Text(message),
    description: description == null ? null : Text(description),
  );
}

/// An error in a destructive toast.
void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  showFToast(
    context: context,
    variant: FToastVariant.destructive,
    icon: const Icon(FLucideIcons.circleAlert),
    title: Text(error.toString()),
  );
}

// ---------------------------------------------------------------------------
// Navigation

/// One top-level section: a Lucide icon, a label and an optional count badge.
typedef NavDestination = ({IconData icon, String label, int badge});

/// The desktop section list: each entry is one button, icon and label
/// together, that hovers and highlights as a unit. The sidebar sits on a
/// surface one step off the page, and the last [footerCount] entries are
/// pinned to its bottom.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.destinations,
    this.header,
    this.footerCount = 0,
    this.width = 200,
  });

  /// The highlighted entry; none when out of range.
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<NavDestination> destinations;
  final Widget? header;
  final int footerCount;
  final double width;

  Widget _group(int from, int to) => FSidebarGroup(
    children: [
      for (var i = from; i < to; i++)
        FSidebarItem(
          icon: Icon(destinations[i].icon),
          label: Row(
            children: [
              Expanded(child: Text(destinations[i].label)),
              if (destinations[i].badge > 0)
                FBadge(child: Text('${destinations[i].badge}')),
            ],
          ),
          selected: i == selectedIndex,
          onPress: () => onSelect(i),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = context.theme.colors;
    // Tints over the sidebar surface, so they read in both brightnesses.
    final tint = colors.foreground;
    final split = destinations.length - footerCount;
    return FSidebar(
      style: FSidebarStyleDelta.delta(
        constraints: BoxConstraints.tightFor(width: width),
        decoration: DecorationDelta.boxDelta(
          color: Color.alphaBlend(
            tint.withValues(alpha: 0.035),
            colors.background,
          ),
        ),
        groupStyle: FSidebarGroupStyleDelta.delta(
          padding: const EdgeInsetsDelta.value(
            EdgeInsets.symmetric(horizontal: 10),
          ),
          itemStyle: FSidebarItemStyleDelta.delta(
            padding: const EdgeInsetsGeometryDelta.value(
              EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            ),
            iconSpacing: 10,
            backgroundColor: FVariants(
              tint.withValues(alpha: 0),
              variants: {
                [.selected]: tint.withValues(alpha: 0.08),
                [.hovered, .pressed]: tint.withValues(alpha: 0.04),
              },
            ),
            textStyle: FVariantsDelta.delta([
              .exact({
                .selected,
              }, const TextStyleDelta.delta(fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ),
      header: header,
      footer: footerCount > 0 ? _group(split, destinations.length) : null,
      children: [_group(0, split)],
    );
  }
}

/// The phone section bar.
class AppBottomBar extends StatelessWidget {
  const AppBottomBar({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.destinations,
  });
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final List<NavDestination> destinations;

  @override
  Widget build(BuildContext context) => FBottomNavigationBar(
    index: selectedIndex,
    onChange: onSelect,
    safeAreaBottom: true,
    children: [
      for (final d in destinations)
        FBottomNavigationBarItem(
          icon: CountBadge(count: d.badge, child: Icon(d.icon)),
          label: Text(d.label),
        ),
    ],
  );
}

/// A small count in the top-right corner of [child]; hidden at zero.
class CountBadge extends StatelessWidget {
  const CountBadge({super.key, required this.count, required this.child});
  final int count;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    final colors = context.theme.colors;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -8,
          top: -5,
          child: Container(
            constraints: const BoxConstraints(minWidth: 16),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: colors.destructive,
              borderRadius: context.theme.style.borderRadius.pill,
            ),
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: context.theme.typography.body.xs2.copyWith(
                color: colors.destructiveForeground,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String countCharacters(String text) =>
    '${text.replaceAll(RegExp(r'\s'), '').runes.length}';
String dateLabel(DateTime date) =>
    '${date.toLocal().month}月${date.toLocal().day}日';
