import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

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
            data: {..._entry.data, 'points': _points, 'routes': _routes},
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
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存地图修改？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'discard'),
            child: const Text('放弃修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'save'),
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
    final result = await showDialog<Map<String, dynamic>>(
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
    final path = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .65,
            child: Column(
              children: [
                const ListTile(title: Text('按行进顺序选择地点')),
                Expanded(
                  child: ListView(
                    children: [
                      for (final point in _points)
                        CheckboxListTile(
                          title: Text(point['label'] as String),
                          subtitle: selected.contains(point['id'])
                              ? Text(
                                  '第 ${selected.indexOf(point['id'] as String) + 1} 站',
                                )
                              : null,
                          value: selected.contains(point['id']),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              selected.add(point['id'] as String);
                            } else {
                              selected.remove(point['id']);
                            }
                          }),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: selected.length < 2
                        ? null
                        : () => Navigator.pop(context, selected),
                    child: const Text('添加路线'),
                  ),
                ),
              ],
            ),
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
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('地图路线')),
            if (_routes.isEmpty) const ListTile(title: Text('尚未添加路线')),
            for (final r in _routes)
              ListTile(
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
                trailing: IconButton(
                  tooltip: '删除路线',
                  onPressed: () {
                    setState(() {
                      _routes.remove(r);
                      _dirty = true;
                    });
                    Navigator.pop(context);
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _points.where((p) => p['id'] == _selected).firstOrNull;
    return PopScope(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_entry.name),
          actions: [
            IconButton(
              tooltip: '保存地图',
              onPressed: _busy ? null : _save,
              icon: Icon(_dirty ? Icons.save_outlined : Icons.check),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  '长按画布添加地点；拖动标记调整位置；双指缩放。',
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
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
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _MapPainter(
                                  _points,
                                  _routes,
                                  Theme.of(context).colorScheme,
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
                                                  d.delta.dx / bounds.maxWidth)
                                              .clamp(0, 1);
                                      p['y'] =
                                          ((p['y'] as num) +
                                                  d.delta.dy / bounds.maxHeight)
                                              .clamp(0, 1);
                                      _dirty = true;
                                      _selected = p['id'] as String;
                                    }),
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: p['id'] == _selected
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                            : Theme.of(context)
                                                  .colorScheme
                                                  .secondary,
                                        borderRadius: BorderRadius.circular(22),
                                      ),
                                      child: const Icon(
                                        Icons.place,
                                        color: Colors.white,
                                        size: 25,
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
              if (selected != null)
                ListTile(
                  title: Text(selected['label'] as String),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '编辑地点标记',
                        onPressed: () => _point(old: selected),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: '删除地点标记',
                        onPressed: () => _removePoint(selected),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 10,
                  children: [
                    TextButton.icon(
                      onPressed: () => _point(),
                      icon: const Icon(Icons.add_location_alt_outlined),
                      label: const Text('添加地点'),
                    ),
                    TextButton.icon(
                      onPressed: _route,
                      icon: const Icon(Icons.route_outlined),
                      label: const Text('连接路线'),
                    ),
                    TextButton(
                      onPressed: _routeList,
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('地点标记'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: '地点名称'),
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: widget.locations.any((l) => l.id == _entity)
              ? _entity
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '关联地点资料（可选）'),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('不关联')),
            for (final l in widget.locations)
              DropdownMenuItem(value: l.id, child: Text(l.name)),
          ],
          onChanged: (v) => setState(() => _entity = v),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
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
  _MapPainter(this.points, this.routes, this.colors);
  final List<Map<String, dynamic>> points, routes;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = colors.surfaceContainerLow,
    );
    final grid = Paint()
      ..color = colors.outlineVariant.withValues(alpha: .4)
      ..strokeWidth = .5;
    for (var x = 0.0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 32) {
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
              ..color = colors.tertiary
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
            color: colors.onSurface,
            backgroundColor: colors.surface,
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
