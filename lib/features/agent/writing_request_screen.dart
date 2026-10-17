import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../lore/sidecar.dart';
import '../presets/preset_screen.dart';
import '../resources/writing_profile.dart';
import '../settings/settings_screen.dart';
import '../settings/model_select.dart';
import '../settings/world_info_budget.dart';

class WritingRequestScreen extends ConsumerStatefulWidget {
  const WritingRequestScreen({
    super.key,
    required this.chapter,
    this.rangeStart,
    this.rangeEnd,
    this.initialBrief,
    this.rewrite = false,
  });
  final Chapter chapter;
  final int? rangeStart, rangeEnd;

  /// Text to start the brief with, e.g. what an HTML interface sent.
  final String? initialBrief;

  /// Start in whole-chapter rewrite mode instead of appending.
  final bool rewrite;
  @override
  ConsumerState<WritingRequestScreen> createState() => _RequestState();
}

class _RequestState extends ConsumerState<WritingRequestScreen> {
  late final _brief = TextEditingController(text: widget.initialBrief ?? '');

  /// The brief the current preview was built from; edits drop the preview.
  late String _briefText = _brief.text;
  bool _append = true, _busy = false;
  PreparedWriting? _draft;
  Object? _error;
  List<ModelConnection> _connections = [];
  ModelConnection? _connection;
  @override
  void initState() {
    super.initState();
    if (widget.rangeStart != null || widget.rewrite) _append = false;
    _loadModels();
  }

  Future<void> _loadModels() async {
    try {
      final services = ref.read(servicesProvider);
      final all = (await services.connections())
          .where((c) => connectionServes(c, 'writing'))
          .toList();
      final selected = await services.connectionFor('writing');
      if (mounted) {
        setState(() {
          _connections = all;
          _connection = selected;
          _draft = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _brief.dispose();
    super.dispose();
  }

  void _briefChanged(TextEditingValue value) {
    if (value.text == _briefText) return;
    _briefText = value.text;
    setState(() => _draft = null);
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
            widget.chapter.branchId,
          );
      final connection = _connection ?? await services.connectionFor('writing');
      if (connection == null) throw const FormatException('请先在设置里添加写作模型连接。');
      final draft = await services.writing.prepare(
        branchId: widget.chapter.branchId,
        chapterId: widget.chapter.id,
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
        expectedRevisionId: widget.chapter.revisionId,
        autoAccept: true,
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
      final services = ref.read(servicesProvider);
      final task = await services.writing.startPrepared(_draft!);
      holdForSidecar(task.branchId, sidecarAfterWrite(services, task));
      if (mounted) Navigator.pop(context, task);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Entries the world info budget left out: one warning saying why, a way
  /// to raise the budget and check again, and the entries themselves.
  Widget _budgetAlert(String summary, List<String> entries) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: FAlert(
      key: const Key('world-book-budget'),
      icon: const Icon(FLucideIcons.bookOpen),
      title: Text(summary),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          FButton(
            variant: FButtonVariant.outline,
            size: FButtonSizeVariant.sm,
            mainAxisSize: MainAxisSize.min,
            onPress: _busy
                ? null
                : () async {
                    await showWorldInfoBudgetDialog(context);
                    if (mounted) await _preview();
                  },
            prefix: const Icon(FLucideIcons.slidersHorizontal),
            child: const Text('调整世界书预算'),
          ),
          FAccordion(
            children: [
              FAccordionItem(
                title: Text('未放入的条目（${entries.length}）'),
                child: SelectableText(entries.join('\n')),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return PageScaffold(
      title: widget.rangeStart == null ? '生成正文' : '改写选中片段',
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              widget.chapter.title,
              style: theme.typography.body.xl.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            const Text('先查看将发送给模型的提示词，再开始生成。写完直接写入正文，可在编辑器的版本历史里恢复。'),
            const SizedBox(height: 20),
            if (widget.rangeStart == null)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (append, label) in const [
                    (true, '续写追加'),
                    (false, '改写整章'),
                  ])
                    ChoicePill(
                      label: label,
                      selected: _append == append,
                      onPress: () => setState(() {
                        _append = append;
                        _draft = null;
                      }),
                    ),
                ],
              ),
            if (widget.rangeStart != null)
              FCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    widget.chapter.content.text.substring(
                      widget.rangeStart!,
                      widget.rangeEnd!,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 20),
            if (_connections.length > 1 ||
                _connections.any((c) => c.models.length > 1)) ...[
              ConnectionModelSelect(
                key: const Key('writing-model'),
                label: '本次写作模型',
                connections: _connections,
                value: _connection,
                enabled: !_busy,
                onChange: (value) => setState(() {
                  _connection = value;
                  _draft = null;
                }),
              ),
              const SizedBox(height: 20),
            ],
            FTextField(
              key: const Key('writing-brief'),
              control: FTextFieldControl.managed(
                controller: _brief,
                onChange: _briefChanged,
              ),
              minLines: 3,
              maxLines: 8,
              label: const Text('写作要求'),
              hint: '想推动什么情节？保留哪些细节？',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            PresetScreen(branchId: widget.chapter.branchId),
                      ),
                    );
                    if (mounted) setState(() => _draft = null);
                  },
                  prefix: const Icon(FLucideIcons.slidersHorizontal),
                  child: const Text('预设'),
                ),
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => WritingProfileScreen(
                          branchId: widget.chapter.branchId,
                        ),
                      ),
                    );
                    if (mounted) setState(() => _draft = null);
                  },
                  prefix: const Icon(FLucideIcons.user),
                  child: const Text('角色卡与世界书'),
                ),
                FButton(
                  variant: FButtonVariant.ghost,
                  size: FButtonSizeVariant.sm,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    );
                    if (mounted) await _loadModels();
                  },
                  prefix: const Icon(FLucideIcons.settings),
                  child: const Text('模型设置'),
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
            const SizedBox(height: 12),
            FButton(
              variant: FButtonVariant.outline,
              onPress: _busy ? null : _preview,
              child: Text(_busy && _draft == null ? '正在准备…' : '预览提示词'),
            ),
            if (_draft case final draft?) ...[
              const SizedBox(height: 20),
              Text(
                '预计 ${draft.compiled['estimatedTokens']} tokens · ${(draft.input['connection'] as Map)['model']}',
              ),
              Text(
                '用量为估算；正式计费与上下文限制以模型服务为准。',
                style: theme.typography.body.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
              for (final d in draft.compiled['diagnostics'] as List)
                if (d['code'] == 'world_book_budget_summary')
                  _budgetAlert(d['message'] as String, [
                    for (final e in draft.compiled['diagnostics'] as List)
                      if (e['code'] == 'world_book_budget')
                        e['message'] as String,
                  ])
                // Listed under the budget summary instead.
                else if (d['code'] != 'world_book_budget')
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FAlert(
                      variant: d['severity'] == 'error'
                          ? FAlertVariant.destructive
                          : FAlertVariant.primary,
                      icon: Icon(
                        d['severity'] == 'error'
                            ? FLucideIcons.circleAlert
                            : FLucideIcons.info,
                      ),
                      title: Text(d['message'] as String),
                      subtitle: Text('${d['code']} · ${d['path']}'),
                    ),
                  ),
              const SizedBox(height: 8),
              FAccordion(
                children: [
                  FAccordionItem(
                    title: const Text('提示词、顺序与参数'),
                    child: SelectableText(
                      const JsonEncoder.withIndent('  ')
                          .convert(draft.compiled),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FButton(
                onPress: _busy || !draft.canRun ? null : _start,
                prefix: const Icon(FLucideIcons.sparkles),
                child: const Text('开始生成'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
