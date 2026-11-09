import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

String comicId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    Random.secure().nextInt(1 << 32).toRadixString(36);

Widget comicField(
  String label,
  String value,
  ValueChanged<String> change, {
  int lines = 3,
  Key? key,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: FTextFormField(
    key: key,
    label: Text(label),
    maxLines: lines,
    control: FTextFieldControl.managed(
      initial: TextEditingValue(text: value),
      onChange: (v) => change(v.text),
    ),
  ),
);

Widget comicButton(String label, VoidCallback? action, {Key? key}) => FButton(
  key: key,
  variant: FButtonVariant.outline,
  size: FButtonSizeVariant.sm,
  mainAxisSize: MainAxisSize.min,
  onPress: action,
  child: Text(label),
);

const comicFactLabels = {
  'action': '动作',
  'dialogue': '对白',
  'emotion': '情绪',
  'thought': '心理',
  'setting': '场景与状态',
  'cause': '因果',
  'negation': '否定',
  'clue': '线索与揭示',
  'metaphor': '修辞的实际含义',
};
const _textLabels = {
  'dialogue': '对白',
  'thought': '心理',
  'narration': '旁白',
  'sound': '拟声',
};

/// Save inside the dialog so a version conflict leaves the author's input open.
/// With [pageId] the edit stays on that page, and a new panel joins its end.
Future<void> editComicPanel(
  BuildContext context, {
  required ComicDocument document,
  required Map<String, dynamic>? panel,
  required Future<void> Function(ComicDocument) save,
  String? pageId,
}) => showAppDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PanelEditor(
    document: document,
    panel: panel,
    save: save,
    pageId: pageId,
  ),
);

class _PanelEditor extends StatefulWidget {
  const _PanelEditor({
    required this.document,
    required this.panel,
    required this.save,
    this.pageId,
  });
  final ComicDocument document;
  final Map<String, dynamic>? panel;
  final Future<void> Function(ComicDocument) save;
  final String? pageId;
  @override
  State<_PanelEditor> createState() => _PanelEditorState();
}

class _PanelEditorState extends State<_PanelEditor> {
  late final Map<String, dynamic> _panel =
      widget.panel ??
      {
        'id': comicId(),
        'description': '',
        'sceneId': comicId(),
        'continuity': '',
        'factIds': <String>[],
        'texts': <Map<String, dynamic>>[],
        'referenceAssetIds': <String>[],
      };
  late final String _original;
  bool _busy = false, _closing = false;

  @override
  void initState() {
    super.initState();
    _original = jsonEncode(_panel);
  }

