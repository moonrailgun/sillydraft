import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../resources/writing_profile.dart';
import '../settings/settings_screen.dart';

class WritingRequestScreen extends ConsumerStatefulWidget {
  const WritingRequestScreen({
    super.key,
    required this.scene,
    this.rangeStart,
    this.rangeEnd,
  });
  final Scene scene;
  final int? rangeStart, rangeEnd;
  @override
  ConsumerState<WritingRequestScreen> createState() => _RequestState();
}

class _RequestState extends ConsumerState<WritingRequestScreen> {
  final _brief = TextEditingController();
  bool _append = true, _busy = false;
  PreparedWriting? _draft;
  Object? _error;
  @override
  void initState() {
    super.initState();
    if (widget.rangeStart != null) _append = false;
  }

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    setState(() {
      _busy = true;
      _error = null;
      _draft = null;
    });
    try {
      final services = ref.read(servicesProvider),
          profile = await WritingContext.load(
            ref.read(servicesProvider),
            widget.scene.branchId,
          );
      final connection = await services.connectionFor('writing');
      if (connection == null) throw const FormatException('请先在设置里添加写作模型连接。');
      final draft = await services.writing.prepare(
        branchId: widget.scene.branchId,
        sceneId: widget.scene.id,
        connection: connection,
        brief: _brief.text.trim().isEmpty
            ? '继续推进当前故事，保持人物动机与叙事视角一致。'
            : _brief.text.trim(),
        append: _append,
        rewrite: !_append,
        preset: profile.preset,
        card: profile.card,
        userName: profile.userName,
        persona: profile.persona,
        worldBooks: profile.books,
        globalRegex: profile.regex,
        selectedOrderId: profile.selectedOrderId,
        rangeStart: widget.rangeStart,
        rangeEnd: widget.rangeEnd,
        expectedRevisionId: widget.scene.revisionId,
      );
      if (mounted) setState(() => _draft = draft);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final task = await ref
          .read(servicesProvider)
          .writing
          .startPrepared(_draft!);
      if (mounted) Navigator.pop(context, task);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.rangeStart == null ? '生成正文候选' : '改写选中片段'),
    ),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            widget.scene.title,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text('先查看将发送给模型的提示词，再开始生成。结果会进入候选，采纳后才写入正文。'),
          const SizedBox(height: 20),
          if (widget.rangeStart == null)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('续写追加')),
                ButtonSegment(value: false, label: Text('改写整幕')),
              ],
              selected: {_append},
              onSelectionChanged: (v) => setState(() {
                _append = v.single;
                _draft = null;
              }),
            ),
          if (widget.rangeStart != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  widget.scene.content.text.substring(
                    widget.rangeStart!,
                    widget.rangeEnd!,
                  ),
                ),
              ),
            ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('writing-brief'),
            controller: _brief,
            minLines: 3,
            maxLines: 8,
            onChanged: (_) => setState(() => _draft = null),
            decoration: const InputDecoration(
              labelText: '写作要求',
              hintText: '想推动什么情节？保留哪些细节？',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              TextButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          WritingProfileScreen(branchId: widget.scene.branchId),
                    ),
                  );
                  if (mounted) setState(() => _draft = null);
                },
                icon: const Icon(Icons.tune),
                label: const Text('角色卡与预设'),
              ),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const SettingsScreen(),
                  ),
                ),
                child: const Text('模型设置'),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                _error.toString(),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy ? null : _preview,
            child: Text(_busy && _draft == null ? '正在准备…' : '预览提示词'),
          ),
          if (_draft case final draft?) ...[
            const SizedBox(height: 20),
            Text(
              '预计 ${draft.compiled['estimatedTokens']} tokens · ${(draft.input['connection'] as Map)['model']}',
            ),
            const Text('用量为估算；正式计费与上下文限制以模型服务为准。'),
            for (final d in draft.compiled['diagnostics'] as List)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  d['severity'] == 'error'
                      ? Icons.error_outline
                      : Icons.info_outline,
                ),
                title: Text(d['message'] as String),
                subtitle: Text('${d['code']} · ${d['path']}'),
              ),
            ExpansionTile(
              title: const Text('提示词、顺序与参数'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent('  ').convert(draft.compiled),
                ),
              ],
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy || !draft.canRun ? null : _start,
              icon: const Icon(Icons.auto_awesome),
              label: const Text('开始生成候选'),
            ),
          ],
        ],
      ),
    ),
  );
}
