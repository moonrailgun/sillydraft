import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../illustrations/illustration_gallery.dart';
import '../illustrations/asset_image.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/writing_request_screen.dart';
import '../agent/task_screen.dart';

class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({super.key, required this.scene});
  final Scene scene;
  @override
  ConsumerState<EditorScreen> createState() => _EditorState();
}

class _EditorState extends ConsumerState<EditorScreen> {
  late Scene _scene;
  late QuillController _controller;
  final _focus = FocusNode(), _scroll = ScrollController();
  Timer? _debounce;
  Future<void>? _saving;
  late String _saved;
  Object? _error;
  bool _allowPop = false;
  late final AppServices _services;
  @override
  void initState() {
    super.initState();
    _scene = widget.scene;
    _controller = QuillController(
      document: Document.fromJson(_scene.content.delta),
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
        final saved = await _services.repository.saveScene(
          branchId: _scene.branchId,
          sceneId: _scene.id,
          expectedRevisionId: _scene.revisionId,
          content: content,
        );
        _scene = saved;
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
        branchId: _scene.branchId,
        sceneId: _scene.id,
        baseRevisionId: _scene.revisionId,
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
        branchId: _scene.branchId,
        sceneId: _scene.id,
      );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .65,
            child: ListView(
              children: [
                const ListTile(
                  title: Text(
                    '正文版本',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text('恢复会保存为新版本，现有历史会保留。'),
                ),
                for (final version in history)
                  ListTile(
                    title: Text(
                      '${dateLabel(version.createdAt)} ${version.createdAt.toLocal().toString().substring(11, 16)} · ${version.reason}',
                    ),
                    subtitle: Text(
                      version.content.text.replaceAll('\n', ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: version.id == _scene.revisionId
                        ? const Text('当前')
                        : TextButton(
                            onPressed: () async {
                              try {
                                final restored = await _services.repository
                                    .restoreRevision(
                                      branchId: _scene.branchId,
                                      sceneId: _scene.id,
                                      expectedRevisionId: _scene.revisionId,
                                      revisionId: version.id,
                                    );
                                if (!mounted) return;
                                _scene = restored;
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
          ),
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
      final end = selection.end.clamp(0, _scene.content.text.length - 1);
      final start = selection.start.clamp(0, end);
      final task = await Navigator.push<GenerationTask>(
        context,
        MaterialPageRoute(
          builder: (_) => WritingRequestScreen(
            scene: _scene,
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
        // A proposal may have been accepted while this editor was covered.
        final latest = await _services.repository.getScene(
          branchId: _scene.branchId,
          sceneId: _scene.id,
        );
        if (mounted &&
            latest.revisionId != _scene.revisionId &&
            _content.encoded == _saved) {
          _scene = latest;
          _controller.document = Document.fromJson(latest.content.delta);
          _saved = _content.encoded;
          setState(() {});
        }
      }
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
              IllustrationGallery(branchId: _scene.branchId, picker: true),
        ),
      );
      if (asset == null) return;
      final scene = await _services.repository.insertIllustration(
        branchId: _scene.branchId,
        sceneId: _scene.id,
        expectedRevisionId: _scene.revisionId,
        assetId: asset.id,
        offset: offset,
      );
      if (mounted) {
        _scene = scene;
        _controller.document = Document.fromJson(scene.content.delta);
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
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '保存并返回',
            onPressed: _leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _scene.title.isEmpty ? '正文编辑' : _scene.title,
                style: const TextStyle(fontSize: 17),
              ),
              Text(
                _error != null
                    ? '保存遇到问题'
                    : _saving != null
                    ? '正在保存…'
                    : dirty
                    ? '尚未保存'
                    : '已保存到设备',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '插入图片',
              onPressed: _insertImage,
              icon: const Icon(Icons.image_outlined),
            ),
            IconButton(
              tooltip: '生成或改写选区',
              onPressed: _generate,
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              tooltip: '正文版本',
              onPressed: _history,
              icon: const Icon(Icons.history_rounded),
            ),
            IconButton(
              tooltip: '立即保存',
              onPressed: () async {
                try {
                  await _flush();
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              icon: const Icon(Icons.check_rounded),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              if (_error != null)
                MaterialBanner(
                  content: Text(_error.toString()),
                  actions: [
                    TextButton(
                      onPressed: _saveProposal,
                      child: const Text('另存为候选'),
                    ),
                    TextButton(
                      onPressed: () =>
                          unawaited(_flush().catchError((Object _) {})),
                      child: const Text('重试保存'),
                    ),
                  ],
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
                      config: const QuillEditorConfig(
                        embedBuilders: [LocalImageEmbedBuilder()],
                        padding: EdgeInsets.fromLTRB(24, 28, 24, 80),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 4,
                  ),
                  child: Text(
                    '${countCharacters(_controller.document.toPlainText())} 字',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
              const Divider(height: 1),
              QuillSimpleToolbar(
                controller: _controller,
                config: const QuillSimpleToolbarConfig(
                  multiRowsDisplay: false,
                  showFontFamily: false,
                  showFontSize: false,
                  showSmallButton: false,
                  showStrikeThrough: false,
                  showInlineCode: false,
                  showColorButton: false,
                  showBackgroundColorButton: false,
                  showListCheck: false,
                  showCodeBlock: false,
                  showIndent: false,
                  showLink: false,
                  showSubscript: false,
                  showSuperscript: false,
                  showSearchButton: true,
                  showHeaderStyle: true,
                  showClearFormat: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