  Future<void> _finish() async {
    if (!mounted) return;
    setState(() => _closing = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _close() async {
    if (jsonEncode(_panel) != _original &&
        !await confirmAction(
          context,
          title: '放弃未保存的分镜修改？',
          confirmLabel: '放弃修改',
          destructive: true,
        )) {
      return;
    }
    await _finish();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final doc = widget.document, page = widget.pageId;
      final ids = page == null
          ? null
          : doc.pages.firstWhere((p) => p['id'] == page)['panelIds'] as List;
      final panels = [
        for (final p in doc.panels)
          if (ids == null || ids.contains(p['id'])) p,
      ];
      final i = panels.indexWhere((p) => p['id'] == _panel['id']);
      if (i < 0) {
        panels.add(_panel);
      } else {
        panels[i] = _panel;
      }
      await widget.save(
        page == null ? doc.editPanels(panels) : doc.editPage(page, panels),
      );
      await _finish();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _closing,
    onPopInvokedWithResult: (popped, _) {
      if (!popped && !_busy) _close();
    },
    child: AppDialog(
      title: const Text('编辑分镜'),
      maxWidth: 680,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          comicField(
            '可画的单一时刻',
            _panel['description'] as String,
            (v) => _panel['description'] = v,
            key: const Key('comic-description'),
            lines: 5,
          ),
          comicField(
            '场景标识',
            _panel['sceneId'] as String,
            (v) => _panel['sceneId'] = v,
            lines: 1,
          ),
          FSelect<String>(
            label: const Text('同场景前格（可选）'),
            items: {
              '无': '',
              for (final (i, p)
                  in widget.document.panels
                      .takeWhile((p) => p['id'] != _panel['id'])
                      .indexed)
                '第 ${i + 1} 格 · ${p['description']}': p['id'] as String,
            },
            control: FSelectControl.lifted(
              value: _panel['previousPanelId'] as String? ?? '',
              onChange: (v) => setState(() {
                if (v == null || v.isEmpty) {
                  _panel.remove('previousPanelId');
                } else {
                  _panel['previousPanelId'] = v;
                }
              }),
            ),
          ),
          const SizedBox(height: 16),
          comicField(
            '人物、物品与转场状态',
            _panel['continuity'] as String,
            (v) => _panel['continuity'] = v,
          ),
          if (!widget.document.isOriginal) ...[
            const Text('这格承载的事实'),
            const SizedBox(height: 8),
          ],
          for (final fact in widget.document.facts)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FCheckbox(
                label: Text(
                  '${comicFactLabels[fact['kind']]}：${fact['summary']}',
                ),
                value: (_panel['factIds'] as List).contains(fact['id']),
                onChange: (checked) => setState(() {
                  final ids = _panel['factIds'] as List;
                  checked ? ids.add(fact['id']) : ids.remove(fact['id']);
                }),
              ),
            ),
          const SizedBox(height: 16),
          Text(widget.document.hasPages ? '文字将在重画后显示在图片内' : '文字按以下顺序显示在图片下方'),
          const SizedBox(height: 8),
          for (final (i, text) in (_panel['texts'] as List).indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      '${_textLabels[text['kind']]} ${text['speaker']}：${text['text']}',
                    ),
                  ),
                  const SizedBox(width: 8),
                  comicButton('编辑', () => _editText(i)),
                  if (i > 0)
                    IconAction(
                      icon: FLucideIcons.arrowUp,
                      tooltip: '上移文字',
                      onPress: () => setState(() {
                        final texts = _panel['texts'] as List;
                        texts.insert(i - 1, texts.removeAt(i));
                      }),
                    ),
                  const SizedBox(width: 8),
                  IconAction(
                    icon: FLucideIcons.trash2,
                    tooltip: '删除文字',
                    onPress: () =>
                        setState(() => (_panel['texts'] as List).removeAt(i)),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: comicButton('添加文字', () => _editText(null)),
          ),
        ],
      ),
      actions: [
        comicButton('取消', _busy ? null : _close),
        FButton(
          onPress: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '保存分镜'),
        ),
      ],
    ),
  );
  Future<void> _editText(int? index) async {
    final original = widget.document.isOriginal;
    final texts = _panel['texts'] as List;
    final text = index == null
        ? <String, dynamic>{
            'kind': 'narration',
            'speaker': '',
            'text': '',
            if (!original) 'factId': (_panel['factIds'] as List).firstOrNull,
          }
        : Map<String, dynamic>.from(texts[index] as Map);
    final facts = widget.document.facts
        .where((f) => (_panel['factIds'] as List).contains(f['id']))
        .toList();
    if (!original && facts.isEmpty) {
      showError(context, '请先选择本格承载的事实');
      return;
    }
    final result = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, update) => AppDialog(
          title: const Text('分镜文字'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FSelect<String>(
                label: const Text('类型'),
                items: {for (final e in _textLabels.entries) e.value: e.key},
                control: FSelectControl.lifted(
                  value: text['kind'] as String,
                  onChange: (v) =>
                      update(() => text['kind'] = v ?? text['kind']),
                ),
              ),
              const SizedBox(height: 16),
              if (!original) ...[
                FSelect<String>(
                  label: const Text('事实来源'),
                  items: {
                    for (final f in facts)
                      '${f['id']} · ${f['summary']}': f['id'] as String,
                  },
                  control: FSelectControl.lifted(
                    value: text['factId'] as String?,
                    onChange: (v) => update(() => text['factId'] = v),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              comicField(
                '说话者（旁白可留空）',
                text['speaker'] as String,
                (v) => text['speaker'] = v,
                lines: 1,
              ),
              comicField(
                '完整文字',
                text['text'] as String,
                (v) => text['text'] = v,
                lines: 6,
                key: const Key('comic-text'),
              ),
            ],
          ),
          actions: [
            comicButton('取消', () => Navigator.pop(dialogContext)),
            FButton(
              onPress: () {
                if ((text['text'] as String).trim().isEmpty ||
                    (!original && text['factId'] == null)) {
                  showError(dialogContext, original ? '请填写文字' : '请选择事实并填写文字');
                  return;
                }
                Navigator.pop(dialogContext, text);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (index == null) {
          texts.add(result);
        } else {
          texts[index] = result;
        }
      });
    }
  }
}

Future<void> editComicSources(
  BuildContext context, {
  required ComicDocument document,
  required Future<void> Function(ComicDocument) save,
}) => showAppDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _SourcesEditor(document: document, save: save),
);

