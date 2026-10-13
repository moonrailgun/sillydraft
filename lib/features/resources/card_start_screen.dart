import 'dart:async';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import '../agent/writing_request_screen.dart';
import '../editor/workspace_screen.dart';
import '../html/html_block_view.dart';
import '../html/tavern_host.dart';

class CardStartScreen extends ConsumerStatefulWidget {
  const CardStartScreen({super.key, required this.resourceId});
  final String resourceId;
  @override
  ConsumerState<CardStartScreen> createState() => _CardStartState();
}

class _CardStartState extends ConsumerState<CardStartScreen> {
  final _title = TextEditingController(),
      _user = TextEditingController(text: '主角'),
      _persona = TextEditingController(),
      _opening = TextEditingController();
  CharacterCard? _card;
  int _greeting = 0;
  String _pov = '第三人称';
  bool _edited = false, _busy = false;
  Object? _error;
  DateTime _openingClock = DateTime.now().toUtc();

  /// Card rules and metadata the HTML preview reads.
  DisplayContext _display = DisplayContext.empty;

  /// The opening after display regex, and the HTML blocks found in it.
  String _shown = '';
  List<HtmlBlock> _blocks = const [];
  PreviewChatBackend? _preview;
  final _bus = HtmlEventBus();
  Timer? _previewTimer;

  /// Text an interface sent with `/send` before the novel existed.
  String? _pendingBrief;

  /// Whether the opening source is unfolded under the preview.
  bool _sourceOpen = false;

  /// The last text each field reported, so cursor moves and programmatic
  /// updates are not taken for typing.
  final _seen = <TextEditingController, String>{};

  /// Calls [onEdit] when [controller]'s text changed since it was last seen:
  /// Material's `onChanged`, for forui's controller-level `onChange`.
  ValueChanged<TextEditingValue> _onEdit(
    TextEditingController controller,
    VoidCallback onEdit,
  ) => (value) {
    if (_seen[controller] == value.text) return;
    _seen[controller] = value.text;
    onEdit();
  };

  /// Sets the opening without counting it as the author's edit.
  void _setOpening(String text) {
    _seen[_opening] = text;
    _opening.text = text;
  }

