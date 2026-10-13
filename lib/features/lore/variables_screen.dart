import 'dart:convert';

import 'package:flutter/material.dart' show SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

/// The variable manager, after 酒馆助手's: one tab per scope (global,
/// chat, message, character, preset) with a JSON editor each, plus the
/// MVU actions (reload InitVar, reprocess) MagVarUpdate offers as buttons.
///
/// Scopes map onto the novel: `global` and `chat` are the branch's
/// versioned variables at the latest chapter (or [chapterId]), `message` is
/// each chapter's record, `character` and `preset` are the tables HTML
/// pages keep for those scopes.
class VariablesScreen extends ConsumerStatefulWidget {
  const VariablesScreen({super.key, required this.branchId, this.chapterId});
  final String branchId;
  final String? chapterId;
  @override
  ConsumerState<VariablesScreen> createState() => _VariablesState();
}

final class _Scope {
  const _Scope(this.key, this.label, this.hint);
  final String key, label, hint;
}

const _scopes = [
  _Scope('global', '全局', '分支共享变量（getglobalvar / setglobalvar），按故事位置保存。'),
  _Scope(
    'chat',
    '聊天',
    '分支变量（getvar / setvar）。MVU 的 stat_data、display_data、delta_data、schema 也在这里。',
  ),
  _Scope('message', '消息楼层', '每一章是一条消息；显示该章生效的变量，修改只写入该章。'),
  _Scope('character', '角色', '界面以 type: character 读写的变量，属于本作品。'),
  _Scope('preset', '预设', '界面以 type: preset 读写的变量，属于本作品。'),
];

class _VariablesState extends ConsumerState<VariablesScreen> {
  final _editors = <String, TextEditingController>{};
  final _errors = <String, String?>{};

  /// What each editor last loaded from storage; an editor whose text
  /// differs is being edited and is not reset by a reload.
  final _loadedText = <String, String>{};

  /// Variables of the chapters opened on the message tab, read on demand.
  final _chapterVariables = <String, Map<String, dynamic>>{};

  /// Version of the branch variables when they were loaded; a save with
  /// an older version is refused, so edits never roll back changes made
  /// elsewhere (an accepted proposal, an HTML page) meanwhile.
  int? _headVersion;

  /// The text each editor held when its error was reported; editing it
  /// away clears the error.
  final _failedText = <String, String>{};
  StorySnapshot? _story;
  BranchVariables? _latest;
  Map<String, dynamic> _other = const {};
  List<MvuInitEntry> _initEntries = const [];
  bool? _schemaChecks;
  Object? _loadError;
  bool _busy = false;

