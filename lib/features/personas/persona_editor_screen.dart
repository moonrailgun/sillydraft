import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

/// Edits one persona; a null [personaId] starts a new one.
class PersonaEditorScreen extends ConsumerStatefulWidget {
  const PersonaEditorScreen({super.key, this.personaId});
  final String? personaId;
  @override
  ConsumerState<PersonaEditorScreen> createState() => _PersonaEditorState();
}

class _PersonaEditorState extends ConsumerState<PersonaEditorScreen> {
  final _name = TextEditingController(),
      _description = TextEditingController(),
      _appearance = TextEditingController(),
      _outfit = TextEditingController();
  List<TextEditingController> get _fields => [
    _name,
    _description,
    _appearance,
    _outfit,
  ];

  /// Empty until first saved: the repository assigns a new persona's id.
  String _id = '';
  List<PersonaImage> _images = const [];
  bool _loaded = false, _busy = false;

  /// The text fields before the last model fill, for one step back.
  Persona? _undo;

  /// Cancels a model call when the page closes.
  GenerationCancellation? _cancel;

  Persona get _draft => Persona(
    id: _id,
    name: _name.text.trim(),
    description: _description.text,
    appearance: _appearance.text,
    outfit: _outfit.text,
    images: _images,
  );

  void _fill(Persona persona) {
    _name.text = persona.name;
    _description.text = persona.description;
    _appearance.text = persona.appearance;
    _outfit.text = persona.outfit;
    _images = persona.images;
  }

  @override
  void initState() {
    super.initState();
    for (final c in _fields) {
      c.addListener(_changed);
    }
    _load();
  }

  void _changed() => setState(() {});

