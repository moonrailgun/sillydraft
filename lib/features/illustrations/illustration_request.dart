import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../agent/task_screen.dart';
import '../settings/settings_screen.dart';
import 'asset_image.dart';
import 'illustration_gallery.dart';

class IllustrationRequestScreen extends ConsumerStatefulWidget {
  const IllustrationRequestScreen({
    super.key,
    required this.branchId,
    this.sceneId,
    this.purpose = AssetPurpose.illustration,
    this.referenceIds = const [],
    this.initialPrompt = '',
  });
  final String branchId;
  final String? sceneId;
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
  late String? _sceneId = widget.sceneId;
  ModelConnection? _connection;
  List<ModelConnection> _connections = [];
  String _size = '', _quality = '';
  bool _busy = false, _loaded = false;
  Object? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final services = ref.read(servicesProvider),
          all = await ref.read(servicesProvider).connections(),
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
    final saved =
        await services.repository.getSetting(
          'imageDefaults/${connection.id}',
        ) ??
        {};
    if (!mounted || _connection?.id != connection.id) return;
    setState(() {
      _size = saved['size'] as String? ?? '';
      _quality = saved['quality'] as String? ?? '';
      _parameters.text = const JsonEncoder.withIndent('  ')
          .convert(saved['parameters'] ?? {});
      _hosts.text = (saved['allowedDownloadHosts'] as List? ?? []).join(', ');
    });
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

  Future<void> _generate() async {
    if (_connection == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
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
          if (_size.isNotEmpty) 'size': _size,
          if (_quality.isNotEmpty) 'quality': _quality,
        },
        allowedDownloadHosts: hosts,
      );
      final services = ref.read(servicesProvider);
      await services.repository.setSetting('imageDefaults/${_connection!.id}', {
        'size': _size,
        'quality': _quality,
        'parameters': extras,
        'allowedDownloadHosts': hosts,
      });
      final task = await services.illustrations.generate(
        branchId: widget.branchId,
        connection: _connection!,
        name: _name.text,
        request: request,
        sceneId: _sceneId,
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('生成插画'),
      actions: [
        IconButton(
          tooltip: '模型设置',
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            );
            if (mounted) _load();
          },
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    ),
    body: !_loaded
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text('插画独立保存。生成完成后，可以插入正文、设为封面或用于地图。'),
              const SizedBox(height: 20),
              if (_connections.isEmpty) const Text('请先在模型设置中添加支持生图的连接。'),
              if (_connections.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey(_connection?.id),
                  initialValue: _connection?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '生图模型'),
                  items: [
                    for (final c in _connections)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text(
                          '${c.name} · ${c.model}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    final c = _connections.firstWhere((c) => c.id == id);
                    setState(() => _connection = c);
                    _defaults(ref.read(servicesProvider), c);
                  },
                ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('illustration-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: '图片名称'),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<AssetPurpose>(
                initialValue: _purpose,
                decoration: const InputDecoration(labelText: '用途'),
                items: [
                  for (final p in AssetPurpose.values)
                    DropdownMenuItem(
                      value: p,
                      child: Text(assetPurposeLabels[p]!),
                    ),
                ],
                onChanged: (v) => setState(() => _purpose = v!),
              ),
              const SizedBox(height: 16),
              AsyncView(
                value: ref.watch(storyProvider(widget.branchId)),
                builder: (story) => DropdownButtonFormField<String>(
                  initialValue: _sceneId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '对应正文场景（可选）'),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('独立素材'),
                    ),
                    for (final s in story.scenes)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text(s.title, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _sceneId = v),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('illustration-prompt'),
                controller: _prompt,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(
                  labelText: '画面描述',
                  hintText: '主体、动作、环境、光线、画风，以及需要保持的人物特征',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('size:$_size'),
                initialValue: _size,
                decoration: const InputDecoration(labelText: '尺寸'),
                items: [
                  for (final s in [
                    '',
                    'auto',
                    '1024x1024',
                    '1536x1024',
                    '1024x1536',
                  ])
                    DropdownMenuItem(
                      value: s,
                      child: Text(s.isEmpty ? '由模型决定' : s),
                    ),
                ],
                onChanged: (v) => setState(() => _size = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: ValueKey('quality:$_quality'),
                initialValue: _quality,
                decoration: const InputDecoration(labelText: '质量'),
                items: [
                  for (final s in ['', 'auto', 'low', 'medium', 'high'])
                    DropdownMenuItem(
                      value: s,
                      child: Text(
                        const {
                          '': '由模型决定',
                          'auto': '自动',
                          'low': '低',
                          'medium': '中',
                          'high': '高',
                        }[s]!,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _quality = v!),
              ),
              const SizedBox(height: 20),
              Text(
                '参考图片 · ${_references.length}/16',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_references.isNotEmpty)
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
                                  child: AssetImageView(
                                    assetId: id,
                                    thumbnail: true,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                Positioned(
                                  right: 0,
                                  top: 0,
                                  child: IconButton(
                                    tooltip: '移除参考图',
                                    onPressed: () =>
                                        setState(() => _references.remove(id)),
                                    icon: const Icon(Icons.close),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              TextButton.icon(
                onPressed: _references.length >= 16 ? null : _reference,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('选择或导入参考图'),
              ),
              if (_references.isNotEmpty)
                const Text('参考图会发送给选定的生图服务，作为图片编辑请求。'),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('高级参数'),
                children: [
                  TextField(
                    controller: _parameters,
                    minLines: 3,
                    maxLines: 9,
                    decoration: const InputDecoration(
                      labelText: '额外参数 JSON',
                      helperText: '例如 output_format、seed；支持范围由连接决定',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _hosts,
                    decoration: const InputDecoration(
                      labelText: '图片下载域名（可选）',
                      helperText: '服务返回图片链接时使用，多个域名以逗号分隔',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _error.toString(),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy || _connection == null ? null : _generate,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(_busy ? '创建任务中…' : '开始生成'),
              ),
            ],
          ),
  );
}
