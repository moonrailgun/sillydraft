import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../resources/preset_prompt_editor.dart';
import '../resources/resource_preview.dart';
import '../resources/writing_profile.dart';

const _json = JsonEncoder.withIndent('  ');

/// One sampler control: ST key, label, range, and whether it is an integer.
typedef _Sampler = (
  String key,
  String label,
  double min,
  double max,
  bool integer,
);

const _chatSamplers = <_Sampler>[
  ('temperature', '温度 Temperature', 0, 2, false),
  ('top_p', 'Top P', 0, 1, false),
  ('top_k', 'Top K', 0, 200, true),
  ('min_p', 'Min P', 0, 1, false),
  ('frequency_penalty', '频率惩罚', -2, 2, false),
  ('presence_penalty', '存在惩罚', -2, 2, false),
  ('repetition_penalty', '重复惩罚', 1, 2, false),
];
const _chatLimits = <_Sampler>[
  ('openai_max_tokens', '最大回复长度（token）', 1, 0, true),
  ('openai_max_context', '上下文长度（token）', 1, 0, true),
  ('seed', '随机种子（-1 为随机）', -1, 0, true),
];
const _textSamplers = <_Sampler>[
  ('temp', '温度 Temperature', 0, 2, false),
  ('top_p', 'Top P', 0, 1, false),
  ('top_k', 'Top K', 0, 200, true),
  ('min_p', 'Min P', 0, 1, false),
  ('typical_p', 'Typical P', 0, 1, false),
  ('rep_pen', '重复惩罚', 1, 2, false),
  ('freq_pen', '频率惩罚', -2, 2, false),
  ('presence_pen', '存在惩罚', -2, 2, false),
];
// ST 1.19.0 saves a text preset's response length as `genamt` and its
// context size as `max_length` (preset-manager.js L744-747).
const _textLimits = <_Sampler>[
  ('genamt', '最大回复长度（token）', 1, 0, true),
  ('max_length', '上下文长度（token）', 1, 0, true),
  ('rep_pen_range', '重复惩罚范围', 0, 0, true),
  ('seed', '随机种子（-1 为随机）', -1, 0, true),
];

/// Preset adjustments autosave to this branch; library originals stay intact.
class PresetScreen extends ConsumerStatefulWidget {
  const PresetScreen({super.key, required this.branchId});
  final String branchId;
  @override
  ConsumerState<PresetScreen> createState() => _PresetScreenState();
}

class _PresetScreenState extends ConsumerState<PresetScreen> {
  Map<String, dynamic>? _setting;
  LibraryResource? _resource;
  Map<String, dynamic>? _draft;
  bool _busy = false;
  int _revision = 0, _pendingWrites = 0;
  Future<void> _pending = Future.value();
  Object? _saveError;

  bool get _customized =>
      (_setting?['presetOverrides'] as Map?)?.containsKey(_resource?.id) ??
      false;

