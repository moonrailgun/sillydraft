import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../illustrations/illustration_gallery.dart';
import '../illustrations/asset_image.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/agent_screen.dart';
import '../agent/writing_request_screen.dart';
import '../agent/task_screen.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, required this.chapter});
  final Chapter chapter;
  @override
  ConsumerState<EditorScreen> createState() => _EditorState();
}

class _EditorState extends ConsumerState<EditorScreen> {
  late Chapter _chapter;
  late QuillController _controller;
  final _focus = FocusNode(), _scroll = ScrollController();
  final _editorKey = GlobalKey<EditorState>();
  Timer? _debounce;
  Future<void>? _saving;
  late String _saved;
  Object? _error;
  bool _allowPop = false;

  /// Whether the assistant is docked beside the manuscript (wide screens).
  bool _assistant = false;
  late final AppServices _services;
  @override
  void initState() {
    super.initState();
    _chapter = widget.chapter;
    _controller = QuillController(
      document: Document.fromJson(_chapter.content.delta),
      selection: const TextSelection.collapsed(offset: 0),
    );
    _saved = _content.encoded;
    _controller.addListener(_changed);
    _services = ref.read(servicesProvider);
    _services.registerDraft(this, _flush);
  }

  ManuscriptContent get _content => ManuscriptContent.fromDelta(
    _controller.document.toDelta().toJson().cast<Map<String, dynamic>>(),
  );
  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_content.encoded == _saved) return;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_flush().catchError((Object _) {})),
    );
  }

  Future<void> _flush() async {
    _debounce?.cancel();
    if (_saving != null) {
      await _saving;
      if (_content.encoded == _saved) return;
    }
    if (_content.encoded == _saved) return;
    final pending = _saveLoop();
    _saving = pending;
    try {
      await pending;
    } finally {
      _saving = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveLoop() async {
    while (_content.encoded != _saved) {
      final content = _content;
      if (mounted) setState(() => _error = null);
      try {
        final saved = await _services.repository.saveChapter(
          branchId: _chapter.branchId,
          chapterId: _chapter.id,
          expectedRevisionId: _chapter.revisionId,
          content: content,
        );
        _chapter = saved;
        _saved = content.encoded;
      } catch (error) {
        if (mounted) setState(() => _error = error);
        rethrow;
      }
    }
  }

  Future<void> _leave() async {
    try {
      await _flush();
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.pop(context);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _saveProposal() async {
    try {
      await _services.repository.createProposal(
        branchId: _chapter.branchId,
        chapterId: _chapter.id,
        baseRevisionId: _chapter.revisionId,
        content: _content,
        summary: '保留发生冲突的本地编辑',
      );
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _history() async {
    try {
      await _flush();
      final history = await _services.repository.listRevisions(
        branchId: _chapter.branchId,
        chapterId: _chapter.id,
      );
      if (!mounted) return;
      await showAppSheet<void>(
        context: context,
        title: '正文版本',
        mainAxisMaxRatio: .65,
        builder: (sheetContext) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '恢复会保存为新版本，现有历史会保留。',
                style: context.theme.typography.body.sm.copyWith(
                  color: context.theme.colors.mutedForeground,
                ),
              ),
            ),
            for (final version in history)
              FItem(
                title: Text(
                  '${dateLabel(version.createdAt)} ${version.createdAt.toLocal().toString().substring(11, 16)} · ${version.reason}',
                ),
                subtitle: Text(
                  version.content.text.replaceAll('\n', ' '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                suffix: version.id == _chapter.revisionId
                    ? FBadge(
                        variant: FBadgeVariant.secondary,
                        child: const Text('当前'),
                      )
                    : FButton(
                        variant: FButtonVariant.outline,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        onPress: () async {
                          try {
                            final restored = await _services.repository
                                .restoreRevision(
                                  branchId: _chapter.branchId,
                                  chapterId: _chapter.id,
                                  expectedRevisionId: _chapter.revisionId,
                                  revisionId: version.id,
                                );
                            if (!mounted) return;
                            _chapter = restored;
                            _controller.document = Document.fromJson(
                              restored.content.delta,
                            );
                            _saved = _content.encoded;
                            setState(() {});
                            if (sheetContext.mounted) {
                              Navigator.pop(sheetContext);
                            }
                          } catch (error) {
                            if (mounted) showError(context, error);
                          }
                        },
                        child: const Text('恢复'),
                      ),
              ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _generate() async {
    final selection = _controller.selection;
    try {
      await _flush();
      if (!mounted) return;
      final end = selection.end.clamp(0, _chapter.content.text.length - 1);
      final start = selection.start.clamp(0, end);
      final task = await Navigator.push<GenerationTask>(
        context,
        MaterialPageRoute(
          builder: (_) => WritingRequestScreen(
            chapter: _chapter,
            rangeStart: end > start ? start : null,
            rangeEnd: end > start ? end : null,
          ),
        ),
      );
      if (task != null && mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
        );
        await _reloadAccepted();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Picks up text written into this chapter elsewhere, as long as nothing
  /// typed here is still unsaved.
  Future<void> _reloadAccepted() async {
    if (_saving != null || _content.encoded != _saved) return;
    final latest = await _services.repository.getChapter(
      branchId: _chapter.branchId,
      chapterId: _chapter.id,
    );
    if (mounted &&
        _saving == null &&
        latest.revisionId != _chapter.revisionId &&
        _content.encoded == _saved) {
      _chapter = latest;
      _controller.document = Document.fromJson(latest.content.delta);
      _saved = _content.encoded;
      setState(() {});
    }
  }

  /// The assistant, reading the story up to this chapter. Docked beside the
  /// manuscript when there is room, otherwise a large floating window.
  Future<void> _askAssistant(bool dock) async {
    try {
      await _flush();
      if (!mounted) return;
      if (dock) {
        setState(() => _assistant = !_assistant);
        return;
      }
      await showAssistantSheet(
        context,
        branchId: _chapter.branchId,
        chapterId: _chapter.id,
      );
      await _reloadAccepted();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _services.unregisterDraft(this);
    _controller.removeListener(_changed);
    _controller.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _insertImage() async {
    final offset = _controller.selection.extentOffset.clamp(
      0,
      _content.text.length - 1,
    );
    try {
      await _flush();
      if (!mounted) return;
      final asset = await Navigator.push<StoryAsset>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              IllustrationGallery(branchId: _chapter.branchId, picker: true),
        ),
      );
      if (asset == null) return;
      final chapter = await _services.repository.insertIllustration(
        branchId: _chapter.branchId,
        chapterId: _chapter.id,
        expectedRevisionId: _chapter.revisionId,
        assetId: asset.id,
        offset: offset,
      );
      if (mounted) {
        _chapter = chapter;
        _controller.document = Document.fromJson(chapter.content.delta);
        _saved = _content.encoded;
        setState(() {});
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dirty = _content.encoded != _saved;
    final dock = MediaQuery.sizeOf(context).width >= 1100;
    final docked = dock && _assistant;
    // A generation written into this chapter while this page is open, e.g.
    // one whose task page was closed early, or the assistant's beside it.
    ref.listen(
      repositoryContentChangesProvider,
      (_, _) => unawaited(_reloadAccepted().catchError((Object _) {})),
    );
    final theme = context.theme;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: AppScaffold(
        header: FHeader.nested(
          // Like an app bar title: legible at large text, never huge.
          title: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.34,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _chapter.title.isEmpty ? '正文编辑' : _chapter.title,
                  style: theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
                Text(
                  _error != null
                      ? '保存遇到问题'
                      : _saving != null
                      ? '正在保存…'
                      : dirty
                      ? '尚未保存'
                      : '已保存到设备',
                  style: theme.typography.body.xs.copyWith(
                    color: _error != null
                        ? theme.colors.error
                        : theme.colors.mutedForeground,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          prefixes: [
            HeaderIconAction(
              icon: FLucideIcons.arrowLeft,
              tooltip: '保存并返回',
              onPress: _leave,
            ),
          ],
          suffixes: [
            HeaderIconAction(
              icon: FLucideIcons.imagePlus,
              tooltip: '插入图片',
              onPress: _insertImage,
            ),
            HeaderIconAction(
              icon: FLucideIcons.wandSparkles,
              tooltip: '生成或改写选区',
              onPress: _generate,
            ),
            _HeaderToggle(
              key: const Key('editor-assistant'),
              icon: docked
                  ? FLucideIcons.panelRightClose
                  : FLucideIcons.sparkles,
              tooltip: docked ? '收起助手' : '问助手',
              selected: docked,
              onPress: () => _askAssistant(dock),
            ),
            HeaderIconAction(
              icon: FLucideIcons.history,
              tooltip: '正文版本',
              onPress: _history,
            ),
            HeaderIconAction(
              icon: FLucideIcons.check,
              tooltip: '立即保存',
              onPress: () async {
                try {
                  await _flush();
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _manuscript()),
              if (docked) ...[
                const FDivider(axis: Axis.vertical, style: _edgeToEdge),
                SizedBox(
                  width: 420,
                  child: AgentPanel(
                    key: ValueKey('agent:${_chapter.id}'),
                    branchId: _chapter.branchId,
                    chapterId: _chapter.id,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _manuscript() {
    final theme = context.theme;
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FAlert(
              variant: FAlertVariant.destructive,
              title: Text(_error.toString()),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _saveProposal,
                      child: const Text('另存，稍后处理'),
                    ),
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () =>
                          unawaited(_flush().catchError((Object _) {})),
                      child: const Text('重试保存'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: QuillEditor.basic(
                key: const Key('manuscript-editor'),
                controller: _controller,
                focusNode: _focus,
                scrollController: _scroll,
                config: QuillEditorConfig(
                  editorKey: _editorKey,
                  embedBuilders: const [LocalImageEmbedBuilder()],
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 80),
                  expands: true,
                  placeholder: '从一句话开始，让故事向前走。',
                  autoFocus: true,
                ),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text(
              '${countCharacters(_controller.document.toPlainText())} 字',
              style: theme.typography.body.xs.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
          ),
        ),
        const FDivider(style: _edgeToEdge),
        ManuscriptToolbar(
          controller: _controller,
          editorFocus: _focus,
          editorKey: _editorKey,
        ),
      ],
    );
  }
}

/// A line that runs to the edges of its parent, without forui's default
/// inset.
const _edgeToEdge = FDividerStyleDelta.delta(
  padding: EdgeInsetsGeometryDelta.value(EdgeInsets.zero),
);

/// A header action that stays highlighted while its panel is open.
class _HeaderToggle extends StatelessWidget implements ActionLabel {
  const _HeaderToggle({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPress,
  });
  final IconData icon;
  @override
  final String tooltip;
  final bool selected;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) => FTooltip(
    tipBuilder: (_, _) => Text(tooltip),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? context.theme.colors.secondary : null,
        borderRadius: context.theme.style.borderRadius.md,
      ),
      child: FHeaderAction(
        icon: Icon(icon),
        selected: selected,
        semanticsLabel: tooltip,
        onPress: onPress,
      ),
    ),
  );
}

/// The formatting bar under the manuscript, driven by the editor's
/// [controller]: history, inline styles, heading level, blocks and find.
///
/// It sits in the editor's tap region, so pressing a button keeps the
/// editor's focus and selection; formatting applies to what is selected.
class ManuscriptToolbar extends StatelessWidget {
  const ManuscriptToolbar({
    super.key,
    required this.controller,
    required this.editorFocus,
    required this.editorKey,
  });
  final QuillController controller;
  final FocusNode editorFocus;
  final GlobalKey<EditorState> editorKey;

  static const _headings = [
    ('正文', Attribute.header),
    ('标题 1', Attribute.h1),
    ('标题 2', Attribute.h2),
    ('标题 3', Attribute.h3),
  ];

  /// Whether [attribute] applies to the whole selection. Lists and headings
  /// share a key, so those compare the value too.
  static bool _active(Map<String, Attribute> styles, Attribute attribute) {
    if (attribute.key == Attribute.list.key ||
        attribute.key == Attribute.header.key) {
      return styles[attribute.key]?.value == attribute.value;
    }
    return styles.containsKey(attribute.key);
  }

  void _format(Attribute attribute) {
    controller
      // Block formats should not pop up the keyboard on phones.
      ..skipRequestKeyboard = !attribute.isInline
      ..formatSelection(attribute);
  }

  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final styles = controller.getSelectionStyle().attributes;
        Widget toggle(Attribute attribute, IconData icon, String tooltip) {
          final on = _active(styles, attribute);
          return IconAction(
            icon: icon,
            tooltip: tooltip,
            selected: on,
            onPress: () =>
                _format(on ? Attribute.clone(attribute, null) : attribute),
          );
        }

        final heading = styles[Attribute.header.key] ?? Attribute.header;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconAction(
                icon: FLucideIcons.undo2,
                tooltip: '撤销',
                onPress: controller.hasUndo ? controller.undo : null,
              ),
              IconAction(
                icon: FLucideIcons.redo2,
                tooltip: '重做',
                onPress: controller.hasRedo ? controller.redo : null,
              ),
              const _Separator(),
              toggle(Attribute.bold, FLucideIcons.bold, '加粗'),
              toggle(Attribute.italic, FLucideIcons.italic, '斜体'),
              toggle(Attribute.underline, FLucideIcons.underline, '下划线'),
              const _Separator(),
              _HeadingMenu(
                current: _headings
                    .firstWhere(
                      (h) => h.$2 == heading,
                      orElse: () => _headings.first,
                    )
                    .$1,
                entries: [
                  for (final (label, attribute) in _headings)
                    (
                      label: label,
                      selected: attribute == heading,
                      onPress: () => _format(attribute),
                    ),
                ],
              ),
              const _Separator(),
              toggle(Attribute.ol, FLucideIcons.listOrdered, '有序列表'),
              toggle(Attribute.ul, FLucideIcons.list, '无序列表'),
              toggle(Attribute.blockQuote, FLucideIcons.textQuote, '引用'),
              const _Separator(),
              _FindButton(
                controller: controller,
                editorFocus: editorFocus,
                editorKey: editorKey,
              ),
            ],
          ),
        );
      },
    ),
  );
}

class _Separator extends StatelessWidget {
  const _Separator();
  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 20,
    child: FDivider(
      axis: Axis.vertical,
      style: FDividerStyleDelta.delta(
        padding: EdgeInsetsGeometryDelta.value(
          EdgeInsets.symmetric(horizontal: 6),
        ),
      ),
    ),
  );
}

/// The heading level picker: shows the current level and lists the others.
class _HeadingMenu extends StatelessWidget implements ActionLabel {
  const _HeadingMenu({required this.current, required this.entries});
  final String current;
  final List<({String label, bool selected, VoidCallback onPress})> entries;

  @override
  String get tooltip => '标题样式';

  @override
  Widget build(BuildContext context) => FPopoverMenu(
    menuAnchor: Alignment.bottomLeft,
    childAnchor: Alignment.topLeft,
    menuBuilder: (context, popover, _) => [
      FItemGroup(
        children: [
          for (final entry in entries)
            FItem(
              prefix: Icon(
                FLucideIcons.check,
                color: entry.selected ? null : const Color(0x00000000),
              ),
              title: Text(entry.label),
              selected: entry.selected,
              onPress: () {
                popover.hide();
                entry.onPress();
              },
            ),
        ],
      ),
    ],
    builder: (context, popover, _) => FTooltip(
      tipBuilder: (_, _) => Text(tooltip),
      child: FButton(
        variant: FButtonVariant.ghost,
        size: FButtonSizeVariant.sm,
        mainAxisSize: MainAxisSize.min,
        semanticsLabel: '$tooltip：$current',
        onPress: popover.toggle,
        prefix: const Icon(FLucideIcons.heading),
        suffix: const Icon(FLucideIcons.chevronDown),
        child: Text(current),
      ),
    ),
  );
}

/// Find in the manuscript: a small panel above the toolbar that steps
/// through matches, selecting each one in the editor.
class _FindButton extends StatelessWidget {
  const _FindButton({
    required this.controller,
    required this.editorFocus,
    required this.editorKey,
  });
  final QuillController controller;
  final FocusNode editorFocus;
  final GlobalKey<EditorState> editorKey;

  @override
  Widget build(BuildContext context) => FPopover(
    popoverAnchor: Alignment.bottomRight,
    childAnchor: Alignment.topRight,
    control: FPopoverControl.managed(
      onChange: (shown) {
        // Back to writing at the match that was found.
        if (!shown) editorFocus.requestFocus();
      },
    ),
    popoverBuilder: (context, popover) => _FindPanel(
      controller: controller,
      editorKey: editorKey,
      onClose: popover.hide,
    ),
    builder: (context, popover, _) => IconAction(
      icon: FLucideIcons.search,
      tooltip: '查找',
      onPress: popover.toggle,
    ),
  );
}

class _FindPanel extends StatefulWidget {
  const _FindPanel({
    required this.controller,
    required this.editorKey,
    required this.onClose,
  });
  final QuillController controller;
  final GlobalKey<EditorState> editorKey;
  final VoidCallback onClose;
  @override
  State<_FindPanel> createState() => _FindPanelState();
}

class _FindPanelState extends State<_FindPanel> {
  final _query = TextEditingController();
  String _searched = '';
  List<int> _matches = const [];
  int _index = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search(String text) {
    if (text == _searched) return;
    _searched = text;
    final matches = text.isEmpty
        ? const <int>[]
        : widget.controller.document.search(text);
    // Start from the match at or after the current selection, so typing
    // more of a word keeps the same match.
    final from = widget.controller.selection.start;
    final index = matches.indexWhere((offset) => offset >= from);
    setState(() {
      _matches = matches;
      _index = index < 0 ? 0 : index;
    });
    if (matches.isNotEmpty) _select();
  }

  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(
      () => _index = (_index + delta + _matches.length) % _matches.length,
    );
    _select();
  }

  /// Selects the current match without taking focus from the search field,
  /// and scrolls the manuscript to it.
  void _select() {
    final controller = widget.controller;
    final start = _matches[_index], end = start + _searched.length;
    controller.skipRequestKeyboard = true;
    controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: end),
      ChangeSource.local,
    );
    controller.skipRequestKeyboard = false;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.editorKey.currentState?.bringIntoView(
        TextPosition(offset: end),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final count = _matches.isEmpty
        ? (_searched.isEmpty ? '' : '无结果')
        : '${_index + 1}/${_matches.length}';
    return Padding(
      padding: const EdgeInsets.all(8),
      child: SizedBox(
        width: 320,
        child: Row(
          children: [
            Expanded(
              child: FTextField(
                autofocus: true,
                hint: '查找正文',
                textInputAction: TextInputAction.search,
                control: FTextFieldControl.managed(
                  controller: _query,
                  onChange: (value) => _search(value.text),
                ),
                // Enter steps to the next match and keeps the field focused.
                onEditingComplete: () {},
                onSubmit: (_) => _step(1),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              count,
              style: theme.typography.body.xs.copyWith(
                color: theme.colors.mutedForeground,
              ),
            ),
            IconAction(
              icon: FLucideIcons.chevronUp,
              tooltip: '上一个',
              onPress: _matches.isEmpty ? null : () => _step(-1),
            ),
            IconAction(
              icon: FLucideIcons.chevronDown,
              tooltip: '下一个',
              onPress: _matches.isEmpty ? null : () => _step(1),
            ),
            IconAction(
              icon: FLucideIcons.x,
              tooltip: '关闭查找',
              onPress: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}