  Future<void> _load() async {
    final id = widget.personaId;
    final found = id == null
        ? null
        : (await ref.read(repositoryProvider).listPersonas())
              .where((p) => p.id == id)
              .firstOrNull;
    if (!mounted) return;
    if (found != null) {
      _id = found.id;
      _fill(found);
    }
    setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _cancel?.cancel();
    for (final c in _fields) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    _cancel = GenerationCancellation();
    setState(() => _busy = true);
    try {
      await action();
    } on GenerationCancelled {
      // The page closed; nothing left to show.
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _checkRoom() {
    if (_images.length >= Persona.maxImages) {
      throw const FormatException('最多 8 张参考图');
    }
  }

  Future<void> _addImage() => _run(() async {
    _checkRoom();
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: '图片',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          uniformTypeIdentifiers: [
            'public.png',
            'public.jpeg',
            'org.webmproject.webp',
          ],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > AssetLibrary.maxBytes) {
      throw const FormatException('图片不能超过 32 MB');
    }
    final library =
        ref.read(servicesProvider).assets ??
        (throw const FormatException('本地图片目录尚未配置'));
    final prepared = await library.prepare(await file.readAsBytes());
    if (mounted) {
      setState(() => _images = [..._images, PersonaImage.of(prepared)]);
    }
  });

  /// Model results replace the text fields; one step back restores them.
  void _apply(Persona result) {
    if (!mounted) return;
    setState(() {
      _undo = _draft;
      _fill(result);
    });
  }

  Future<ModelConnection> _connection(String role) async =>
      await ref.read(servicesProvider).connectionFor(role) ??
      (throw FormatException(
        role == 'image' ? '请先在设置中配置插画模型' : '请先在设置中配置资料整理模型',
      ));

  Future<void> _describe() => _run(() async {
    _apply(
      await ref
          .read(servicesProvider)
          .personas
          .describeImages(
            await _connection('analysis'),
            _draft,
            cancellation: _cancel,
          ),
    );
  });

  Future<void> _refine() => _run(() async {
    _apply(
      await ref
          .read(servicesProvider)
          .personas
          .refine(await _connection('analysis'), _draft, cancellation: _cancel),
    );
  });

  Future<void> _generateImage() => _run(() async {
    _checkRoom();
    final personas = ref.read(servicesProvider).personas;
    final painter = await _connection('image');
    final drafted = await personas.imagePrompt(
      await _connection('analysis'),
      _draft,
      painter,
      cancellation: _cancel,
    );
    if (!mounted) return;
    final prompt = await askText(
      context,
      title: '参考图提示词',
      initial: drafted,
      label: '提示词',
      maxLines: 6,
    );
    if (prompt == null) return;
    final image = await personas.generateImage(
      painter,
      prompt,
      cancellation: _cancel,
    );
    if (mounted) setState(() => _images = [..._images, image]);
  });

  Future<void> _save() => _run(() async {
    await ref.read(repositoryProvider).savePersona(_draft);
    if (mounted) Navigator.pop(context);
  });

  Future<void> _delete() async {
    if (!await confirmAction(
      context,
      title: '删除人设“${_name.text}”？',
      confirmLabel: '删除',
      destructive: true,
    )) {
      return;
    }
    await _run(() async {
      await ref.read(repositoryProvider).deletePersona(_id);
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    final heading = theme.typography.body.sm.copyWith(
      fontWeight: FontWeight.w600,
    );
    final library = ref.watch(servicesProvider).assets;
    final prompt = _draft.prompt;
    Widget missing() => const SizedBox(
      width: 96,
      height: 96,
      child: Center(child: Text('图片暂不可用')),
    );
    return PageScaffold(
      title: widget.personaId == null ? '新建人设' : '编辑人设',
      actions: [
        if (_id.isNotEmpty && _id != Persona.meId)
          HeaderIconAction(
            tooltip: '删除人设',
            icon: FLucideIcons.trash2,
            onPress: _busy ? null : _delete,
          ),
      ],
      body: !_loaded
          ? const Center(child: FCircularProgress())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                FTextField(
                  control: FTextFieldControl.managed(controller: _name),
                  label: const Text('名字（{{user}}）'),
                ),
                const SizedBox(height: 16),
                FTextField(
                  control: FTextFieldControl.managed(controller: _description),
                  minLines: 2,
                  maxLines: 6,
                  label: const Text('人设描述'),
                ),
                const SizedBox(height: 16),
                FTextField(
                  control: FTextFieldControl.managed(controller: _appearance),
                  minLines: 2,
                  maxLines: 5,
                  label: const Text('外貌'),
                  description: const Text('脸、发型、体型等不随衣着改变的特征'),
                ),
                const SizedBox(height: 16),
                FTextField(
                  control: FTextFieldControl.managed(controller: _outfit),
                  maxLines: 4,
                  label: const Text('默认服饰'),
                ),
                const SizedBox(height: 20),
                Text('参考图', style: heading),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final image in _images)
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: library == null
                                ? missing()
                                : Image.file(
                                    library.hashFile(
                                      image.thumbnailHash,
                                      thumbnail: true,
                                    ),
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.cover,
                                    semanticLabel: '参考图',
                                    errorBuilder: (_, _, _) => missing(),
                                  ),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: IconAction(
                              icon: FLucideIcons.x,
                              tooltip: '移除参考图',
                              onPress: _busy
                                  ? null
                                  : () => setState(
                                      () => _images = [
                                        for (final i in _images)
                                          if (i != image) i,
                                      ],
                                    ),
                            ),
                          ),
                        ],
                      ),
                    FButton(
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      prefix: const Icon(FLucideIcons.imagePlus),
                      onPress: _busy ? null : _addImage,
                      child: const Text('添加图片'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FButton(
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      prefix: const Icon(FLucideIcons.scanEye),
                      onPress: _busy || _images.isEmpty ? null : _describe,
                      child: const Text('看图反推'),
                    ),
                    FButton(
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      prefix: const Icon(FLucideIcons.wandSparkles),
                      onPress: _busy ? null : _refine,
                      child: const Text('AI 补全润色'),
                    ),
                    FButton(
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      prefix: const Icon(FLucideIcons.sparkles),
                      onPress: _busy ? null : _generateImage,
                      child: const Text('生成参考图'),
                    ),
                    if (_undo != null)
                      FButton(
                        variant: FButtonVariant.ghost,
                        mainAxisSize: MainAxisSize.min,
                        prefix: const Icon(FLucideIcons.undo2),
                        // Images added since stay; only the text goes back.
                        onPress: _busy
                            ? null
                            : () => setState(() {
                                _fill(_undo!.copyWith(images: _images));
                                _undo = null;
                              }),
                        child: const Text('撤销'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text('模型看到的 {{persona}}', style: heading),
                const SizedBox(height: 8),
                Text(prompt.isEmpty ? '（空）' : prompt, style: muted),
                const SizedBox(height: 24),
                FButton(
                  onPress: _busy ? null : _save,
                  child: const Text('保存人设'),
                ),
              ],
            ),
    );
  }
}