  String get _settingKey => 'writing/${widget.branchId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? select}) async {
    try {
      final repo = ref.read(repositoryProvider);
      final setting = await repo.getSetting(_settingKey) ?? {};
      final id = select ?? setting['presetId'] as String?;
      final resource = id == null ? null : await repo.getResource(id);
      if (!mounted) return;
      setState(() {
        _setting = setting;
        _resource = resource;
        _draft = resource == null
            ? null
            : jsonDecode(
                jsonEncode(
                  (setting['presetOverrides'] as Map?)?[id] ?? resource.data,
                ),
              ) as Map<String, dynamic>;
        _revision++;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _bind(String? presetId) async {
    final setting = {...?_setting};
    if (presetId == null) {
      setting.remove('presetId');
    } else {
      setting['presetId'] = presetId;
    }
    setting.remove('selectedOrderId');
    await ref.read(repositoryProvider).setSetting(_settingKey, setting);
  }

  void _persist() {
    final repo = ref.read(repositoryProvider);
    final setting = jsonDecode(jsonEncode(_setting!)) as Map<String, dynamic>;
    setState(() => _pendingWrites++);
    // Serialize snapshots so fast edits cannot finish in the wrong order.
    _pending = _pending.then((_) async {
      try {
        await repo.setSetting(_settingKey, setting);
        _saveError = null;
      } catch (e) {
        _saveError = e;
      } finally {
        _pendingWrites--;
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _awaitSaved() async {
    while (_pendingWrites > 0) {
      await _pending;
    }
    if (_saveError != null) throw _saveError!;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _awaitSaved();
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switch(String? id) async {
    if (id == _resource?.id) return;
    await _run(() async {
      await _bind(id);
      await _load(select: id);
    });
  }

  Future<void> _saveAs() async {
    final name = await askText(
      context,
      title: '存入预设库',
      initial: '${_resource?.name ?? '预设'} 副本',
      label: '预设名称',
    );
    if (name == null) return;
    await _run(() async {
      final data = {...?_draft, 'name': name};
      final created = await ref
          .read(servicesProvider)
          .library
          .import(
            Uint8List.fromList(utf8.encode(jsonEncode(data))),
            filename: '$name.json',
            kind: ResourceKind.preset,
          );
      await _bind(created.id);
      await _load(select: created.id);
    });
  }

  Future<void> _import() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'ST 预设',
          extensions: ['json'],
          uniformTypeIdentifiers: ['public.json', 'public.data'],
        ),
      ],
    );
    if (file == null) return;
    await _run(() async {
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('预设文件不能超过 8 MB');
      }
      final library = ref.read(servicesProvider).library;
      final bytes = await file.readAsBytes();
      final preview = library.inspect(
        bytes,
        filename: file.name,
        kind: ResourceKind.preset,
      );
      final created = await library.import(
        bytes,
        filename: file.name,
        kind: ResourceKind.preset,
      );
      await _bind(created.id);
      await _load(select: created.id);
      if (mounted && preview.diagnostics.isNotEmpty) {
        showError(context, '已导入：${preview.diagnostics.length} 条兼容提示，见「兼容提示」页签');
      }
    });
  }

  Future<void> _export() => _run(() async {
    final resource = _resource!;
    final bytes = Uint8List.fromList(
      utf8.encode(_json.convert(redactCredentials(_draft!))),
    );
    final filename =
        '${resource.name.replaceAll(RegExp(r'[^\p{L}\p{N}_-]', unicode: true), '_')}.json';
    final file = XFile.fromData(
      bytes,
      mimeType: 'application/json',
      name: filename,
    );
    if (Platform.isAndroid || Platform.isIOS) {
      await SharePlus.instance.share(
        ShareParams(files: [file], fileNameOverrides: [filename]),
      );
    } else {
      final location = await getSaveLocation(suggestedName: filename);
      if (location != null) await file.saveTo(location.path);
    }
  });

  Future<void> _reset() async {
    final yes = await confirmAction(
      context,
      title: '恢复预设「${_resource!.name}」？',
      message: '清除当前分支对此预设的调整，恢复为预设库中的内容。',
      confirmLabel: '恢复',
    );
    if (!yes) return;
    _changed(() {
      _draft = jsonDecode(jsonEncode(_resource!.data)) as Map<String, dynamic>;
      _revision++;
    });
  }

  void _changed(VoidCallback change) {
    setState(() {
      change();
      final overrides = Map<String, dynamic>.from(
        _setting!['presetOverrides'] as Map? ?? {},
      );
      if (canonicalJson(_draft) == canonicalJson(_resource!.data)) {
        overrides.remove(_resource!.id);
      } else {
        overrides[_resource!.id] = _draft;
      }
      if (overrides.isEmpty) {
        _setting!.remove('presetOverrides');
      } else {
        _setting!['presetOverrides'] = overrides;
      }
    });
    _persist();
  }

  void _edit(void Function(Map<String, dynamic> target) change) =>
      _changed(() => change(_samplerTarget(_draft!)));

  /// Samplers live at the top level, or in `preset` for a formatting bundle.
  Map<String, dynamic> _samplerTarget(Map<String, dynamic> draft) =>
      draft['preset'] is Map<String, dynamic>
      ? draft['preset'] as Map<String, dynamic>
      : draft;

  @override
  Widget build(BuildContext context) {
    final resources = ref.watch(resourcesProvider).value ?? const [];
    final parents = {for (final r in resources) r.parentId};
    final customizedIds = (_setting?['presetOverrides'] as Map? ?? {}).keys;
    // Keep customized versions selectable after their library original changes.
    final presets = [
      for (final r in resources)
        if (r.kind == ResourceKind.preset &&
            !r.archived &&
            (!parents.contains(r.id) ||
                r.id == _resource?.id ||
                customizedIds.contains(r.id)))
          r,
    ];
    final names = {for (final r in resources) r.id: r.name};
    final preset = _draft == null ? null : PresetImporter().decode(_draft!);
    final kind = preset?.kind;
    final chat = kind == PresetKind.chat;
    final text = kind == PresetKind.textCompletion || kind == PresetKind.bundle;
    final assistant = _setting?[assistantUsesPresetKey] != false;
    final assistantCapable = chat || kind == PresetKind.promptPack;
    final regex = DisplayContext.regexRulesOf(_draft?['extensions']);
    // Phones keep the controls above the tabs to short single lines.
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final gap = SizedBox(height: narrow ? 8 : 12);
    return PopScope(
      canPop: _pendingWrites == 0 && _saveError == null && !_busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy) return;
        await _run(() async {
          await WidgetsBinding.instance.endOfFrame;
          if (context.mounted) Navigator.pop(context);
        });
      },
      child: PageScaffold(
        title: '预设',
        actions: [
          HeaderIconAction(
            tooltip: '导入 ST 预设',
            onPress: _busy ? null : _import,
            icon: FLucideIcons.fileInput,
          ),
          if (!_busy && _resource != null)
            MenuAction(
              header: true,
              tooltip: '预设操作',
              entries: [
                menuEntry('存入预设库…', _saveAs, icon: FLucideIcons.copy),
                menuEntry('导出 JSON', _export, icon: FLucideIcons.download),
              ],
            )
          else
            const HeaderIconAction(
              tooltip: '预设操作',
              onPress: null,
              icon: FLucideIcons.ellipsisVertical,
            ),
        ],
        body: _setting == null
            ? const Center(child: FCircularProgress())
            : Align(
                alignment: Alignment.topCenter,
                child: AbsorbPointer(
                  absorbing: _busy,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_busy) const FProgress(),
                          const SizedBox(height: 8),
                          FSelect<String>.rich(
                            key: ValueKey(
                              'preset:${_resource?.id}:${presets.length}',
                            ),
                            label: const Text('当前预设'),
                            description: narrow
                                ? null
                                : const Text('修改自动保存到当前分支，不影响预设库和其他分支'),
                            enabled: !_busy,
                            format: (id) => id == _none
                                ? '不使用预设（SillyDraft 默认）'
                                : '${names[id] ?? id}${customizedIds.contains(id) ? ' · 已自定义' : ''}',
                            control: FSelectControl<String>.lifted(
                              value: _resource?.id ?? _none,
                              onChange: (id) {
                                if (id != null) {
                                  _switch(id == _none ? null : id);
                                }
                              },
                            ),
                            children: [
                              FSelectItem<String>(
                                title: const Text('不使用预设（SillyDraft 默认）'),
                                value: _none,
                              ),
                              for (final r in presets)
                                FSelectItem<String>(
                                  title: Text(
                                    '${r.name}${customizedIds.contains(r.id) ? ' · 已自定义' : ''}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  value: r.id,
                                ),
                            ],
                          ),
                          gap,
                          if (_resource == null)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Text(
                                '还没有选择预设。点右上角导入 SillyTavern 的预设文件（聊天补全预设、提示词包或高级格式组合包），或在资源库导入后在这里选择。',
                              ),
                            )
                          else ...[
                            FTile(
                              key: const Key('assistant-uses-preset'),
                              enabled: assistantCapable,
                              title: _wrapped('助手对话也使用此预设'),
                              // Narrow: only the reason it is unavailable.
                              subtitle: !assistantCapable
                                  ? _wrapped('文本补全模板不能用于助手对话')
                                  : narrow
                                  ? null
                                  : _wrapped('助手的身份与语气按预设组装；编辑规则与工具权限不变'),
                              suffix: FSwitch(
                                value: assistant && assistantCapable,
                                enabled: assistantCapable,
                                onChange: _setAssistant,
                              ),
                              onPress: assistantCapable
                                  ? () => _setAssistant(!assistant)
                                  : null,
                            ),
                            gap,
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _saveError != null
                                        ? '自动保存失败，修改尚未保存'
                                        : _pendingWrites > 0
                                        ? '正在自动保存…'
                                        : _customized
                                        ? '已自定义 · 已自动保存'
                                        : '使用预设库原件 · 修改自动保存到当前分支',
                                  ),
                                ),
                                if (_saveError != null)
                                  FButton(
                                    variant: FButtonVariant.outline,
                                    mainAxisSize: MainAxisSize.min,
                                    onPress: _pendingWrites > 0
                                        ? null
                                        : _persist,
                                    child: const Text('重试'),
                                  ),
                                if (_customized)
                                  FButton(
                                    key: const Key('preset-reset'),
                                    variant: FButtonVariant.ghost,
                                    mainAxisSize: MainAxisSize.min,
                                    onPress: _busy ? null : _reset,
                                    child: const Text('恢复预设'),
                                  ),
                              ],
                            ),
                            gap,
                            Expanded(
                              child: _PresetTabs(
                                key: ValueKey('preset-tabs:${_resource!.id}'),
                                children: [
                                  if (chat || text)
                                    FTabEntry(
                                      label: const Text('采样参数'),
                                      child: Builder(
                                        builder: (_) => ListView(
                                          key: const PageStorageKey(
                                            'preset-samplers',
                                          ),
                                          padding: const EdgeInsets.only(
                                            bottom: 32,
                                          ),
                                          children: [
                                            for (final s
                                                in chat
                                                    ? _chatSamplers
                                                    : _textSamplers)
                                              _slider(s),
                                            for (final s
                                                in chat
                                                    ? _chatLimits
                                                    : _textLimits)
                                              _number(s),
                                          ],
                                        ),
                                      ),
                                    ),
                                  if (PresetPromptEditor.supports(_draft!))
                                    FTabEntry(
                                      label: const Text('提示词管理'),
                                      child: PresetPromptEditor(
                                        key: ValueKey(
                                          'prompts:${_resource!.id}:$_revision',
                                        ),
                                        value: _draft!,
                                        onChanged: (value) => _changed(() {
                                          // Only take prompt fields so sampler edits survive.
                                          if (value['data'] is Map) {
                                            _draft!['data'] = value['data'];
                                          } else {
                                            _draft!['prompts'] =
                                                value['prompts'];
                                            _draft!['prompt_order'] =
                                                value['prompt_order'];
                                          }
                                        }),
                                      ),
                                    ),
                                  if (regex.isNotEmpty)
                                    FTabEntry(
                                      label: const Text('预设正则'),
                                      child: Builder(
                                        builder: (_) => ListView(
                                          key: const PageStorageKey(
                                            'preset-regex',
                                          ),
                                          padding: const EdgeInsets.only(
                                            bottom: 32,
                                          ),
                                          children: [
                                            Text(
                                              '启用 ${regex.where((r) => r['disabled'] != true).length} / ${regex.length}',
                                            ),
                                            const SizedBox(height: 4),
                                            const Text(
                                              '开关自动保存到当前分支；显示正则立即刷新已有章节，不改动原正文。后续生成使用新设置。',
                                            ),
                                            const SizedBox(height: 8),
                                            FTileGroup.builder(
                                              count: regex.length,
                                              tileBuilder: (_, i) =>
                                                  _regexTile(regex[i], i),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  FTabEntry(
                                    label: const Text('原始 JSON'),
                                    child: Builder(
                                      builder: (_) => ListView(
                                        key: const PageStorageKey(
                                          'preset-json',
                                        ),
                                        padding: const EdgeInsets.only(
                                          bottom: 32,
                                        ),
                                        children: [
                                          const Text('当前分支使用的完整预设，包含已做的修改。'),
                                          const SizedBox(height: 8),
                                          Align(
                                            alignment: Alignment.centerLeft,
                                            child: FButton(
                                              variant: FButtonVariant.outline,
                                              mainAxisSize: MainAxisSize.min,
                                              onPress: () => Clipboard.setData(
                                                ClipboardData(
                                                  text: _json.convert(_draft!),
                                                ),
                                              ),
                                              child: const Text('复制完整 JSON'),
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          JsonTreeView(_draft!),
                                        ],
                                      ),
                                    ),
                                  ),
                                  FTabEntry(
                                    label: const Text('兼容提示'),
                                    child: Builder(
                                      builder: (_) => ListView(
                                        key: const PageStorageKey(
                                          'preset-diagnostics',
                                        ),
                                        padding: const EdgeInsets.only(
                                          bottom: 32,
                                        ),
                                        children: [
                                          if (preset!.diagnostics.isEmpty)
                                            const Text('此预设没有导入兼容提示。')
                                          else
                                            FTileGroup(
                                              children: [
                                                for (final d
                                                    in preset.diagnostics)
                                                  FTile(
                                                    prefix: Icon(
                                                      d.severity ==
                                                              DiagnosticSeverity
                                                                  .error
                                                          ? FLucideIcons
                                                                .circleAlert
                                                          : FLucideIcons.info,
                                                    ),
                                                    title: _wrapped(d.message),
                                                    subtitle: Text(d.code),
                                                  ),
                                              ],
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  void _setAssistant(bool value) {
    setState(() => _setting![assistantUsesPresetKey] = value);
    _persist();
  }

  Widget _regexTile(Map<String, dynamic> rule, int index) {
    final rawName = rule['scriptName'];
    final name = rawName is String && rawName.trim().isNotEmpty
        ? rawName
        : '正则 ${index + 1}';
    final enabled = rule['disabled'] != true;
    final stages = [
      if (rule['markdownOnly'] == true) '正文显示',
      if (rule['promptOnly'] == true) '模型提示词',
      if (rule['markdownOnly'] != true && rule['promptOnly'] != true) '文本处理',
    ];
    // ST 1.19.0 (06bde939), extensions/regex/index.js: enabled = !disabled.
    void toggle(bool value) => _changed(() => rule['disabled'] = !value);
    final tile = FTile(
      key: Key('preset-regex-$index'),
      title: _wrapped(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _wrapped('${enabled ? '已启用' : '已停用'} · ${stages.join('、')}'),
          const SizedBox(height: 4),
          Text(
            '${rule['findRegex'] ?? ''}',
            style: const TextStyle(fontFamily: 'monospace'),
            overflow: TextOverflow.visible,
            softWrap: true,
          ),
        ],
      ),
      suffix: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconAction(
            key: Key('preset-regex-details-$index'),
            icon: FLucideIcons.fileCode,
            tooltip: '查看正则内容',
            onPress: () => _showRegex(rule, name),
          ),
          FSwitch(semanticsLabel: name, value: enabled, onChange: toggle),
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : context.theme.colors.disabledOpacity,
      child: tile,
    );
  }

  Future<void> _showRegex(Map<String, dynamic> rule, String name) =>
      showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          maxWidth: 800,
          title: Text(name),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (key, label) in [
                ('findRegex', '查找表达式'),
                ('replaceString', '替换内容'),
              ]) ...[
                Text(label),
                const SizedBox(height: 4),
                SelectableText(
                  '${rule[key] ?? ''}',
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 16),
              ],
              const Text('执行条件与其他字段'),
              const SizedBox(height: 4),
              JsonTreeView(
                {...rule}
                  ..remove('findRegex')
                  ..remove('replaceString'),
              ),
            ],
          ),
          actions: [
            FButton(
              variant: FButtonVariant.outline,
              onPress: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
            FButton(
              onPress: () =>
                  Clipboard.setData(ClipboardData(text: _json.convert(rule))),
              child: const Text('复制完整规则'),
            ),
          ],
        ),
      );

  Widget _slider(_Sampler s) {
    final (key, label, min, max, integer) = s;
    final value = _samplerTarget(_draft!)[key];
    final current = value is num ? value.toDouble().clamp(min, max) : null;
    // The same resolution the ST sliders use.
    final divisions = integer ? (max - min).round() : 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                current == null
                    ? '未设置'
                    : integer
                    ? '${current.round()}'
                    : current.toStringAsFixed(2),
                style: context.theme.typography.body.sm.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              IconAction(
                tooltip: '恢复为未设置',
                onPress: current == null
                    ? null
                    : () => _edit((t) => t.remove(key)),
                icon: FLucideIcons.rotateCcw,
              ),
            ],
          ),
          FSlider(
            key: Key('sampler-$key'),
            tooltipControls: const FSliderTooltipControls.disabled(),
            control: FSliderControl.liftedContinuous(
              value: FSliderValue(
                max: ((current ?? (min + max) / 2) - min) / (max - min),
              ),
              onChange: (fraction) {
                final step = (fraction.max * divisions).round() / divisions;
                final v = min + step * (max - min);
                final next = integer
                    ? v.round()
                    : double.parse(v.toStringAsFixed(2));
                if (_samplerTarget(_draft!)[key] != next) {
                  _edit((t) => t[key] = next);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _number(_Sampler s) {
    final (key, label, min, _, _) = s;
    final value = _samplerTarget(_draft!)[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FTextFormField(
        key: ValueKey('number:$key:$_revision'),
        control: FTextFieldControl.managed(
          initial: TextEditingValue(
            text: value is num ? '${value.round()}' : '',
          ),
          // Also called for cursor moves: only a changed number is an edit.
          onChange: (text) {
            final target = _samplerTarget(_draft!);
            final parsed = int.tryParse(text.text.trim());
            if (text.text.trim().isEmpty) {
              if (target.containsKey(key)) _edit((t) => t.remove(key));
            } else if (parsed != null &&
                parsed >= min &&
                target[key] != parsed) {
              _edit((t) => t[key] = parsed);
            }
          },
        ),
        keyboardType: TextInputType.number,
        label: Text(label),
        hint: '未设置',
      ),
    );
  }
}

// FTabs stretches its bar; keep the same theme with a content-width header.
class _PresetTabs extends StatelessWidget {
  const _PresetTabs({super.key, required this.children});

  final List<FTabEntry> children;

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final style = theme.tabsStyle;
    return DefaultTabController(
      length: children.length,
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DecoratedBox(
              decoration: style.decoration,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerHeight: 0,
                padding: style.padding,
                indicator: style.indicatorDecoration,
                indicatorSize: TabBarIndicatorSize.tab,
                labelStyle: style.labelTextStyle.resolve({
                  context.platformVariant,
                  FTabVariant.selected,
                }),
                unselectedLabelStyle: style.labelTextStyle.resolve({
                  context.platformVariant,
                }),
                tabs: [
                  for (final tab in children)
                    ConstrainedBox(
                      constraints: BoxConstraints(minHeight: style.minHeight),
                      child: Center(widthFactor: 1, child: tab.label),
                    ),
                ],
              ),
            ),
            SizedBox(height: style.spacing),
            Expanded(
              child: DefaultTextStyle(
                style: theme.typography.body.md.copyWith(
                  color: theme.colors.foreground,
                ),
                child: TabBarView(
                  physics: const BouncingScrollPhysics(),
                  children: [for (final tab in children) tab.child],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "no preset" choice of the preset select.
const _none = '';

/// A long text in a tile: wraps instead of being cut to one line.
Text _wrapped(String text) =>
    Text(text, overflow: TextOverflow.visible, softWrap: true);