class _SourcesEditor extends StatefulWidget {
  const _SourcesEditor({required this.document, required this.save});
  final ComicDocument document;
  final Future<void> Function(ComicDocument) save;
  @override
  State<_SourcesEditor> createState() => _SourcesEditorState();
}

class _SourcesEditorState extends State<_SourcesEditor> {
  late var _doc = widget.document;
  bool _busy = false, _dirty = false;
  void _edit(Map<String, dynamic> changes) {
    // Fact/style edits can alter every dependent image without changing its asset.
    final panels = _doc.panels;
    for (final panel in panels) {
      if (panel['assetId'] != null) panel['visualReview'] = true;
    }
    setState(() {
      _doc = _doc.edit({...changes, 'panels': panels});
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_dirty && !_busy,
    onPopInvokedWithResult: (popped, _) {
      if (!popped && !_busy) _close();
    },
    child: AppDialog(
      title: const Text('来源与事实'),
      maxWidth: 720,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('冻结的章节原文'),
          const SizedBox(height: 8),
          SelectableText(_doc.sourceText),
          const SizedBox(height: 16),
          comicField('画风与视觉设定', _doc.style, (v) => _edit({'style': v})),
          const Text('每段原文都须提取事实，或说明不承载剧情的理由。'),
          const SizedBox(height: 12),
          for (final unit in _doc.units) ...[
            SelectableText('${unit['id']} · ${unit['text']}'),
            const SizedBox(height: 8),
            Text(
              '处理：${const {'story': '剧情', 'decoration': '纯修饰', 'presentation': '展示内容', 'unresolved': '待处理'}[unit['disposition']]} ${unit['reason']}',
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: comicButton('修改处理方式', () => _unit(unit)),
            ),
            const SizedBox(height: 16),
          ],
          const Text('事实与分镜对应'),
          const SizedBox(height: 12),
          for (final fact in _doc.facts) ...[
            Text('${comicFactLabels[fact['kind']]} · ${fact['summary']}'),
            SelectableText('原文：${fact['evidence']}'),
            Text(
              '来源：${(fact['unitIds'] as List).join('、')}；分镜：${_doc.panels.where((p) => (p['factIds'] as List).contains(fact['id'])).map((p) => _doc.panels.indexWhere((x) => x['id'] == p['id']) + 1).join('、')}',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                comicButton('编辑事实', () => _fact(fact)),
                comicButton('删除事实', () {
                  if (_doc.panels.any(
                        (p) => (p['factIds'] as List).contains(fact['id']),
                      ) ||
                      _doc.facts.any(
                        (f) => (f['dependsOn'] as List).contains(fact['id']),
                      )) {
                    showError(context, '请先解除分镜和后续事实对此事实的引用，避免丢失剧情。');
                    return;
                  }
                  _edit({
                    'facts': _doc.facts
                      ..removeWhere((f) => f['id'] == fact['id']),
                  });
                }),
              ],
            ),
            const SizedBox(height: 16),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: comicButton('添加事实', () => _fact(null)),
          ),
        ],
      ),
      actions: [
        comicButton('关闭', _busy ? null : _close),
        if (_dirty)
          FButton(
            onPress: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      await widget.save(_doc);
                      if (mounted) {
                        setState(() {
                          _dirty = false;
                          _busy = false;
                        });
                        await WidgetsBinding.instance.endOfFrame;
                        if (context.mounted) Navigator.pop(context);
                      }
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: const Text('保存并标记待检查'),
          ),
      ],
    ),
  );
  Future<void> _close() async {
    if (_dirty &&
        !await confirmAction(
          context,
          title: '放弃未保存的事实修改？',
          confirmLabel: '放弃修改',
          destructive: true,
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => _dirty = false);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _unit(Map<String, dynamic> unit) async {
    var disposition = unit['disposition'] as String,
        reason = unit['reason'] as String;
    final result = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, update) => AppDialog(
          title: const Text('处理原文'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(unit['text'] as String),
              const SizedBox(height: 16),
              FSelect<String>(
                label: const Text('处理方式'),
                items: const {
                  '剧情': 'story',
                  '纯修饰': 'decoration',
                  '展示内容': 'presentation',
                  '待处理': 'unresolved',
                },
                control: FSelectControl.lifted(
                  value: disposition,
                  onChange: (v) => update(() => disposition = v ?? disposition),
                ),
              ),
              const SizedBox(height: 16),
              comicField('理由（排除时必填）', reason, (v) => reason = v),
            ],
          ),
          actions: [
            comicButton('取消', () => Navigator.pop(ctx)),
            FButton(
              onPress: () {
                if (['decoration', 'presentation'].contains(disposition) &&
                    reason.trim().isEmpty) {
                  showError(ctx, '请说明为什么不承载剧情');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      final units = _doc.units;
      units[units.indexWhere((u) => u['id'] == unit['id'])].addAll({
        'disposition': disposition,
        'reason': reason,
      });
      _edit({'units': units});
    }
  }

  Future<void> _fact(Map<String, dynamic>? original) async {
    final fact = original == null
        ? <String, dynamic>{
            'id': comicId(),
            'kind': 'action',
            'summary': '',
            'evidence': '',
            'unitIds': <String>[],
            'dependsOn': <String>[],
          }
        : Map<String, dynamic>.from(original);
    final preceding = _doc.facts
        .takeWhile((f) => f['id'] != fact['id'])
        .toList();
    final result = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (_, update) => AppDialog(
          title: const Text('编辑事实'),
          maxWidth: 680,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FSelect<String>(
                label: const Text('事实类型'),
                items: {
                  for (final e in comicFactLabels.entries) e.value: e.key,
                },
                control: FSelectControl.lifted(
                  value: fact['kind'] as String,
                  onChange: (v) => update(() {
                    fact['kind'] = v ?? fact['kind'];
                    if (v == 'dialogue') {
                      fact['speaker'] ??= '';
                      fact['quote'] ??= '';
                    } else {
                      fact.remove('speaker');
                      fact.remove('quote');
                    }
                  }),
                ),
              ),
              const SizedBox(height: 16),
              comicField(
                '朴素描述（保留否定、因果与揭示顺序）',
                fact['summary'] as String,
                (v) => fact['summary'] = v,
              ),
              comicField(
                '原文证据（逐字摘录）',
                fact['evidence'] as String,
                (v) => fact['evidence'] = v,
              ),
              if (fact['kind'] == 'dialogue') ...[
                comicField(
                  '说话者',
                  fact['speaker'] as String,
                  (v) => fact['speaker'] = v,
                  lines: 1,
                ),
                comicField(
                  '对白原句',
                  fact['quote'] as String,
                  (v) => fact['quote'] = v,
                ),
              ],
              const Text('来源段落'),
              const SizedBox(height: 8),
              for (final unit in _doc.units)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FCheckbox(
                    label: Text('${unit['id']} · ${unit['text']}'),
                    value: (fact['unitIds'] as List).contains(unit['id']),
                    onChange: (v) => update(() {
                      v
                          ? (fact['unitIds'] as List).add(unit['id'])
                          : (fact['unitIds'] as List).remove(unit['id']);
                    }),
                  ),
                ),
              const SizedBox(height: 16),
              const Text('必须先发生的事实'),
              const SizedBox(height: 8),
              for (final before in preceding)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FCheckbox(
                    label: Text(before['summary'] as String),
                    value: (fact['dependsOn'] as List).contains(before['id']),
                    onChange: (v) => update(() {
                      v
                          ? (fact['dependsOn'] as List).add(before['id'])
                          : (fact['dependsOn'] as List).remove(before['id']);
                    }),
                  ),
                ),
            ],
          ),
          actions: [
            comicButton('取消', () => Navigator.pop(ctx)),
            FButton(
              onPress: () {
                try {
                  final facts = _doc.facts;
                  final i = facts.indexWhere((f) => f['id'] == fact['id']);
                  if (i < 0) {
                    facts.add(fact);
                  } else {
                    facts[i] = fact;
                  }
                  _doc.edit({'facts': facts});
                  Navigator.pop(ctx, true);
                } catch (e) {
                  showError(ctx, e);
                }
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (result == true && mounted) {
      final facts = _doc.facts,
          i = _doc.facts.indexWhere((f) => f['id'] == fact['id']);
      if (i < 0) {
        facts.add(fact);
      } else {
        facts[i] = fact;
      }
      _edit({'facts': facts});
    }
  }
}