  /// Chapters whose editor is open; only the latest chapter opens by itself.
  final _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _editors.values) {
      c.dispose();
    }
    super.dispose();
  }

  StoryRepository get _repo => ref.read(repositoryProvider);
  MvuService get _mvu => MvuService(_repo);

  static String _pretty(Map<String, dynamic> value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  TextEditingController _editor(String key, Map<String, dynamic> value) {
    final text = _pretty(value);
    final existing = _editors[key];
    if (existing != null) {
      // Keep text the author is still editing; refresh the rest.
      final dirty = existing.text != _loadedText[key];
      if (!dirty && existing.text != text) existing.text = text;
      _loadedText[key] = text;
      return existing;
    }
    _loadedText[key] = text;
    return _editors[key] = TextEditingController(text: text);
  }

  /// Reads one chapter's variables for its editor on the message tab.
  Future<void> _loadChapter(Chapter chapter) async {
    final variables = decodeVariables(
      (await _repo.getBranchVariables(
        widget.branchId,
        throughChapterId: chapter.id,
      )).local,
    );
    if (!mounted) return;
    setState(() {
      _chapterVariables[chapter.id] = variables;
      _editor('chapter:${chapter.id}', variables);
    });
  }

  Future<void> _load() async {
    try {
      final story = await _repo.getStory(widget.branchId);
      final latest = await _repo.getBranchVariables(
        widget.branchId,
        throughChapterId: widget.chapterId,
      );
      final other =
          (await _repo.getSetting('htmlVariables/${widget.branchId}') ?? {})
              .cast<String, dynamic>();
      final entries = await _mvu.initEntries(widget.branchId);
      final checks = await _mvu.schemaChecks(widget.branchId);
      final head = await _repo.getBranchVariables(widget.branchId);
      if (_expanded.isEmpty && story.chapters.isNotEmpty) {
        _expanded.add(story.chapters.last.id);
      }
      final perChapter = <String, Map<String, dynamic>>{};
      for (final chapter in story.chapters.where(
        (s) => _expanded.contains(s.id),
      )) {
        perChapter[chapter.id] = decodeVariables(
          (await _repo.getBranchVariables(
            widget.branchId,
            throughChapterId: chapter.id,
          )).local,
        );
      }
      if (!mounted) return;
      setState(() {
        _story = story;
        _latest = latest;
        _headVersion = head.version;
        _other = other;
        _initEntries = entries;
        _schemaChecks = checks;
        _loadError = null;
        _editor('global', decodeVariables(latest.global));
        _editor('chat', decodeVariables(latest.local));
        for (final scope in ['character', 'preset']) {
          _editor(
            scope,
            other[scope] is Map
                ? (other[scope] as Map).cast<String, dynamic>()
                : <String, dynamic>{},
          );
        }
        _chapterVariables.addAll(perChapter);
        for (final entry in perChapter.entries) {
          _editor('chapter:${entry.key}', entry.value);
        }
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  Map<String, dynamic>? _parse(String key) {
    try {
      final value = jsonDecode(_editors[key]!.text);
      if (value is! Map) throw const FormatException('变量表必须是 JSON 对象');
      setState(() => _errors[key] = null);
      return value.cast<String, dynamic>();
    } on FormatException catch (error) {
      _failedText[key] = _editors[key]!.text;
      setState(() => _errors[key] = 'JSON 无效：${error.message}');
      return null;
    }
  }

  Future<void> _run(Future<void> Function() action, {String? done}) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (mounted && done != null) toast(context, done);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveBranch(String key) async {
    final value = _parse(key);
    if (value == null) return;
    await _run(() async {
      final chapterId = widget.chapterId ?? _story!.chapters.lastOrNull?.id;
      if (chapterId == null) throw const FormatException('请先创建一个正文章节');
      final current = await _repo.getBranchVariables(
        widget.branchId,
        throughChapterId: chapterId,
      );
      await _repo.setBranchVariables(
        branchId: widget.branchId,
        chapterId: chapterId,
        expectedVersion: _headVersion!,
        local: key == 'chat' ? encodeVariables(value) : current.local,
        global: key == 'global' ? encodeVariables(value) : current.global,
      );
    }, done: '已保存');
  }

  Future<void> _saveChapter(Chapter chapter) async {
    final value = _parse('chapter:${chapter.id}');
    if (value == null) return;
    await _run(() async {
      final current = await _repo.getBranchVariables(
        widget.branchId,
        throughChapterId: chapter.id,
      );
      await _repo.setBranchVariables(
        branchId: widget.branchId,
        chapterId: chapter.id,
        expectedVersion: _headVersion!,
        local: encodeVariables(value),
        global: current.global,
      );
    }, done: '已保存第 ${_story!.chapters.indexOf(chapter)} 楼的变量');
  }

  Future<void> _saveOther(String scope) async {
    final value = _parse(scope);
    if (value == null) return;
    await _run(
      () => _repo.setSetting('htmlVariables/${widget.branchId}', {
        ..._other,
        scope: value,
      }),
      done: '已保存',
    );
  }

  void _format(String key) {
    final value = _parse(key);
    if (value != null) _editors[key]!.text = _pretty(value);
  }

  Future<void> _mvuAction(String action) async {
    if (_busy) return;
    switch (action) {
      case 'reload':
        await _run(() async {
          final data = await _mvu.reloadInitVar(widget.branchId);
          if (data == null) {
            throw const FormatException('没有新的 [InitVar] 条目可读取，或作品还没有正文');
          }
        }, done: '已重新读取初始变量');
      case 'reprocess':
        final confirmed = await confirmAction(
          context,
          title: '重新处理变量',
          message: '从初始变量开始，按每一章正文中的更新命令重新推算所有楼层的变量。手动修改过的变量会被覆盖。',
          confirmLabel: '重新处理',
        );
        if (!confirmed) return;
        await _run(() async {
          final errors = await _mvu.reprocess(widget.branchId);
          if (errors.isNotEmpty && mounted) {
            final story = _story!;
            final lines = errors.entries.map((e) {
              final index = story.chapters.indexWhere((s) => s.id == e.key);
              final where = index < 0 ? e.key : '第 $index 楼';
              return '$where：${e.value.join('；')}';
            });
            showFToast(
              context: context,
              title: const Text('部分命令未执行：'),
              description: Text(lines.join('\n')),
              duration: const Duration(seconds: 8),
            );
          }
        }, done: '已重新处理所有楼层');
      case 'checks':
        await _run(() async {
          final profile =
              await _repo.getSetting('writing/${widget.branchId}') ?? {};
          await _repo.setSetting('writing/${widget.branchId}', {
            ...profile,
            MvuService.schemaChecksKey: !(_schemaChecks ?? true),
          });
        });
    }
  }

  Widget _jsonEditor(String key, {required Future<void> Function() save}) {
    final error = _errors[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FTextField(
          key: Key('variables-$key'),
          control: FTextFieldControl.managed(
            controller: _editors[key],
            onChange: (value) {
              if (_errors[key] != null && value.text != _failedText[key]) {
                setState(() => _errors[key] = null);
              }
            },
          ),
          maxLines: null,
          minLines: 6,
          style: FTextFieldStyleDelta.delta(
            contentTextStyle: FVariantsDelta.delta([
              FVariantOperation.all(
                const TextStyleDelta.delta(
                  fontFamily: 'monospace',
                  fontSize: 13,
                ),
              ),
            ]),
          ),
          error: error == null ? null : Text(error),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FButton(
              variant: FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : () => _format(key),
              prefix: const Icon(FLucideIcons.alignLeft),
              child: const Text('格式化'),
            ),
            const Spacer(),
            FButton(
              key: Key('save-$key'),
              mainAxisSize: MainAxisSize.min,
              onPress: _busy ? null : save,
              child: const Text('保存'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _mvuCard() {
    final latest = _latest;
    final record = latest == null ? null : MvuData.fromStored(latest.local);
    final books = record?.initializedLorebooks.keys.join('、') ?? '';
    final theme = context.theme;
    final checks = _schemaChecks ?? true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: FCard(
        key: const Key('mvu-status'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(FLucideIcons.cpu, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'MVU 变量框架',
                    style: theme.typography.body.md.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  MenuAction(
                    key: const Key('mvu-actions'),
                    tooltip: 'MVU 操作',
                    enabled: !_busy,
                    entries: [
                      menuEntry('重新读取初始变量', () => _mvuAction('reload')),
                      menuEntry('重新处理变量', () => _mvuAction('reprocess')),
                      menuEntry(
                        checks ? '关闭结构校验' : '开启结构校验',
                        () => _mvuAction('checks'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                record == null
                    ? (_initEntries.isEmpty
                          ? '当前作品没有 [InitVar] 世界书条目，也没有 stat_data；绑定带有初始变量的角色卡或世界书后可在此读取。'
                          : '已找到 ${_initEntries.length} 个 [InitVar] 条目，但变量尚未初始化。选择“重新读取初始变量”。')
                    : '已初始化（${books.isEmpty ? '无世界书记录' : books}）。模型回复中的 <UpdateVariable> / <JSONPatch> 命令在采纳候选时写入该章；'
                          '结构校验${checks ? '开启' : '关闭（角色卡自带 registerMvuSchema 脚本时默认关闭）'}。',
                style: theme.typography.body.xs.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              ),
              if (record != null && record.deltaData.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '最近一次变更',
                  style: theme.typography.body.sm.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SelectableText(
                  _pretty(record.deltaData),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _scopeTab(_Scope scope) {
    final theme = context.theme;
    final hint = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        scope.hint,
        style: theme.typography.body.xs.copyWith(
          color: theme.colors.mutedForeground,
        ),
      ),
    );
    const padding = EdgeInsets.fromLTRB(0, 4, 0, 16);
    if (scope.key == 'message') {
      final story = _story!;
      final chapters = story.chapters.reversed.toList();
      return ListView.builder(
        padding: padding,
        itemCount: chapters.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return chapters.isEmpty
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [hint, const Text('这部作品还没有正文。')],
                  )
                : hint;
          }
          final chapter = chapters[i - 1];
          final open = _expanded.contains(chapter.id);
          final loaded = _chapterVariables.containsKey(chapter.id);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: FCard(
              key: Key('chapter-card-${chapter.id}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FItem(
                    title: Text(
                      '第 ${story.chapters.indexOf(chapter)} 楼 · ${chapter.title}',
                    ),
                    suffix: Icon(
                      open ? FLucideIcons.chevronUp : FLucideIcons.chevronDown,
                    ),
                    onPress: () {
                      setState(() {
                        if (!_expanded.remove(chapter.id)) {
                          _expanded.add(chapter.id);
                        }
                      });
                      if (!open && !loaded) _loadChapter(chapter);
                    },
                  ),
                  if (open && !loaded)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: FCircularProgress()),
                    ),
                  if (open && loaded)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _jsonEditor(
                            'chapter:${chapter.id}',
                            save: () => _saveChapter(chapter),
                          ),
                          if (_initEntries.isNotEmpty ||
                              MvuData.presentIn(_latest?.local ?? const {}))
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FButton(
                                key: Key('reprocess-${chapter.id}'),
                                variant: FButtonVariant.ghost,
                                mainAxisSize: MainAxisSize.min,
                                onPress: _busy
                                    ? null
                                    : () => _run(
                                        () => _mvu.processChapter(
                                          widget.branchId,
                                          chapter.id,
                                        ),
                                        done: '已按本章正文重新推算变量',
                                      ),
                                prefix: const Icon(FLucideIcons.rotateCcw),
                                child: const Text('按本章正文重新推算'),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    }
    return ListView(
      padding: padding,
      children: [
        hint,
        if (scope.key == 'chat') _mvuCard(),
        _jsonEditor(
          scope.key,
          save: () => switch (scope.key) {
            'global' || 'chat' => _saveBranch(scope.key),
            _ => _saveOther(scope.key),
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '变量管理器',
    body: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: FTabs(
        scrollable: true,
        expands: true,
        children: [
          for (final scope in _scopes)
            FTabEntry(
              label: Text(scope.label),
              child: _loadError != null
                  ? ErrorPane(message: _loadError.toString(), retry: _load)
                  : _story == null
                  ? const Center(child: FCircularProgress())
                  : _scopeTab(scope),
            ),
        ],
      ),
    ),
  );
}