  @override
  void initState() {
    super.initState();
    for (final c in [_title, _user, _persona, _opening]) {
      _seen[c] = c.text;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final card = await ref
          .read(servicesProvider)
          .library
          .character(widget.resourceId);
      if (!mounted) return;
      _title.text = '${card.name}的故事';
      _display = DisplayContext.fromCard(card.raw, cardId: widget.resourceId);
      setState(() => _card = card);
      _refreshOpening();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, String> _macroValues(CharacterCard card) => {
    'char': card.name,
    'user': _user.text.trim(),
    'description': card.description,
    'personality': card.personality,
    'scenario': card.scenario,
    'persona': _persona.text,
  };

  MacroEngine _macros(CharacterCard card) =>
      MacroEngine(values: _macroValues(card), clock: _openingClock, seed: 0);

  void _refreshOpening() {
    final card = _card;
    if (card == null) return;
    _openingClock = DateTime.now().toUtc();
    final macros = _macros(card);
    _setOpening(macros.render(card.greetings[_greeting]));
    _edited = false;
    _error =
        macros.diagnostics.any((d) => d.severity == DiagnosticSeverity.error)
        ? FormatException(macros.diagnostics.map((d) => d.message).join('\n'))
        : null;
    _updatePreview();
  }

  /// Re-reads the opening as the reader would show it and prepares the
  /// preview bridge: the greetings are message 0's swipes, so an opening
  /// page's "switch to the second greeting" button works before the novel
  /// exists.
  void _updatePreview() {
    final card = _card;
    if (card == null) return;
    _display = DisplayContext.fromCard(
      card.raw,
      cardId: widget.resourceId,
      userName: _user.text.trim(),
      persona: _persona.text,
      greetingIndex: _greeting,
    );
    final shown = ManuscriptPresentation.fromRules(
      ManuscriptContent.plainText(_opening.text),
      rules: _display.rules,
      macros: _macros(card),
      strict: false,
    ).content.text;
    final greetings = [for (final g in card.greetings) _macros(card).render(g)];
    final preview = _preview ??= PreviewChatBackend(
      greetings: greetings,
      greetingIndex: _greeting,
      context: _display,
      onGreetingChanged: (index) {
        if (!mounted || index == _greeting) return;
        _greeting = index;
        _refreshOpening();
      },
      onOpeningEdited: (text) {
        if (!mounted) return;
        _setOpening(text);
        _edited = true;
        _updatePreview();
      },
    );
    preview
      ..greetings = greetings
      ..greetingIndex = _greeting
      ..context = _display
      ..openingText = _edited ? _opening.text : null;
    setState(() {
      _shown = shown;
      _blocks = HtmlBlocks.find(shown);
    });
  }

  void _sourceEdited() {
    _edited = true;
    _error = null;
    _previewTimer?.cancel();
    _previewTimer = Timer(const Duration(milliseconds: 600), _updatePreview);
    setState(() {});
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    for (final c in [_title, _user, _persona, _opening]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      final novel = await repo.createNovelFromCard(
        resourceId: widget.resourceId,
        title: _title.text,
        userName: _user.text.trim(),
        persona: _persona.text,
        pointOfView: _pov,
        greetingIndex: _greeting,
        openingOverride: _edited ? _opening.text : null,
        openingClock: _openingClock,
      );
      final story = await repo.getStory(novel.activeBranchId);
      final preview = _preview;
      if (preview != null &&
          (preview.chatVariables.isNotEmpty ||
              preview.globalVariables.isNotEmpty) &&
          story.scenes.isNotEmpty) {
        // What the opening interface set before creation becomes the
        // opening scene's variable state.
        final current = await repo.getBranchVariables(novel.activeBranchId);
        await repo.setBranchVariables(
          branchId: novel.activeBranchId,
          sceneId: story.scenes.first.id,
          expectedVersion: current.version,
          local: {...current.local, ...encodeVariables(preview.chatVariables)},
          global: {
            ...current.global,
            ...encodeVariables(preview.globalVariables),
          },
        );
      }
      final services = ref.read(servicesProvider);
      String? artworkWarning;
      if (services.assets != null) {
        try {
          final resource = await services.repository.getResource(
            widget.resourceId,
          );
          if (!resource.filename.toLowerCase().endsWith('.json')) {
            final result = await services.assets!.importCardArtwork(
              branchId: novel.activeBranchId,
              resourceId: widget.resourceId,
              resources: services.library,
            );
            if (result.warnings.isNotEmpty) {
              artworkWarning = result.warnings.join('；');
            }
          }
        } catch (_) {
          artworkWarning = '小说已建立，卡片图片尚未导入。可在插图与素材中重新提取。';
        }
      }
      if (mounted) {
        if (artworkWarning != null) toast(context, artworkWarning);
        final navigator = Navigator.of(context);
        final brief = _pendingBrief;
        unawaited(
          navigator.pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => NovelWorkspace(novelId: novel.id),
            ),
          ),
        );
        if (brief != null && story.scenes.isNotEmpty) {
          final task = await navigator.push<GenerationTask>(
            MaterialPageRoute(
              builder: (_) => WritingRequestScreen(
                scene: story.scenes.first,
                initialBrief: brief,
              ),
            ),
          );
          if (task != null) {
            unawaited(
              navigator.push(
                MaterialPageRoute<void>(
                  builder: (_) => TaskScreen(taskId: task.id),
                ),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onWritingRequest(TavernWritingRequest request) async {
    _pendingBrief = request.brief.isEmpty ? null : request.brief;
    if (!mounted) return;
    toast(
      context,
      _pendingBrief == null ? '创建小说后才能开始生成。' : '已记录界面发出的写作要求，创建小说后会直接打开写作请求。',
    );
  }

  /// The opening as the reader will show it: prose and HTML blocks in
  /// order, the blocks live.
  Widget _previewCard(BuildContext context) => FCard(
    key: const Key('opening-preview'),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.clamp(0.0, 704.0);
          final host = FlutterTavernHost(
            context: () => this.context,
            bus: _bus,
            onWritingRequest: _onWritingRequest,
          );
          final children = <Widget>[
            Row(
              children: [
                const Icon(FLucideIcons.eye, size: 18),
                const SizedBox(width: 8),
                Text(
                  '开场预览',
                  style: context.theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '这个开场包含 HTML 界面，阅读时会在隔离的网页视图中显示。界面里的按钮可以切换开场、设置变量或发出写作要求。',
              style: context.theme.typography.body.sm.copyWith(
                color: context.theme.colors.mutedForeground,
              ),
            ),
            const SizedBox(height: 12),
          ];
          var cursor = 0;
          for (final (i, block) in _blocks.indexed) {
            final before = _shown.substring(cursor, block.start).trim();
            if (before.isNotEmpty) {
              children.add(
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(before),
                ),
              );
            }
            children.add(
              HtmlBlockView(
                key: ValueKey('preview:$i:${block.source.hashCode}'),
                block: block,
                width: width,
                bus: _bus,
                bridge: block.kind == HtmlBlockKind.frontend
                    ? TavernBridge(
                        backend: _preview!,
                        actions: host,
                        messageId: 0,
                        blockIndex: i,
                      )
                    : null,
              ),
            );
            cursor = block.end;
          }
          final after = _shown.substring(cursor).trim();
          if (after.isNotEmpty) {
            children.add(
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(after),
              ),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final htmlEnabled =
        ref.watch(settingProvider('html')).value?['render'] != false;
    final showPreview = htmlEnabled && _blocks.isNotEmpty && _preview != null;
    final openingField = FTextField(
      key: const Key('opening-source'),
      control: FTextFieldControl.managed(
        controller: _opening,
        onChange: _onEdit(_opening, _sourceEdited),
      ),
      minLines: 5,
      maxLines: 14,
      label: const Text('第一幕正文'),
    );
    String greetingLabel(int i) =>
        '${i == 0 ? '默认开场' : '备用开场 $i'} · ${_card!.greetings[i].replaceAll('\n', ' ')}';
    return PageScaffold(
      title: '从角色卡开始故事',
      body: _card == null
          ? (_error == null
                ? const Center(child: FCircularProgress())
                : ErrorPane(message: _error.toString(), retry: _load))
          : SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    '以 ${_card!.name} 为起点',
                    style: theme.typography.body.xl2.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('选中的开场成为第一幕，人物和世界设定存入旁路资料。其他备用开场仍保留在角色卡里。'),
                  if (_display.helperScripts.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    FAlert(
                      key: const Key('helper-scripts-note'),
                      icon: const Icon(FLucideIcons.puzzle),
                      title: Text(
                        '角色卡附带 ${_display.helperScripts.length} 个酒馆助手脚本',
                      ),
                      subtitle: Text(
                        '${_display.helperScripts.map((s) => s.name.isEmpty ? '未命名' : s.name).join('、')}。'
                        'SillyDraft 内置渲染 HTML 界面并提供消息、变量等接口，但不运行脚本库；依赖这些脚本的状态栏或悬浮窗可能不完整。',
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FTextField(
                    control: FTextFieldControl.managed(controller: _title),
                    label: const Text('作品名称'),
                  ),
                  const SizedBox(height: 16),
                  FTextField(
                    control: FTextFieldControl.managed(
                      controller: _user,
                      onChange: _onEdit(_user, _refreshOpening),
                    ),
                    label: const Text('{{user}} 对应的主角名字'),
                  ),
                  const SizedBox(height: 16),
                  FTextField(
                    control: FTextFieldControl.managed(
                      controller: _persona,
                      onChange: _onEdit(_persona, _refreshOpening),
                    ),
                    minLines: 2,
                    maxLines: 4,
                    label: const Text('主角身份 / Persona'),
                  ),
                  const SizedBox(height: 16),
                  FSelect<String>(
                    label: const Text('叙事视角'),
                    items: {
                      for (final v in ['第三人称', '第一人称', '多视角']) v: v,
                    },
                    control: FSelectControl<String>.lifted(
                      value: _pov,
                      onChange: (v) {
                        if (v != null) setState(() => _pov = v);
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  FSelect<int>.rich(
                    key: ValueKey('greeting:$_greeting'),
                    label: const Text('采用哪个开场'),
                    format: greetingLabel,
                    control: FSelectControl<int>.lifted(
                      value: _greeting,
                      onChange: (v) {
                        if (v == null) return;
                        _greeting = v;
                        _refreshOpening();
                      },
                    ),
                    children: [
                      for (var i = 0; i < _card!.greetings.length; i++)
                        FSelectItem<int>(
                          title: Text(
                            greetingLabel(i),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          value: i,
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (showPreview) ...[
                    _previewCard(context),
                    const SizedBox(height: 8),
                    FAccordion(
                      key: const Key('opening-source-tile'),
                      control: FAccordionControl.managed(
                        onChange: (open) =>
                            setState(() => _sourceOpen = open.contains(0)),
                      ),
                      children: [
                        FAccordionItem(
                          title: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('开场源码'),
                              Text(
                                '需要时可以直接编辑',
                                style: theme.typography.body.sm.copyWith(
                                  color: theme.colors.mutedForeground,
                                  fontWeight: FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                          // Built only while unfolded, like the tile it
                          // replaces.
                          child: _sourceOpen
                              ? Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: openingField,
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ] else
                    openingField,
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '开场需要手动调整：$_error',
                        style: TextStyle(color: theme.colors.error),
                      ),
                    ),
                  const SizedBox(height: 24),
                  FButton(
                    onPress: _busy || _error != null ? null : _create,
                    prefix: const Icon(FLucideIcons.bookOpen),
                    child: const Text('创建小说与初始资料'),
                  ),
                ],
              ),
            ),
    );
  }
}
