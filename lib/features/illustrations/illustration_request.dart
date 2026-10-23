import 'dart:convert';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/model_select.dart';
import 'asset_image.dart';
import 'illustration_gallery.dart';

class IllustrationRequestScreen extends ConsumerStatefulWidget {
  const IllustrationRequestScreen({
    super.key,
    required this.branchId,
    this.chapterId,
    this.purpose = AssetPurpose.illustration,
    this.referenceIds = const [],
    this.initialPrompt = '',
  });
  final String branchId;
  final String? chapterId;
  final AssetPurpose purpose;
  final List<String> referenceIds;
  final String initialPrompt;
  @override
  ConsumerState<IllustrationRequestScreen> createState() => _RequestState();
}

class _RequestState extends ConsumerState<IllustrationRequestScreen> {
  final _name = TextEditingController(text: '新的插画'),
      _parameters = TextEditingController(text: '{}'),
      _hosts = TextEditingController();
  late final _prompt = TextEditingController(text: widget.initialPrompt);
  late final _references = [...widget.referenceIds];
  late AssetPurpose _purpose = widget.purpose;
  late String? _chapterId = widget.chapterId;
  ModelConnection? _connection;
  List<ModelConnection> _connections = [];
  String _size = '', _quality = '';
  bool _busy = false, _loaded = false;
  bool _loadingDefaults = false;
  Object? _error;
  bool get _comfy => _connection?.protocol == ModelProtocol.comfyUI;
  bool get _novelAI => _connection?.protocol == ModelProtocol.novelAI;
  bool get _codex => _connection?.protocol == ModelProtocol.codexCli;
  int get _referenceLimit =>
      _connection == null ? 0 : referenceLimit(_connection!);
  bool get _canReference => _referenceLimit > 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = ref.read(servicesProvider),
          all = (await ref.read(servicesProvider).connections())
              .where((c) => connectionServes(c, 'image'))
              .toList(),
          selected = await ref.read(servicesProvider).connectionFor('image');
      if (!mounted) return;
      setState(() {
        _connections = all;
        _connection = selected;
        _loaded = true;
      });
      if (selected != null) await _defaults(services, selected);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loaded = true;
        });
      }
    }
  }

  Future<void> _defaults(
    AppServices services,
    ModelConnection connection,
  ) async {
    setState(() => _loadingDefaults = true);
    bool current() =>
        mounted &&
        _connection?.id == connection.id &&
        _connection?.model == connection.model;
    try {
      final saved = await services.illustrations.savedDefaults(connection);
      if (!current()) return;
      setState(() {
        _size = saved['size'] as String? ?? '';
        _quality = saved['quality'] as String? ?? '';
        _parameters.text = const JsonEncoder.withIndent('  ')
            .convert(saved['parameters'] ?? {});
        _hosts.text = (saved['allowedDownloadHosts'] as List? ?? []).join(', ');
      });
    } catch (e) {
      if (current()) setState(() => _error = e);
    } finally {
      if (current()) setState(() => _loadingDefaults = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _prompt, _parameters, _hosts]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _reference() async {
    final asset = await Navigator.push<StoryAsset>(
      context,
      MaterialPageRoute(
        builder: (_) => IllustrationGallery(
          branchId: widget.branchId,
          picker: true,
          purpose: AssetPurpose.reference,
        ),
      ),
    );
    if (asset != null && mounted && !_references.contains(asset.id)) {
      setState(() => _references.add(asset.id));
    }
  }

  /// Picks a character with portraits and adds the first one not chosen yet.
  Future<void> _characterReference() async {
    try {
      final characters = [
        for (final entry
            in await ref
                .read(repositoryProvider)
                .listLore(
                  widget.branchId,
                  throughChapterId: _chapterId,
                  kind: LoreKind.character,
                ))
          if ((entry.data['images'] as List? ?? const []).isNotEmpty) entry,
      ];
      if (!mounted) return;
      if (characters.isEmpty) {
        toast(context, '还没有带形象图的人物，可在资料页的人物条目里添加。');
        return;
      }
      final picked = await showAppSheet<LoreEntry>(
        context: context,
        title: '选择人物形象图',
        builder: (context) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            for (final character in characters)
              FItem(
                key: Key('character-reference-${character.id}'),
                prefix: SizedBox(
                  width: 40,
                  height: 40,
                  child: AssetImageView(
                    assetId: (character.data['images'] as List).first as String,
                    thumbnail: true,
                    fit: BoxFit.cover,
                  ),
                ),
                title: Text(character.name),
                onPress: () => Navigator.pop(context, character),
              ),
          ],
        ),
      );
      if (picked == null || !mounted) return;
      final next = (picked.data['images'] as List)
          .cast<String>()
          .where((id) => !_references.contains(id))
          .firstOrNull;
      if (next == null) {
        toast(context, '这个人物的形象图都已添加');
      } else {
        setState(() => _references.add(next));
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _generate() async {
    if (_connection == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_references.length > _referenceLimit ||
          (_references.isNotEmpty && !_canReference)) {
        throw FormatException(
          _novelAI
              ? 'NovelAI 连接目前仅支持文生图，请移除参考图'
              : _canReference
              ? '当前模型最多使用 $_referenceLimit 张参考图'
              : '请先在 ComfyUI 模型设置中添加图生图工作流',
        );
      }
      final extras = jsonDecode(_parameters.text);
      if (extras is! Map<String, dynamic>) {
        throw const FormatException('额外参数须为 JSON 对象');
      }
      final hosts = _hosts.text
          .split(RegExp(r'[,，\s]+'))
          .where((h) => h.isNotEmpty)
          .toList();
      if (hosts.any(
        (h) => h.contains('/') || h.contains(':') || h.contains('@'),
      )) {
        throw const FormatException('图片下载域名只填写主机名，例如 images.example.com');
      }
      final request = ImageRequest(
        prompt: _prompt.text,
        parameters: {
          ...extras,
          if (!_comfy && _size.isNotEmpty) 'size': _size,
          if (!_comfy && !_novelAI && _quality.isNotEmpty) 'quality': _quality,
        },
        allowedDownloadHosts: hosts,
      );
      final services = ref.read(servicesProvider);
      await services.repository.setSetting(
        'imageDefaults/${_connection!.id}/${Uri.encodeComponent(_connection!.model)}',
        {
          'size': _size,
          'quality': _quality,
          'parameters': extras,
          'allowedDownloadHosts': hosts,
        },
      );
      final task = await services.illustrations.generate(
        branchId: widget.branchId,
        connection: _connection!,
        name: _name.text,
        request: request,
        chapterId: _chapterId,
        referenceAssetIds: _references,
        purpose: _purpose,
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(builder: (_) => TaskScreen(taskId: task.id)),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Quality choices and how they read.
  static const _qualities = {
    '': '由模型决定',
    'auto': '自动',
    'low': '低',
    'medium': '中',
    'high': '高',
  };

  /// A select over [options] (value → label). A saved value that is no
  /// longer offered still shows as itself.
  Widget _choice({
    required String label,
    required String value,
    required Map<String, String> options,
    required ValueChanged<String> onChange,
  }) => FSelect<String>.rich(
    label: Text(label),
    control: FSelectControl.lifted(
      value: value,
      onChange: (v) {
        if (v != null) onChange(v);
      },
    ),
    format: (v) => options[v] ?? v,
    children: [
      for (final MapEntry(:key, :value) in options.entries)
        FSelectItem(title: Text(value), value: key),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return PageScaffold(
      title: '生成插画',
      actions: [
        HeaderIconAction(
          tooltip: '模型设置',
          icon: FLucideIcons.settings,
          onPress: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            );
            if (mounted) _load();
          },
        ),
      ],
      body: !_loaded
          ? const Center(child: FCircularProgress())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text('插画独立保存。生成完成后，可以插入正文、设为封面或用于地图。'),
                const SizedBox(height: 20),
                if (_connections.isEmpty) const Text('请先在模型设置中添加支持生图的连接。'),
                if (_connections.isNotEmpty)
                  ConnectionModelSelect(
                    key: const Key('illustration-model'),
                    label: '生图模型',
                    connections: _connections,
                    value: _connection,
                    enabled: !_busy,
                    onChange: (c) {
                      setState(() => _connection = c);
                      _defaults(ref.read(servicesProvider), c);
                    },
                  ),
                const SizedBox(height: 16),
                FTextField(
                  key: const Key('illustration-name'),
                  control: FTextFieldControl.managed(controller: _name),
                  label: const Text('图片名称'),
                ),
                const SizedBox(height: 16),
                FSelect<AssetPurpose>(
                  label: const Text('用途'),
                  control: FSelectControl.lifted(
                    value: _purpose,
                    onChange: (v) {
                      if (v != null) setState(() => _purpose = v);
                    },
                  ),
                  items: {
                    for (final p in AssetPurpose.values)
                      assetPurposeLabels[p]!: p,
                  },
                ),
                const SizedBox(height: 16),
                AsyncView(
                  value: ref.watch(storyProvider(widget.branchId)),
                  // An empty id stands for "no chapter": a standalone asset.
                  builder: (story) => FSelect<String>.rich(
                    label: const Text('对应正文章节（可选）'),
                    control: FSelectControl.lifted(
                      value: _chapterId ?? '',
                      onChange: (v) {
                        if (v != null) {
                          setState(() => _chapterId = v.isEmpty ? null : v);
                        }
                      },
                    ),
                    format: (id) => id.isEmpty
                        ? '独立素材'
                        : story.chapters
                                  .where((s) => s.id == id)
                                  .firstOrNull
                                  ?.title ??
                              '',
                    children: [
                      FSelectItem(title: const Text('独立素材'), value: ''),
                      for (final s in story.chapters)
                        FSelectItem(
                          title: Text(s.title, overflow: TextOverflow.ellipsis),
                          value: s.id,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                FTextField(
                  key: const Key('illustration-prompt'),
                  control: FTextFieldControl.managed(controller: _prompt),
                  minLines: 5,
                  maxLines: 12,
                  label: const Text('画面描述'),
                  hint: '主体、动作、环境、光线、画风，以及需要保持的人物特征',
                ),
                const SizedBox(height: 16),
                if (!_comfy)
                  _choice(
                    label: '尺寸',
                    value: _size,
                    options: _novelAI
                        ? const {
                            '': '默认 1024x1024',
                            '1024x1024': '1024x1024',
                            '832x1216': '832x1216',
                            '1216x832': '1216x832',
                          }
                        : const {
                            '': '由模型决定',
                            'auto': 'auto',
                            '1024x1024': '1024x1024',
                            '1536x1024': '1536x1024',
                            '1024x1536': '1024x1536',
                          },
                    onChange: (v) => setState(() => _size = v),
                  ),
                const SizedBox(height: 16),
                if (!_comfy && !_novelAI)
                  _choice(
                    label: '质量',
                    value: _quality,
                    options: _qualities,
                    onChange: (v) => setState(() => _quality = v),
                  ),
                const SizedBox(height: 20),
                if (_comfy) ...[
                  const Text(
                    '尺寸与采样参数沿用 ComfyUI 工作流。每次生成使用新的随机种子，也可在高级参数中指定 seed。取消会停止等待，服务端可能继续执行。',
                  ),
                  const SizedBox(height: 16),
                ],
                if (_novelAI) ...[
                  const Text(
                    'NovelAI 目前仅支持文生图。高级参数可设置 negative_prompt、steps、scale、seed、sampler、noise_schedule。取消只停止等待，服务端可能继续生成并计费。',
                  ),
                  const SizedBox(height: 16),
                ],
                if (_codex) ...[
                  const Text(
                    '使用 Codex 订阅额度。尺寸和质量作为画面要求，不保证精确像素；高级参数仅支持 negative_prompt。取消后已开始的生成仍可能消耗额度。',
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  '参考图片 · ${_references.length}/$_referenceLimit',
                  style: theme.typography.body.md.copyWith(
                    color: theme.colors.foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (_references.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 115,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final id in _references)
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: SizedBox(
                              width: 100,
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: ClipRRect(
                                      borderRadius: theme.style.borderRadius.md,
                                      child: AssetImageView(
                                        assetId: id,
                                        thumbnail: true,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 4,
                                    top: 4,
                                    child: IconAction(
                                      tooltip: '移除参考图',
                                      icon: FLucideIcons.x,
                                      variant: FButtonVariant.secondary,
                                      onPress: () => setState(
                                        () => _references.remove(id),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FButton(
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress:
                          !_canReference ||
                              _references.length >= _referenceLimit
                          ? null
                          : _reference,
                      prefix: const Icon(FLucideIcons.imagePlus),
                      child: const Text('选择或导入参考图'),
                    ),
                    FButton(
                      key: const Key('pick-character-reference'),
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress:
                          !_canReference ||
                              _references.length >= _referenceLimit
                          ? null
                          : _characterReference,
                      prefix: const Icon(FLucideIcons.user),
                      child: const Text('选择人物形象图'),
                    ),
                  ],
                ),
                if (!_canReference && !_novelAI)
                  const Text('此连接未配置图生图工作流，可在模型设置中添加。'),
                if (_references.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '参考图会发送给选定的生图服务，作为图片编辑请求。',
                      style: theme.typography.body.xs.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                FAccordion(
                  children: [
                    FAccordionItem(
                      title: const Text('高级参数'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FTextField(
                            control: FTextFieldControl.managed(
                              controller: _parameters,
                            ),
                            minLines: 3,
                            maxLines: 9,
                            label: const Text('额外参数 JSON'),
                            description: Text(
                              _comfy
                                  ? '例如 {"seed": 123}；其他参数在工作流中配置'
                                  : _novelAI
                                  ? '例如 {"negative_prompt": "blurry", "steps": 28, "scale": 5, "seed": 123}'
                                  : _codex
                                  ? '例如 {"negative_prompt": "文字、水印"}；不支持 seed 和采样步数'
                                  : '例如 output_format、seed；支持范围由连接决定',
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (!_comfy && !_novelAI && !_codex)
                            FTextField(
                              control: FTextFieldControl.managed(
                                controller: _hosts,
                              ),
                              label: const Text('图片下载域名（可选）'),
                              description: const Text('服务返回图片链接时使用，多个域名以逗号分隔'),
                            ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _error.toString(),
                      style: TextStyle(color: theme.colors.error),
                    ),
                  ),
                const SizedBox(height: 16),
                FButton(
                  onPress: _busy || _loadingDefaults || _connection == null
                      ? null
                      : _generate,
                  prefix: const Icon(FLucideIcons.sparkles),
                  child: Text(_busy ? '创建任务中…' : '开始生成'),
                ),
              ],
            ),
    );
  }
}
