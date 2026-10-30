import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../illustrations/asset_image.dart';
import '../illustrations/illustration_detail.dart';
import '../illustrations/illustration_gallery.dart';
import 'lore_providers.dart';
import '../resources/resource_library_screen.dart';

class LoreEditScreen extends ConsumerStatefulWidget {
  const LoreEditScreen({
    super.key,
    required this.branchId,
    this.entry,
    this.atChapterId,
    this.kind = LoreKind.world,
  });
  final String branchId;
  final LoreEntry? entry;
  final String? atChapterId;
  final LoreKind kind;
  @override
  ConsumerState<LoreEditScreen> createState() => _LoreEditState();
}

class _LoreEditState extends ConsumerState<LoreEditScreen> {
  late final _name = TextEditingController(text: widget.entry?.name),
      _content = TextEditingController(text: widget.entry?.content);
  late final _appearance = TextEditingController(
        text: widget.entry?.data['appearance'] as String?,
      ),
      _goal = TextEditingController(
        text: widget.entry?.data['goal'] as String?,
      ),
      _time = TextEditingController(
        text: widget.entry?.data['storyTime'] as String?,
      );
  late final _outfit = TextEditingController(
        text: widget.entry?.data['outfit'] as String?,
      ),
      _state = TextEditingController(
        text: widget.entry?.data['state'] as String?,
      );
  late final _referencePrompt = TextEditingController(
    text:
        widget.entry?.data['referencePrompt'] as String? ??
        (widget.entry?.kind == LoreKind.location
            ? widget.entry?.content
            : [
                widget.entry?.data['appearance'],
                widget.entry?.data['outfit'],
              ].whereType<String>().join(', ')),
  );
  late final List<String> _images = [
    ...(widget.entry?.data['images'] as List? ?? const []).cast<String>(),
  ];
  late final bool _user = widget.entry?.data['user'] == true;
  bool get _full => _images.length >= maxCharacterImages;
  late LoreKind _kind = widget.entry?.kind ?? widget.kind;
  late LoreCertainty _certainty = widget.entry?.certainty ?? LoreCertainty.fact;
  late String? _chapterId = widget.atChapterId ?? widget.entry?.atChapterId,
      _from = widget.entry?.data['fromId'] as String?,
      _to = widget.entry?.data['toId'] as String?;
  late String _status = widget.entry?.data['status'] as String? ?? 'active';
  late bool _directed = widget.entry?.data['directed'] != false;
  bool _busy = false, _rechecked = false;
  final _routingCancellation = GenerationCancellation();
  @override
  void dispose() {
    _routingCancellation.cancel();
    for (final c in [
      _name,
      _content,
      _appearance,
      _goal,
      _time,
      _outfit,
      _state,
      _referencePrompt,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool deleted = false}) async {
    setState(() => _busy = true);
    try {
      if (!deleted &&
          _images.isNotEmpty &&
          [LoreKind.character, LoreKind.location].contains(_kind) &&
          _referencePrompt.text.trim().isEmpty) {
        throw const FormatException('请填写与参考图对应的固定外观描述');
      }
      final repo = ref.read(repositoryProvider);
      // A copy: a save that fails leaves the open entry as it was.
      var provenance = {...?widget.entry?.provenance};
      if (provenance.isEmpty) provenance = {'type': 'manual'};
      if (_rechecked && provenance['chapterId'] is String) {
        final source = await repo.getChapter(
          branchId: widget.branchId,
          chapterId: provenance['chapterId'] as String,
        );
        provenance['revisionId'] = source.revisionId;
        provenance['reviewedAt'] = DateTime.now().toUtc().toIso8601String();
      } else if (provenance['type'] == 'sidecar') {
        // The author's edit makes the note theirs: the sidecar no longer
        // redoes it, and it never goes stale with the chapter.
        provenance = {'type': 'manual'};
      }
      final entry = await repo.saveLoreEntry(
        branchId: widget.branchId,
        id: widget.entry?.id,
        expectedRevisionId: widget.entry?.revisionId,
        kind: _kind,
        name: _name.text,
        content: _content.text,
        certainty: _certainty,
        atChapterId: _chapterId,
        deleted: deleted,
        data: {
          ...?widget.entry?.data,
          'status': _status,
          if (_kind == LoreKind.character) ...{
            'appearance': _appearance.text,
            'goal': _goal.text,
            'outfit': _outfit.text,
            'state': _state.text,
          },
          if ([LoreKind.character, LoreKind.location].contains(_kind)) ...{
            'images': _images,
            'referencePrompt': _referencePrompt.text.trim(),
          },
          if (_kind == LoreKind.event || _kind == LoreKind.foreshadow)
            'storyTime': _time.text,
          if (_kind == LoreKind.relationship) ...{
            'fromId': _from,
            'toId': _to,
            'directed': _directed,
          },
        },
        provenance: provenance,
      );
      if (mounted) Navigator.pop(context, entry);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Adds what [pick] returns to the portraits, up to the limit.
  Future<void> _addImages(Future<List<String>> Function() pick) async {
    setState(() => _busy = true);
    try {
      final ids = await pick();
      if (mounted) {
        setState(
          () => _images.addAll(
            ids
                .where((id) => !_images.contains(id))
                .take(maxCharacterImages - _images.length),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() => _addImages(() async {
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
    return [?asset?.id];
  });

  /// Drafts a prompt from the looks, lets the author adjust it, then draws
  /// with the image engine, the first portrait as reference when it takes one.
  Future<void> _generateImage() => _addImages(() async {
    final services = ref.read(servicesProvider);
    final painter = await services.connectionFor('image');
    if (painter == null) throw const FormatException('请先在设置中配置插画模型');
    final writer = await services.connectionFor('analysis');
    if (writer == null) throw const FormatException('请先在设置中配置资料整理模型');
    var drafted = _referencePrompt.text.trim();
    if (drafted.isEmpty && _kind == LoreKind.character) {
      drafted = PersonaService.imageDescription(
        Persona(
          id: '',
          name: _name.text,
          appearance: _appearance.text,
          outfit: _outfit.text,
        ),
      );
    } else if (drafted.isEmpty) {
      drafted = _content.text;
    }
    if (!mounted) return const [];
    final prompt = await askText(
      context,
      title: '参考图外观描述',
      initial: drafted,
      label: '画面描述（确认后自动选择引擎并编写提示词）',
      maxLines: 6,
    );
    if (prompt == null) return const [];
    if (prompt.trim().isEmpty) throw const FormatException('请填写固定外观描述');
    final task = await services.illustrations.generate(
      branchId: widget.branchId,
      connection: painter,
      promptConnection: writer,
      nsfwConnection: await services.connectionFor('imageNsfw'),
      cancellation: _routingCancellation,
      name: '${_name.text.trim()} · 参考图',
      request: IllustrationService.requestFrom(
        painter,
        _kind == LoreKind.location
            ? 'Empty location, no people. $prompt'
            : prompt,
        await services.illustrations.savedDefaults(painter),
      ),
      visualReferences: [
        if (_images.isNotEmpty)
          VisualReference(
            kind: _kind,
            name: _name.text.trim(),
            prompt: prompt,
            assetId: _images.first,
          ),
      ],
      purpose: AssetPurpose.reference,
    );
    final done = await services.runner.wait(task.id);
    if (done.result['assetId'] case final String id) {
      _referencePrompt.text = prompt;
      return [id];
    }
    throw FormatException(done.error.isEmpty ? '参考图没有生成' : done.error);
  });

  /// The protagonist's portraits from the persona this branch binds.
  Future<void> _importPersona() => _addImages(() async {
    final services = ref.read(servicesProvider), library = services.assets;
    if (library == null) throw const FormatException('本地图片目录尚未配置');
    final persona = await services.repository.personaFor(
      await services.repository.getSetting('writing/${widget.branchId}') ??
          const {},
    );
    // Only what will be kept is imported, so no orphan assets are left.
    final have = {
      for (final id in _images) (await services.repository.getAsset(id)).hash,
    };
    return [
      for (final image
          in persona.images
              .where((i) => !have.contains(i.hash))
              .take(maxCharacterImages - _images.length))
        (await library.importImage(
          branchId: widget.branchId,
          name: '${persona.name} · 人设图',
          bytes: await library.readHash(image.hash),
          purpose: AssetPurpose.reference,
        )).id,
    ];
  });

  Widget _portraits() {
    final theme = context.theme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_kind == LoreKind.location ? '场景参考图' : '形象图'} · ${_images.length}/$maxCharacterImages',
          style: theme.typography.body.md.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '参考图与外观描述共同固定人物或地点。纯文生图使用同一份描述；修改描述时请同步调整参考图。',
          style: theme.typography.body.xs.copyWith(
            color: theme.colors.mutedForeground,
          ),
        ),
        if (_images.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 115,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final id in _images)
                  Padding(
                    key: Key('character-image-$id'),
                    padding: const EdgeInsets.only(right: 10),
                    child: SizedBox(
                      width: 100,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              onTap: () => showIllustrationDetail(
                                context,
                                assetId: id,
                                branchId: widget.branchId,
                              ),
                              child: ClipRRect(
                                borderRadius: theme.style.borderRadius.md,
                                child: AssetImageView(
                                  assetId: id,
                                  thumbnail: true,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 4,
                            top: 4,
                            child: IconAction(
                              tooltip: _kind == LoreKind.location
                                  ? '移除场景参考图'
                                  : '移除形象图',
                              icon: FLucideIcons.x,
                              variant: FButtonVariant.secondary,
                              onPress: () => setState(() => _images.remove(id)),
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
              onPress: _busy || _full ? null : _pickImage,
              prefix: const Icon(FLucideIcons.imagePlus),
              child: const Text('选择或导入'),
            ),
            FButton(
              variant: FButtonVariant.outline,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy || _full ? null : _generateImage,
              prefix: const Icon(FLucideIcons.sparkles),
              child: Text(_kind == LoreKind.location ? '生成场景参考图' : '生成形象图'),
            ),
            if (_user && _kind == LoreKind.character)
              FButton(
                variant: FButtonVariant.outline,
                mainAxisSize: MainAxisSize.min,
                onPress: _busy || _full ? null : _importPersona,
                prefix: const Icon(FLucideIcons.user),
                child: const Text('从人设导入'),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final reference = widget.entry;
    if (reference?.data['worldBookOnly'] == true) {
      return PageScaffold(
        title: reference!.name,
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              '此条是导入角色卡时的世界书快照。生成时由角色卡世界书按触发条件参与提示词，不会始终注入。要修改生成使用的内容，请编辑角色卡资源并在写作配置中选择新版本。',
            ),
            const SizedBox(height: 24),
            SelectableText(reference.content),
            const SizedBox(height: 24),
            if (reference.provenance['resourceId'] case final String id)
              FButton(
                variant: FButtonVariant.outline,
                onPress: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ResourceDetailScreen(resourceId: id),
                  ),
                ),
                child: const Text('查看来源角色卡'),
              ),
          ],
        ),
      );
    }
    final story = ref.watch(storyProvider(widget.branchId));
    final entries =
        ref
            .watch(
              loreProvider((branchId: widget.branchId, chapterId: _chapterId)),
            )
            .value ??
        [];
    Widget endpoint(
      String label,
      String? value,
      ValueChanged<String?> changed,
    ) {
      final options = entries
          .where(
            (e) =>
                !e.deleted &&
                e.kind != LoreKind.relationship &&
                e.kind != LoreKind.map,
          )
          .toList();
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: FSelect<String>.rich(
          key: ValueKey('$label:$value'),
          label: Text(label),
          control: FSelectControl<String>.lifted(
            value: entries.any((e) => e.id == value && !e.deleted)
                ? value
                : null,
            onChange: changed,
          ),
          format: (id) =>
              options.where((e) => e.id == id).firstOrNull?.name ?? '',
          children: [
            for (final e in options)
              FSelectItem<String>(
                title: Text(e.name, overflow: TextOverflow.ellipsis),
                value: e.id,
              ),
          ],
        ),
      );
    }

    return PageScaffold(
      title: widget.entry == null ? '添加旁路资料' : '编辑${loreLabels[_kind]}',
      actions: [
        if (widget.entry != null && !widget.entry!.deleted)
          HeaderIconAction(
            icon: FLucideIcons.archive,
            tooltip: '移入资料归档',
            onPress: _busy ? null : () => _save(deleted: true),
          ),
      ],
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (widget.entry?.sourceStale == true) ...[
              const Text('正文依据已经变化。请对照原文复核此条资料。'),
              const SizedBox(height: 12),
              FCheckbox(
                label: const Text('已对照最新正文复核'),
                value: _rechecked,
                onChange: (v) => setState(() => _rechecked = v),
              ),
              const SizedBox(height: 16),
            ],
            if (widget.entry == null) ...[
              FSelect<LoreKind>(
                label: const Text('资料类型'),
                items: {for (final e in loreLabels.entries) e.value: e.key},
                control: FSelectControl<LoreKind>.lifted(
                  value: _kind,
                  onChange: (v) {
                    if (v != null) setState(() => _kind = v);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            FTextField(
              key: const Key('lore-name'),
              control: FTextFieldControl.managed(controller: _name),
              label: Text(
                _kind == LoreKind.relationship ? '关系类型，例如信任、敌对' : '名称',
              ),
            ),
            const SizedBox(height: 16),
            FSelect<LoreCertainty>(
              label: const Text('确定程度'),
              items: {for (final e in certaintyLabels.entries) e.value: e.key},
              control: FSelectControl<LoreCertainty>.lifted(
                value: _certainty,
                onChange: (v) {
                  if (v != null) setState(() => _certainty = v);
                },
              ),
            ),
            const SizedBox(height: 16),
            AsyncView(
              value: story,
              builder: (story) => FSelect<String>.rich(
                key: ValueKey('anchor:$_chapterId'),
                label: const Text('从哪个章节开始成立'),
                hint: '当前故事末尾',
                control: FSelectControl<String>.lifted(
                  value: story.chapters.any((s) => s.id == _chapterId)
                      ? _chapterId
                      : null,
                  onChange: (v) => setState(() => _chapterId = v),
                ),
                format: (id) =>
                    story.chapters
                        .where((s) => s.id == id)
                        .firstOrNull
                        ?.title ??
                    '',
                children: [
                  for (final s in story.chapters)
                    FSelectItem<String>(
                      title: Text(s.title, overflow: TextOverflow.ellipsis),
                      value: s.id,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_kind == LoreKind.relationship) ...[
              endpoint('起点人物或组织', _from, (v) => setState(() => _from = v)),
              endpoint('终点人物或组织', _to, (v) => setState(() => _to = v)),
              FSwitch(
                label: const Text('有方向的关系'),
                value: _directed,
                onChange: (v) => setState(() => _directed = v),
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.character) ...[
              FTextField(
                control: FTextFieldControl.managed(controller: _appearance),
                minLines: 1,
                maxLines: 3,
                label: const Text('外貌与辨识特征'),
              ),
              const SizedBox(height: 16),
              FTextField(
                control: FTextFieldControl.managed(controller: _goal),
                minLines: 1,
                maxLines: 3,
                label: const Text('动机与目标'),
              ),
              const SizedBox(height: 16),
              FTextField(
                control: FTextFieldControl.managed(controller: _outfit),
                minLines: 1,
                maxLines: 3,
                label: const Text('服饰'),
              ),
              const SizedBox(height: 16),
              FTextField(
                key: const Key('character-state'),
                control: FTextFieldControl.managed(controller: _state),
                minLines: 1,
                maxLines: 3,
                label: const Text('当前状态'),
                hint: '伤势、情绪、处境',
              ),
              const SizedBox(height: 16),
            ],
            if ([LoreKind.character, LoreKind.location].contains(_kind)) ...[
              FTextField(
                key: const Key('lore-reference-prompt'),
                control: FTextFieldControl.managed(
                  controller: _referencePrompt,
                ),
                minLines: 2,
                maxLines: 6,
                label: const Text('参考图固定外观描述'),
                hint: _kind == LoreKind.character
                    ? '与参考图对应的外貌、服饰和辨识特征'
                    : '建筑、空间布局、材质和固定陈设；天气与时间在具体场景中记录',
              ),
              const SizedBox(height: 16),
              _portraits(),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.event || _kind == LoreKind.foreshadow) ...[
              FTextField(
                control: FTextFieldControl.managed(controller: _time),
                label: const Text('故事内时间'),
                hint: '例如：第三个雨夜',
              ),
              const SizedBox(height: 16),
            ],
            if (_kind == LoreKind.foreshadow) ...[
              FSelect<String>(
                label: const Text('伏笔状态'),
                items: {
                  for (final e in loreStatusLabels.entries) e.value: e.key,
                },
                control: FSelectControl<String>.lifted(
                  value: loreStatusLabels.containsKey(_status)
                      ? _status
                      : 'active',
                  onChange: (v) {
                    if (v != null) setState(() => _status = v);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            FTextField(
              key: const Key('lore-content'),
              control: FTextFieldControl.managed(controller: _content),
              minLines: 6,
              maxLines: 14,
              label: const Text('内容、依据与备注'),
            ),
            if (widget.entry != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  '来源：${const {'manual': '手动整理', 'analysis': 'AI 建议，经作者采纳', 'card': '角色卡', 'candidate': '故事走向候选', 'sidecar': '旁路整理', 'visualReference': '已确认的视觉参考'}[widget.entry!.provenance['type']] ?? '导入资料'}${widget.entry!.provenance['chapterId'] == null ? '' : ' · 正文章节'}',
                ),
              ),
            const SizedBox(height: 24),
            FButton(
              onPress: _busy ? null : () => _save(),
              child: Text(
                _busy
                    ? '保存中…'
                    : widget.entry?.deleted == true
                    ? '恢复资料'
                    : '保存资料',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
