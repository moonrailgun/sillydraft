import 'dart:math';

import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../illustrations/illustration_gallery.dart';
import '../illustrations/asset_image.dart';

class StoryMapScreen extends ConsumerStatefulWidget {
  const StoryMapScreen({super.key, required this.entry, this.atSceneId});
  final LoreEntry entry;
  final String? atSceneId;
  @override
  ConsumerState<StoryMapScreen> createState() => _MapState();
}

class _MapState extends ConsumerState<StoryMapScreen> {
  late LoreEntry _entry = widget.entry;
  late final _points = (widget.entry.data['points'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  late final _routes = (widget.entry.data['routes'] as List? ?? [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  bool _dirty = false, _busy = false, _allowPop = false;
  String? _selected;
  late String? _background = widget.entry.data['backgroundAssetId'] as String?;
  late double? _backgroundAspect =
      (widget.entry.data['backgroundAspect'] as num?)?.toDouble();
  Future<void> _chooseBackground() async {
    final asset = await Navigator.push<StoryAsset>(
      context,
      MaterialPageRoute(
        builder: (_) => IllustrationGallery(
          branchId: _entry.branchId,
          picker: true,
          purpose: AssetPurpose.map,
        ),
      ),
    );
    if (asset != null && mounted) {
      setState(() {
        _background = asset.id;
        _backgroundAspect = asset.width / asset.height;
        _dirty = true;
      });
    }
  }

  Widget _mapFrame(Widget child) =>
      _backgroundAspect == null ||
          !_backgroundAspect!.isFinite ||
          _backgroundAspect! <= 0
      ? child
      : Center(
          child: AspectRatio(aspectRatio: _backgroundAspect!, child: child),
        );
  String _id() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
      Random.secure().nextInt(1 << 32).toRadixString(36);
  Future<bool> _save() async {
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(repositoryProvider)
          .saveLoreEntry(
            branchId: _entry.branchId,
            id: _entry.id,
            expectedRevisionId: _entry.revisionId,
            kind: LoreKind.map,
            name: _entry.name,
            content: _entry.content,
            certainty: _entry.certainty,
            atSceneId: widget.atSceneId,
            data: {
              ..._entry.data,
              'points': _points,
              'routes': _routes,
              'backgroundAssetId': _background,
              'backgroundAspect': _backgroundAspect,
            },
            provenance: _entry.provenance,
          );
      if (mounted) {
        setState(() {
          _entry = saved;
          _dirty = false;
        });
      }
      return true;
    } catch (e) {
      if (mounted) showError(context, e);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (!_dirty) {
      setState(() => _allowPop = true);
      Navigator.pop(context);
      return;
    }
    final choice = await showAppDialog<String>(
      context: context,
      builder: (context) => AppDialog(
        title: const Text('保存地图修改？'),
        actions: [
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => Navigator.pop(context, 'cancel'),
            child: const Text('继续编辑'),
          ),
          FButton(
            variant: FButtonVariant.outline,
            onPress: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          FButton(
            onPress: () => Navigator.pop(context, 'save'),
            child: const Text('保存并返回'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'cancel') return;
    if (choice == 'save' && !await _save()) return;
    if (mounted) {
      setState(() => _allowPop = true);
      Navigator.pop(context);
    }
  }

  Future<void> _point({
    Map<String, dynamic>? old,
    Offset position = const Offset(.5, .5),
  }) async {
    final locations = (await ref
        .read(repositoryProvider)
        .listLore(
          _entry.branchId,
          throughSceneId: widget.atSceneId,
          kind: LoreKind.location,
        ));
    if (!mounted) return;
    final result = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _PointDialog(old: old, locations: locations),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (old == null) {
        final id = _id();
        _points.add({'id': id, 'x': position.dx, 'y': position.dy, ...result});
        _selected = id;
      } else {
        old.addAll(result);
      }
      _dirty = true;
    });
  }

  void _removePoint(Map<String, dynamic> point) => setState(() {
    _points.remove(point);
    for (final route in _routes) {
      (route['pointIds'] as List).remove(point['id']);
    }
    _routes.removeWhere((r) => (r['pointIds'] as List).length < 2);
    _selected = null;
    _dirty = true;
  });
  Future<void> _route() async {
    if (_points.length < 2) {
      showError(context, '先添加至少两个地点。');
      return;
    }
    final name = await askText(context, title: '新建路线', label: '路线名称');
    if (name == null || !mounted) return;
    final selected = <String>[];
    final path = await showAppSheet<List<String>>(
      context: context,
      title: '按行进顺序选择地点',
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    for (final point in _points)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: FCheckbox(
                          label: Text(point['label'] as String),
                          description: selected.contains(point['id'])
                              ? Text(
                                  '第 ${selected.indexOf(point['id'] as String) + 1} 站',
                                )
                              : null,
                          value: selected.contains(point['id']),
                          onChange: (v) => setSheet(() {
                            if (v) {
                              selected.add(point['id'] as String);
                            } else {
                              selected.remove(point['id']);
                            }
                          }),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FButton(
                  onPress: selected.length < 2
                      ? null
                      : () => Navigator.pop(context, selected),
                  child: const Text('添加路线'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (path != null && mounted) {
      setState(() {
        _routes.add({'id': _id(), 'name': name, 'pointIds': path});
        _dirty = true;
      });
    }
  }

  Future<void> _routeList() async {
    await showAppSheet<void>(
      context: context,
      title: '地图路线',
      builder: (context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        children: [
          if (_routes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '尚未添加路线',
                style: TextStyle(color: context.theme.colors.mutedForeground),
              ),
            ),
          for (final r in _routes)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FTile(
                title: Text(r['name'] as String? ?? '路线'),
                subtitle: Text(
                  (r['pointIds'] as List)
                      .map(
                        (id) =>
                            _points
                                .where((p) => p['id'] == id)
                                .firstOrNull?['label'] ??
                            '未知',
                      )
                      .join(' → '),
                ),
                suffix: IconAction(
                  icon: FLucideIcons.trash2,
                  tooltip: '删除路线',
                  onPress: () {
                    setState(() {
                      _routes.remove(r);
                      _dirty = true;
                    });
                    Navigator.pop(context);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _points.where((p) => p['id'] == _selected).firstOrNull;
    final colors = context.theme.colors;
    return PopScope(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: PageScaffold(
        title: _entry.name,
        actions: [
          HeaderIconAction(
            icon: FLucideIcons.image,
            tooltip: '选择地图底图',
            onPress: _busy ? null : _chooseBackground,
          ),
          if (_background != null)
            HeaderIconAction(
              icon: FLucideIcons.imageOff,
              tooltip: '移除地图底图',
              onPress: () => setState(() {
                _background = null;
                _backgroundAspect = null;
                _dirty = true;
              }),
            ),
          HeaderIconAction(
            icon: _dirty ? FLucideIcons.save : FLucideIcons.check,
            tooltip: '保存地图',
            onPress: _busy ? null : _save,
          ),
        ],
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '长按画布添加地点；拖动标记调整位置；双指缩放。',
                  textAlign: TextAlign.center,
                  style: context.theme.typography.body.sm.copyWith(
                    color: colors.mutedForeground,
                  ),
                ),
              ),
              Expanded(
                child: _mapFrame(
                  LayoutBuilder(
                    builder: (context, bounds) => InteractiveViewer(
                      minScale: .5,
                      maxScale: 4,
                      boundaryMargin: const EdgeInsets.all(100),
                      child: GestureDetector(
                        onLongPressStart: (d) => _point(
                          position: Offset(
                            (d.localPosition.dx / bounds.maxWidth).clamp(0, 1),
                            (d.localPosition.dy / bounds.maxHeight).clamp(0, 1),
                          ),
                        ),
                        child: SizedBox(
                          width: bounds.maxWidth,
                          height: bounds.maxHeight,
                          child: Stack(
                            children: [
                              if (_background != null)
                                Positioned.fill(
                                  child: AssetImageView(
                                    assetId: _background!,
                                    fit: BoxFit.fill,
                                  ),
                                ),
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _MapPainter(
                                    _points,
                                    _routes,
                                    colors,
                                    background: _background == null,
                                  ),
                                ),
                              ),
                              for (final p in _points)
                                Positioned(
                                  left: ((p['x'] as num) * bounds.maxWidth - 22)
                                      .clamp(0, bounds.maxWidth - 44),
                                  top: ((p['y'] as num) * bounds.maxHeight - 22)
                                      .clamp(0, bounds.maxHeight - 44),
                                  child: Semantics(
                                    button: true,
                                    label: '地点 ${p['label']}',
                                    child: GestureDetector(
                                      onTap: () => setState(
                                        () => _selected = p['id'] as String,
                                      ),
                                      onPanUpdate: (d) => setState(() {
                                        p['x'] =
                                            ((p['x'] as num) +
                                                    d.delta.dx /
                                                        bounds.maxWidth)
                                                .clamp(0, 1);
                                        p['y'] =
                                            ((p['y'] as num) +
                                                    d.delta.dy /
                                                        bounds.maxHeight)
                                                .clamp(0, 1);
                                        _dirty = true;
                                        _selected = p['id'] as String;
                                      }),
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: p['id'] == _selected
                                              ? colors.primary
                                              : colors.secondary,
                                          border: Border.all(
                                            color: p['id'] == _selected
                                                ? colors.primary
                                                : colors.border,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            22,
                                          ),
                                        ),
                                        child: Icon(
                                          FLucideIcons.mapPin,
                                          color: p['id'] == _selected
                                              ? colors.primaryForeground
                                              : colors.secondaryForeground,
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (selected != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: FTile(
                    title: Text(selected['label'] as String),
                    suffix: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconAction(
                          icon: FLucideIcons.pencil,
                          tooltip: '编辑地点标记',
                          onPress: () => _point(old: selected),
                        ),
                        IconAction(
                          icon: FLucideIcons.trash2,
                          tooltip: '删除地点标记',
                          onPress: () => _removePoint(selected),
                        ),
                      ],
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  children: [
                    FButton(
                      variant: FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => _point(),
                      prefix: const Icon(FLucideIcons.mapPinPlus),
                      child: const Text('添加地点'),
                    ),
                    FButton(
                      variant: FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _route,
                      prefix: const Icon(FLucideIcons.route),
                      child: const Text('连接路线'),
                    ),
                    FButton(
                      variant: FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _routeList,
                      child: Text('${_routes.length} 条路线'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PointDialog extends StatefulWidget {
  const _PointDialog({this.old, required this.locations});
  final Map<String, dynamic>? old;
  final List<LoreEntry> locations;
  @override
  State<_PointDialog> createState() => _PointState();
}

class _PointState extends State<_PointDialog> {
  late final _name = TextEditingController(
    text: widget.old?['label'] as String?,
  );
  late String? _entity = widget.old?['entityId'] as String?;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: const Text('地点标记'),
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTextField(
          control: FTextFieldControl.managed(controller: _name),
          autofocus: true,
          label: const Text('地点名称'),
        ),
        const SizedBox(height: 16),
        FSelect<String>.rich(
          label: const Text('关联地点资料（可选）'),
          control: FSelectControl<String>.lifted(
            value: widget.locations.any((l) => l.id == _entity) ? _entity : '',
            onChange: (v) =>
                setState(() => _entity = v == null || v.isEmpty ? null : v),
          ),
          format: (id) =>
              widget.locations.where((l) => l.id == id).firstOrNull?.name ??
              '不关联',
          children: [
            FSelectItem<String>(title: const Text('不关联'), value: ''),
            for (final l in widget.locations)
              FSelectItem<String>(title: Text(l.name), value: l.id),
          ],
        ),
      ],
    ),
    actions: [
      FButton(
        variant: FButtonVariant.outline,
        onPress: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FButton(
        onPress: () {
          if (_name.text.trim().isNotEmpty) {
            Navigator.pop(context, {
              'label': _name.text.trim(),
              'entityId': _entity,
            });
          }
        },
        child: const Text('保存标记'),
      ),
    ],
  );
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.points, this.routes, this.colors, {this.background = true});
  final bool background;
  final List<Map<String, dynamic>> points, routes;
  final FColors colors;
  @override
  void paint(Canvas canvas, Size size) {
    if (background) {
      canvas.drawRect(Offset.zero & size, Paint()..color = colors.muted);
    }
    final grid = Paint()
      ..color = colors.border.withValues(alpha: .6)
      ..strokeWidth = .5;
    for (var x = 0.0; background && x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; background && y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final locations = {
      for (final p in points)
        p['id']: Offset(
          (p['x'] as num) * size.width,
          (p['y'] as num) * size.height,
        ),
    };
    for (final route in routes) {
      final ids = route['pointIds'] as List;
      for (var i = 1; i < ids.length; i++) {
        final a = locations[ids[i - 1]], b = locations[ids[i]];
        if (a != null && b != null) {
          canvas.drawLine(
            a,
            b,
            Paint()
              ..color = colors.primary.withValues(alpha: .7)
              ..strokeWidth = 3,
          );
        }
      }
    }
    for (final p in points) {
      final at = locations[p['id']]!;
      final text = TextPainter(
        text: TextSpan(
          text: p['label'] as String,
          style: TextStyle(
            fontSize: 12,
            color: colors.foreground,
            backgroundColor: colors.background,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: 120);
      text.paint(
        canvas,
        Offset(
          (at.dx - text.width / 2).clamp(0, size.width - text.width),
          (at.dy + 25).clamp(0, size.height - text.height),
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) => true;
}
