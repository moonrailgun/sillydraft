import 'dart:math';

import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/library_host.dart';
import '../../app/services.dart';
import '../../app/widgets.dart';
import '../lore/sidecar.dart';
import '../remote/hosting_screen.dart';
import '../remote/library_switcher.dart';
import '../remote/share_screen.dart';
import '../skills/skills_screen.dart';
import '../update/update_prompt.dart';
import 'comfy_workflow_editor.dart';
import 'model_select.dart';
import 'usage_screen.dart';
import 'world_info_budget.dart';

final connectionsProvider = FutureProvider<List<ModelConnection>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(servicesProvider).connections();
});

/// [connection] with its saved key; never an address a phone wrote.
Future<SharePayload> _shareConnection(
  AppServices services,
  ModelConnection connection,
) async {
  if (!await services.endpointTrusted(connection)) {
    throw StateError(AppServices.movedEndpoint);
  }
  return connectionShare(connection, await services.savedKey(connection));
}

/// A long text in a tile's subtitle: wraps instead of being cut to one line.
Text _wrapped(String text) =>
    Text(text, overflow: TextOverflow.visible, softWrap: true);

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remote = ref.watch(servicesProvider).remote;
    final appearance = ref.watch(settingProvider('appearance')).value;
    final html = ref.watch(settingProvider('html')).value;
    final roles = ref.watch(settingProvider('modelRoles')).value ?? {};
    final usage = switch (ref.watch(usageProvider).value) {
      final u? => usageSummary(u.months),
      null => null,
    };
    final version = ref.watch(appVersionProvider).value;
    final updates = ref.watch(servicesProvider).updateEndpoint != null;
    final autoUpdate =
        ref.watch(settingProvider('update')).value?['auto'] != false;
    final theme = context.theme;
    final heading = theme.typography.body.md.copyWith(
      fontWeight: FontWeight.w600,
    );
    final renderHtml = html?['render'] != false;
    void setHtml(bool value) =>
        ref.read(repositoryProvider).setSetting('html', {'render': value});
    return PageScaffold(
      title: '设置',
      body: LayoutBuilder(
        builder: (context, constraints) {
          return ListView(
            // Center the content while keeping the scrollbar at the page edge.
            padding: EdgeInsets.symmetric(
              horizontal: 24 + max(0.0, (constraints.maxWidth - 800) / 2),
              vertical: 24,
            ),
            children: [
              if (remote != null) ...[
                FTileGroup(
                  children: [
                    FTile(
                      key: const Key('settings-remote'),
                      prefix: const Icon(FLucideIcons.monitor),
                      title: Text('正在使用桌面：${remote.hello.name}'),
                      subtitle: _wrapped('作品、资料和模型都来自这台桌面电脑'),
                      suffix: FButton(
                        variant: FButtonVariant.outline,
                        mainAxisSize: MainAxisSize.min,
                        onPress: () => switchLibrary(context, ref, null),
                        child: const Text('切回本机'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
              Text(
                '让工具适合你的写作方式',
                style: theme.typography.body.xl2.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 24),
              Text('外观', style: heading),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in const {
                    'system': '跟随系统',
                    'light': '浅色',
                    'dark': '深色',
                  }.entries)
                    ChoicePill(
                      label: entry.value,
                      icon: switch (entry.key) {
                        'light' => FLucideIcons.sun,
                        'dark' => FLucideIcons.moon,
                        _ => FLucideIcons.sunMoon,
                      },
                      selected: (appearance?['mode'] ?? 'system') == entry.key,
                      onPress: () => ref.read(repositoryProvider).setSetting(
                        'appearance',
                        {'mode': entry.key},
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              FTileGroup(
                children: [
                  FTile(
                    key: const Key('settings-html'),
                    prefix: const Icon(FLucideIcons.codeXml),
                    title: _wrapped('渲染正文中的 HTML 界面'),
                    subtitle: _wrapped(
                      '角色卡开场、状态栏等 html 代码块在隔离的网页视图里显示，并提供酒馆助手风格的接口（消息、变量、/send 等）。预设填入酒馆输入框的文本会直接用于续写下一章。页面只能通过 HTTPS 联网，不能跳转或读文件。关闭后按源码显示。',
                    ),
                    suffix: FSwitch(value: renderHtml, onChange: setHtml),
                    onPress: () => setHtml(!renderHtml),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '模型连接',
                      style: theme.typography.body.lg.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (remote == null)
                    FButton(
                      variant: FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: () => showAppDialog<void>(
                        context: context,
                        builder: (_) => const ConnectionDialog(),
                      ),
                      prefix: const Icon(FLucideIcons.plus),
                      child: const Text('添加连接'),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  remote == null
                      ? '一个连接可保存多个模型。支持 OpenAI 兼容接口、ComfyUI 与 NovelAI 生图、SillyDraft 远程执行器，以及桌面端的本地订阅（Claude Code、Codex）。密钥以明文保存在本机的密钥文件里，不进入作品备份和同步。'
                      : '连接在桌面管理：地址与密钥只保存在桌面电脑里。这里可以为各任务选择连接。',
                  style: theme.typography.body.sm.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ),
              AsyncView(
                value: ref.watch(connectionsProvider),
                builder: (List<ModelConnection> connections) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (connections.isEmpty)
                      const FCard(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('尚未配置模型。你仍然可以离线编辑和阅读，添加连接后即可使用 AI 创作。'),
                        ),
                      )
                    else
                      FTileGroup(
                        children: [
                          for (final connection in connections)
                            FTile(
                              prefix: Icon(
                                connection.protocol.isLocalCli
                                    ? FLucideIcons.squareTerminal
                                    : FLucideIcons.network,
                              ),
                              title: Text(connection.name),
                              subtitle: _wrapped(
                                connection.protocol.isLocalCli
                                    ? '${protocolLabels[connection.protocol]} · ${connection.model == 'default' ? '默认模型' : connection.model}\n${connection.command.isEmpty ? '自动查找命令' : connection.command}'
                                    : '${modelKindLabels[connection.kind]} · ${connection.models.join('、')}\n${connection.baseUrl}',
                              ),
                              suffix: remote == null
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconAction(
                                          icon: FLucideIcons.qrCode,
                                          tooltip: '扫码分享',
                                          onPress: () => shareByQr(
                                            context,
                                            () => _shareConnection(
                                              ref.read(servicesProvider),
                                              connection,
                                            ),
                                            containsKey: true,
                                          ),
                                        ),
                                        IconAction(
                                          icon: FLucideIcons.pencil,
                                          tooltip: '编辑连接',
                                          onPress: () => showAppDialog<void>(
                                            context: context,
                                            builder: (_) => ConnectionDialog(
                                              connection: connection,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : null,
                            ),
                        ],
                      ),
                    if (connections.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      Text('任务使用的模型', style: heading),
                      const SizedBox(height: 16),
                      for (final role in {
                        'writing': '正文写作',
                        'editor': '编辑 Agent',
                        'analysis': '资料整理',
                        'image': '插画生成',
                      }.entries)
                        if (connections.any(
                          (c) => connectionServes(c, role.key),
                        ))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: _roleSelect(
                              ref,
                              label: role.value,
                              role: role.key,
                              roles: roles,
                              connections: [
                                for (final c in connections)
                                  if (connectionServes(c, role.key)) c,
                              ],
                            ),
                          ),
                      const SizedBox(height: 12),
                      Text('旁路整理', style: heading),
                      const SizedBox(height: 8),
                      const Text(
                        '每写完一章，用资料整理模型在后台维护人物、记忆与推演。每次整理会额外调用若干轮模型（最多 8 轮），每轮都会重发本章正文和资料索引。',
                      ),
                      const SizedBox(height: 12),
                      const SidecarSwitches(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text('世界书预算', style: heading),
              const SizedBox(height: 8),
              const Text(worldInfoBudgetHelp),
              const SizedBox(height: 12),
              const WorldInfoBudgetFields(),
              const SizedBox(height: 24),
              FTileGroup(
                children: [
                  FTile(
                    key: const Key('settings-usage'),
                    prefix: const Icon(FLucideIcons.receipt),
                    title: const Text('用量与成本'),
                    subtitle: usage == null
                        ? null
                        : _wrapped([usage.title, ?usage.note].join('\n')),
                    suffix: const Icon(FLucideIcons.chevronRight),
                    onPress: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const UsageScreen(),
                      ),
                    ),
                  ),
                  FTile(
                    key: const Key('settings-skills'),
                    prefix: const Icon(FLucideIcons.puzzle),
                    title: const Text('助手技能'),
                    subtitle: _wrapped(
                      'Agent Skills（SKILL.md）：内置写作技能、导入社区技能或自己编写',
                    ),
                    suffix: const Icon(FLucideIcons.chevronRight),
                    onPress: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SkillsScreen(),
                      ),
                    ),
                  ),
                  if (!isPhone && remote == null)
                    FTile(
                      key: const Key('settings-hosting'),
                      prefix: const Icon(FLucideIcons.smartphone),
                      title: const Text('手机连接'),
                      subtitle: _wrapped('让手机扫码使用这台电脑的作品库和模型'),
                      suffix: const Icon(FLucideIcons.chevronRight),
                      onPress: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const HostingScreen(),
                        ),
                      ),
                    ),
                ],
              ),
              if (updates) ...[
                const SizedBox(height: 24),
                FTileGroup(
                  children: [
                    FTile(
                      key: const Key('settings-check-update'),
                      prefix: const Icon(FLucideIcons.refreshCw),
                      title: const Text('检查更新'),
                      subtitle: _wrapped('从 GitHub Releases 获取新版本，下载后手动安装'),
                      onPress: () => checkUpdates(context, ref, manual: true),
                    ),
                    FTile(
                      key: const Key('settings-auto-update'),
                      prefix: const Icon(FLucideIcons.bellRing),
                      title: const Text('自动检查更新'),
                      subtitle: _wrapped('启动时每天最多访问一次 GitHub'),
                      suffix: FSwitch(
                        value: autoUpdate,
                        onChange: (value) => setAutoUpdateCheck(
                          ref.read(repositoryProvider),
                          value,
                        ),
                      ),
                      onPress: () => setAutoUpdateCheck(
                        ref.read(repositoryProvider),
                        !autoUpdate,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 32),
              const FDivider(),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 16),
                    child: Icon(
                      FLucideIcons.bookOpen,
                      size: 20,
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          key: const Key('settings-version'),
                          version == null
                              ? 'SillyDraft'
                              : 'SillyDraft ${version.version} (${version.buildNumber})',
                          style: theme.typography.body.sm.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '正文属于作品，Agent 是创作工具。\n本地优先，支持手机与桌面。',
                          style: theme.typography.body.sm.copyWith(
                            color: theme.colors.mutedForeground,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  /// Which connection a task role uses: the saved choice when that connection
  /// still serves the role. Without one the role falls back to the first that
  /// does (as `connectionFor`), which the hint names but does not select, so
  /// choosing it is a change that saves.
  Widget _roleSelect(
    WidgetRef ref, {
    required String label,
    required String role,
    required Map<String, dynamic> roles,
    required List<ModelConnection> connections,
  }) {
    var chosen = connections.where((c) => c.id == roles[role]).firstOrNull;
    if (chosen != null && chosen.models.contains(roles['${role}Model'])) {
      chosen = chosen.withModel(roles['${role}Model'] as String);
    }
    final fallback = connections.first;
    return ConnectionModelSelect(
      key: Key('role-$role'),
      label: label,
      connections: connections,
      value: chosen,
      hint: '未指定（使用 ${fallback.name} · ${fallback.model}）',
      onChange: (value) => ref.read(repositoryProvider).setSetting(
        'modelRoles',
        {...roles, role: value.id, '${role}Model': value.model},
      ),
    );
  }
}

const protocolLabels = {
  ModelProtocol.openAICompatible: 'OpenAI 兼容接口',
  ModelProtocol.comfyUI: 'ComfyUI（生图）',
  ModelProtocol.novelAI: 'NovelAI（生图）',
  ModelProtocol.sillyDraftRunner: 'SillyDraft 远程执行器',
  ModelProtocol.claudeCode: 'Claude Code（本地订阅）',
  ModelProtocol.codexCli: 'Codex（本地订阅）',
};

const modelKindLabels = {
  ModelKind.text: '文本模型',
  ModelKind.image: '生图模型',
  ModelKind.both: '文本与生图',
};

class ConnectionDialog extends ConsumerStatefulWidget {
  const ConnectionDialog({super.key, this.connection});
  final ModelConnection? connection;
  @override
  ConsumerState<ConnectionDialog> createState() => _ConnectionState();
}

class _ConnectionState extends ConsumerState<ConnectionDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.connection?.name ?? '我的模型',
  );
  late final _url = TextEditingController(
    text: widget.connection?.baseUrl ?? 'https://api.openai.com/v1',
  );
  late final _model = TextEditingController(
    text: widget.connection?.models.join('\n'),
  );
  final _key = TextEditingController();
  late final _command = TextEditingController(
    text: widget.connection?.command ?? '',
  );
  late final _context = TextEditingController(
    text: '${widget.connection?.contextWindow ?? 200000}',
  );
  late final _output = TextEditingController(
    text: '${widget.connection?.maxOutputTokens ?? 2048}',
  );
  late final _extras = TextEditingController(
    text: widget.connection?.extraParameters.join(', ') ?? '',
  );
  late final _disabledSampling =
      widget.connection?.disabledSamplingParameters.toSet() ?? <String>{};
  late String _tokenParameter =
      widget.connection?.outputTokenParameter ?? 'max_tokens';
  late final _id =
      widget.connection?.id ??
      List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  bool _busy = false, _obscure = true;
  bool _advanced = false;

  /// The loaded connection no longer matches what this device saved.
  bool _moved = false;

  /// A local command a phone may have written runs only once saved here.
  static const _commandMoved = '命令在本机之外被改动过，请核对后保存';
  bool get _unsavedCommand => _moved && _cli;
  late ModelProtocol _protocol =
      widget.connection?.protocol ?? ModelProtocol.openAICompatible;
  late bool _allowInsecure = widget.connection?.allowInsecureHttp ?? false;
  late ModelKind _kind = widget.connection?.kind ?? ModelKind.text;
  late ComfyWorkflow? _workflow = widget.connection?.comfyWorkflow;
  late ComfyWorkflow? _editWorkflow = widget.connection?.comfyEditWorkflow;
  late bool _showEdit = _editWorkflow != null;
  late int _maxReferences = widget.connection?.maxReferenceImages ?? 16;
  bool get _comfy => _protocol == ModelProtocol.comfyUI;
  bool get _novelAI => _protocol == ModelProtocol.novelAI;
  bool get _text => !_comfy && !_novelAI && _kind != ModelKind.image;
  bool get _remote => _protocol == ModelProtocol.sillyDraftRunner;
  bool get _cli => _protocol.isLocalCli;
  String get _tool =>
      _protocol == ModelProtocol.claudeCode ? 'claude' : 'codex';
  List<String> _models = [];
  String? _message;
  GenerationCancellation? _testing;
  ConnectionProbeResult? _probe;
  List<String> get _selectedModels => _model.text
      .split(RegExp(r'[,，\r\n]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();
  Set<String> get _modelOptions => {..._models, ..._selectedModels};
  @override
  void initState() {
    super.initState();
    if (widget.connection case final connection?) {
      ref
          .read(servicesProvider)
          .endpointTrusted(connection)
          // A record that cannot be read is no proof either.
          .catchError((Object _) => false)
          .then((trusted) {
            if (mounted && !trusted) setState(() => _moved = true);
          });
    }
  }

  @override
  void dispose() {
    _testing?.cancel();
    for (final c in [
      _name,
      _url,
      _model,
      _key,
      _command,
      _context,
      _output,
      _extras,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  ModelConnection _configuration({bool listing = false}) {
    final selected = _comfy && _workflow?.modelInput.isNotEmpty != true
        ? <String>['workflow']
        : _selectedModels;
    if (selected.isEmpty && (listing || _cli || _comfy)) {
      selected.add(
        _cli
            ? 'default'
            : _comfy
            ? 'workflow'
            : 'model-list',
      );
    }
    return ModelConnection(
      id: _id,
      name: _name.text.trim(),
      protocol: _protocol,
      allowInsecureHttp: _allowInsecure,
      baseUrl: _cli ? '' : _url.text.trim(),
      command: _cli ? _command.text.trim() : '',
      model: selected.contains(widget.connection?.model)
          ? widget.connection!.model
          : selected.firstOrNull ?? '',
      models: selected,
      kind: _comfy || _novelAI
          ? ModelKind.image
          : _protocol == ModelProtocol.codexCli
          ? ModelKind.both
          : _cli
          ? ModelKind.text
          : _kind,
      comfyWorkflow: _comfy ? _workflow : null,
      comfyEditWorkflow: _comfy && _showEdit ? _editWorkflow : null,
      maxReferenceImages: _maxReferences,
      contextWindow: int.parse(_context.text),
      maxOutputTokens: int.parse(_output.text),
      outputTokenParameter: _tokenParameter,
      disabledSamplingParameters: _disabledSampling.toList(),
      extraParameters: _extras.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }

  void _switchProtocol(ModelProtocol? value) {
    if (value == null || value == _protocol) return;
    setState(() {
      final wasCli = _cli;
      final wasComfy = _comfy;
      final wasNovelAI = _novelAI;
      _protocol = value;
      _models = [];
      _message = null;
      _probe = null;
      if (wasNovelAI) {
        _kind = ModelKind.text;
        if (_url.text == 'https://image.novelai.net') {
          _url.text = 'https://api.openai.com/v1';
        }
        if (_selectedModels.every(NovelAIImageProvider.models.contains)) {
          _model.clear();
        }
        if (_name.text == 'NovelAI') _name.text = '我的模型';
      }
      if (_comfy) {
        _kind = ModelKind.image;
        if (_url.text == 'https://api.openai.com/v1') {
          _url.text = 'http://127.0.0.1:8188';
        }
        if (_name.text == '我的模型') _name.text = 'ComfyUI';
      } else if (wasComfy) {
        _kind = ModelKind.text;
        if (_url.text == 'http://127.0.0.1:8188') {
          _url.text = 'https://api.openai.com/v1';
        }
      }
      if (_novelAI) {
        _kind = ModelKind.image;
        if (_url.text == 'https://api.openai.com/v1') {
          _url.text = 'https://image.novelai.net';
        }
        if (_name.text == '我的模型') _name.text = 'NovelAI';
        if (_selectedModels.isEmpty) {
          _model.text = NovelAIImageProvider.models.first;
        }
      }
      if (_cli && !wasCli) {
        _kind = ModelKind.text;
        // Sensible defaults for a subscription; untouched values only.
        if (_name.text == '我的模型') {
          _name.text = protocolLabels[value]!.split('（').first;
        }
        if (_output.text == '2048') _output.text = '8192';
      }
    });
  }

  /// Sends one tiny request through the connection as filled in now — the
  /// same code path real writing uses — and shows what came back.
  Future<void> _test() async {
    final running = _testing;
    if (running != null) return running.cancel();
    if (!_form.currentState!.validate()) return;
    if (_unsavedCommand) {
      return setState(
        () => _probe = const ConnectionProbeResult(
          ok: false,
          elapsed: Duration.zero,
          error: _commandMoved,
        ),
      );
    }
    final cancel = GenerationCancellation();
    setState(() {
      _testing = cancel;
      _probe = null;
    });
    ModelProvider? provider;
    try {
      provider = await ref
          .read(servicesProvider)
          .draftProvider(
            _configuration(),
            secret: _key.text.isEmpty ? null : _key.text,
          );
      final result = await probeConnection(provider, cancellation: cancel);
      if (mounted) setState(() => _probe = result);
    } catch (e) {
      if (mounted) {
        setState(
          () => _probe = ConnectionProbeResult(
            ok: false,
            elapsed: Duration.zero,
            error: '$e',
          ),
        );
      }
    } finally {
      provider?.close();
      if (mounted) setState(() => _testing = null);
    }
  }

  Widget _probeResult(ConnectionProbeResult result) {
    final colors = context.theme.colors;
    final good = result.ok && result.warning == null;
    final seconds = (result.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    final tokens =
        result.usage['total_tokens'] ?? result.usage['output_tokens'];
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: FAlert(
        key: const Key('connection-test-result'),
        variant: result.ok ? FAlertVariant.primary : FAlertVariant.destructive,
        icon: Icon(
          !result.ok
              ? FLucideIcons.circleAlert
              : good
              ? FLucideIcons.circleCheck
              : FLucideIcons.info,
        ),
        title: Text(result.ok ? '模型正常返回 · $seconds 秒' : '测试未通过 · $seconds 秒'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.reply.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '回复：${result.reply}',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.foreground),
              ),
            ],
            if (result.ok && (result.finishReason != null || tokens != null))
              Text(
                [
                  if (result.finishReason != null)
                    '结束原因 ${result.finishReason}',
                  if (tokens != null) '用量 $tokens tokens',
                  if (result.sawReasoning) '含推理输出',
                ].join(' · '),
              ),
            if (result.warning != null) ...[
              const SizedBox(height: 6),
              Text(result.warning!),
            ],
            if (result.error != null) ...[
              const SizedBox(height: 6),
              SelectableText(
                result.error!,
                style: DefaultTextStyle.of(context).style,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<T> _comfyRequest<T>(Future<T> Function(ComfyUIProvider) action) async {
    final config = _configuration(listing: true);
    final secret = _key.text.isNotEmpty
        ? _key.text
        : await ref.read(servicesProvider).savedKey(config);
    final provider = ComfyUIProvider(config: config, apiKey: secret);
    try {
      return await action(provider);
    } finally {
      provider.close();
    }
  }

  Future<void> _list() async {
    if (_unsavedCommand) return setState(() => _message = _commandMoved);
    setState(() {
      _busy = true;
      _message = null;
    });
    ModelProvider? provider;
    try {
      if (_novelAI) {
        setState(() {
          _models = NovelAIImageProvider.models;
          _message = '内置常用模型列表，可手动填写其他模型 ID；未发送网络请求。';
        });
        return;
      }
      if (_cli) {
        final cli = LocalCliProvider(config: _configuration(listing: true));
        final status = await cli.check();
        final models = await cli.listModels();
        if (mounted) {
          setState(() {
            _models = models;
            _message = status;
          });
        }
        return;
      }
      if (_comfy) {
        final models = await _comfyRequest((provider) => provider.listModels());
        if (mounted) {
          setState(() {
            _models = models;
            _message = '连接成功，发现 ${models.length} 个生图模型';
          });
        }
        return;
      }
      final config = _configuration(listing: true);
      final secret = _key.text.isNotEmpty
          ? _key.text
          : await ref.read(servicesProvider).savedKey(config);
      provider = _remote
          ? RemoteModelProvider(config: config, accessToken: secret)
          : OpenAICompatibleProvider(config: config, apiKey: secret);
      final models = await provider.listModels();
      if (mounted) {
        setState(() {
          _models = models;
          _message = '连接成功，发现 ${models.length} 个模型';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _message = e.toString());
    } finally {
      provider?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (_unsavedCommand) {
      final command = _command.text.trim();
      final confirmed = await confirmAction(
        context,
        title: '确认使用此命令？',
        message:
            '保存后，本机的生成任务会运行这个命令：\n${command.isEmpty ? '自动查找 $_tool' : command}',
        confirmLabel: '保存',
      );
      if (!confirmed || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      if (_cli) {
        await ref.read(servicesProvider).saveConnection(_configuration());
        if (mounted) Navigator.pop(context);
        return;
      }
      if ((_remote || _novelAI) &&
          _key.text.isEmpty &&
          (await ref.read(servicesProvider).secrets.read('model/$_id') ?? '')
              .isEmpty) {
        throw FormatException(
          _novelAI ? '请填写 NovelAI API Key' : '请填写远程执行器访问令牌',
        );
      }
      await ref
          .read(servicesProvider)
          .saveConnection(
            _configuration(),
            apiKey: _key.text.isEmpty && widget.connection != null
                ? null
                : _key.text,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _delete() async {
    final yes = await confirmAction(
      context,
      title: '删除此连接？',
      message: '系统中保存的密钥也会删除。已有作品与任务结果会保留。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (yes) {
      await ref.read(servicesProvider).removeConnection(_id);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    final tokenParameters = {
      'max_tokens',
      'max_completion_tokens',
      _tokenParameter,
    };
    return AppDialog(
      maxWidth: 540,
      title: Text(widget.connection == null ? '添加模型连接' : '编辑模型连接'),
      body: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_moved) ...[
              FAlert(
                variant: FAlertVariant.destructive,
                icon: const Icon(FLucideIcons.circleAlert),
                title: Text(
                  _cli
                      ? '此连接的命令在本机之外被改动过，可能来自已配对的手机。请核对命令后保存。'
                      : '此连接的地址或命令在本机之外被改动过，可能来自已配对的手机。请核对后重新输入密钥并保存。',
                ),
              ),
              const SizedBox(height: 16),
            ],
            FSelect<ModelProtocol>(
              label: const Text('连接方式'),
              enabled: !_busy && _testing == null,
              items: {
                for (final e in protocolLabels.entries)
                  if (!e.key.isLocalCli ||
                      localCliAvailable ||
                      e.key == _protocol)
                    e.value: e.key,
              },
              control: FSelectControl<ModelProtocol>.lifted(
                value: _protocol,
                onChange: _switchProtocol,
              ),
            ),
            if (!_cli && !_comfy && !_novelAI) ...[
              const SizedBox(height: 16),
              FSelect<ModelKind>(
                label: const Text('模型用途'),
                enabled: !_busy && _testing == null,
                items: {
                  for (final entry in modelKindLabels.entries)
                    entry.value: entry.key,
                },
                control: FSelectControl.lifted(
                  value: _kind,
                  onChange: (v) {
                    if (v != null) {
                      setState(() {
                        _kind = v;
                        _probe = null;
                      });
                    }
                  },
                ),
              ),
            ],
            if (_cli)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '使用你在终端登录的 ${_protocol == ModelProtocol.claudeCode ? 'Claude' : 'ChatGPT'} 订阅，不需要 API Key。'
                  '请先在终端运行 $_tool 完成登录。不支持文本补全模板，采样参数不会生效。'
                  '${_protocol == ModelProtocol.codexCli ? '支持插画和参考图生图，需要 Codex 内置生图工具；尺寸和质量作为画面要求传递。连接测试仅验证文本。' : '不支持插画。'}',
                  style: theme.typography.body.sm.copyWith(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FTextFormField(
              control: FTextFieldControl.managed(controller: _name),
              label: const Text('连接名称'),
              validator: _required,
            ),
            const SizedBox(height: 16),
            if (_cli)
              FTextFormField(
                key: const ValueKey('command'),
                control: FTextFieldControl.managed(controller: _command),
                label: const Text('命令路径（可选）'),
                description: Text('留空会自动查找 $_tool；找不到时填写完整路径'),
              )
            else
              FTextFormField(
                key: const ValueKey('url'),
                control: FTextFieldControl.managed(
                  controller: _url,
                  onChange: (_) => setState(() {}),
                ),
                label: Text(
                  _comfy
                      ? 'ComfyUI 服务地址'
                      : _remote
                      ? '远程执行器地址'
                      : 'API 基础地址',
                ),
                description: Text(
                  _comfy
                      ? '例如 http://127.0.0.1:8188；手机连接电脑时填写电脑的局域网地址'
                      : _novelAI
                      ? '默认 https://image.novelai.net，不加 /v1 或 /ai/generate-image'
                      : _remote
                      ? '例如 https://runner.example，不加 /v1'
                      : '例如 https://服务地址/v1，不含 /chat/completions',
                ),
                keyboardType: TextInputType.url,
                validator: _required,
              ),
            const SizedBox(height: 16),
            if (_remote && !_cli) ...[
              FCheckbox(
                value: _allowInsecure,
                enabled: !_busy,
                onChange: (value) => setState(() => _allowInsecure = value),
                label: const Text('允许可信局域网 HTTP'),
                description: const Text('HTTP 会明文传输访问令牌与写作内容。公网请使用 HTTPS。'),
              ),
              const SizedBox(height: 16),
            ],
            if (!_cli)
              FTextFormField(
                control: FTextFieldControl.managed(controller: _key),
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                label: Text(_remote ? '访问令牌' : 'API Key'),
                description: Text(
                  widget.connection == null
                      ? (_novelAI
                            ? '填写 NovelAI 账户设置中的 Persistent API Token'
                            : _remote
                            ? '填写 SILLYDRAFT_RUNNER_TOKEN'
                            : '本地无鉴权服务可以留空')
                      : '留空保留现有密钥',
                ),
                suffixBuilder: (context, _, _) => Padding(
                  padding: const EdgeInsetsDirectional.only(end: 4),
                  child: IconAction(
                    tooltip: _obscure ? '显示密钥' : '隐藏密钥',
                    onPress: () => setState(() => _obscure = !_obscure),
                    icon: _obscure ? FLucideIcons.eye : FLucideIcons.eyeOff,
                    size: 16,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (_comfy) ...[
              ComfyWorkflowEditor(
                serverUrl: _url.text.trim(),
                initialValue: _workflow,
                listWorkflows: () =>
                    _comfyRequest((provider) => provider.listWorkflows()),
                readWorkflow: (name) =>
                    _comfyRequest((provider) => provider.readWorkflow(name)),
                onChange: (workflow) {
                  setState(() {
                    _workflow = workflow;
                    if (workflow != null &&
                        _selectedModels.isEmpty &&
                        workflow.modelInput.isNotEmpty) {
                      final (node, input) = ComfyWorkflow.splitInput(
                        workflow.modelInput,
                      );
                      _model.text =
                          workflow.nodes[node]['inputs'][input] as String;
                    }
                  });
                },
              ),
              const SizedBox(height: 16),
              if (_showEdit) ...[
                Text(
                  '图生图工作流（可选）',
                  style: context.theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ComfyWorkflowEditor(
                  edit: true,
                  serverUrl: _url.text.trim(),
                  initialValue: _editWorkflow,
                  listWorkflows: () =>
                      _comfyRequest((provider) => provider.listWorkflows()),
                  readWorkflow: (name) =>
                      _comfyRequest((provider) => provider.readWorkflow(name)),
                  onChange: (workflow) =>
                      setState(() => _editWorkflow = workflow),
                ),
                FButton(
                  variant: FButtonVariant.ghost,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(() {
                    _showEdit = false;
                    _editWorkflow = null;
                  }),
                  child: const Text('移除图生图工作流'),
                ),
              ] else
                FButton(
                  key: const Key('comfy-add-edit-workflow'),
                  variant: FButtonVariant.outline,
                  mainAxisSize: MainAxisSize.min,
                  onPress: () => setState(() => _showEdit = true),
                  prefix: const Icon(FLucideIcons.images),
                  child: const Text('添加图生图工作流（参考图生图）'),
                ),
              const SizedBox(height: 16),
            ],
            if (!_comfy &&
                !_novelAI &&
                (_kind != ModelKind.text ||
                    _protocol == ModelProtocol.codexCli)) ...[
              FSelect<int>(
                key: const Key('image-reference-capacity'),
                label: const Text('生图参考图上限'),
                description: const Text(
                  '按服务商支持填写；0 表示纯文生图，1 张时优先人物。此连接内的模型共用。',
                ),
                items: {
                  for (var i = 0; i <= 16; i++)
                    i == 0 ? '0 · 仅使用外观描述' : '$i 张': i,
                },
                control: FSelectControl<int>.lifted(
                  value: _maxReferences,
                  onChange: (value) {
                    if (value != null) setState(() => _maxReferences = value);
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (!_comfy || _workflow?.modelInput.isNotEmpty == true) ...[
              FTextFormField(
                control: FTextFieldControl.managed(
                  controller: _model,
                  onChange: (_) => setState(() {}),
                ),
                minLines: 1,
                maxLines: 4,
                label: Text(
                  _cli
                      ? '模型'
                      : _remote
                      ? '服务端模型配置 ID'
                      : '模型名称',
                ),
                hint: _cli
                    ? '留空使用 $_tool 的默认模型'
                    : _remote
                    ? '例如 writer 或 illustrator'
                    : '服务商提供的模型 ID',
                description: Text(
                  _comfy && _workflow?.modelInput.isNotEmpty != true
                      ? '未绑定模型输入时沿用工作流中的模型，可留空'
                      : '可填写多个模型，每行一个或用逗号分隔；也可从下方列表多选',
                ),
                validator: _cli || _comfy ? null : _required,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FButton(
                    variant: FButtonVariant.outline,
                    size: FButtonSizeVariant.sm,
                    mainAxisSize: MainAxisSize.min,
                    onPress: _busy || _testing != null ? null : _list,
                    prefix: const Icon(FLucideIcons.refreshCw),
                    // Wraps on a narrow dialog instead of overflowing.
                    child: Flexible(
                      child: Text(
                        _busy
                            ? '检查中…'
                            : _cli
                            ? '检查安装与登录'
                            : _novelAI
                            ? '选择常用模型'
                            : '检查连接并获取模型',
                      ),
                    ),
                  ),
                  if (_text)
                    FButton(
                      key: const Key('connection-test'),
                      variant: FButtonVariant.secondary,
                      size: FButtonSizeVariant.sm,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _test,
                      prefix: _testing == null
                          ? const Icon(FLucideIcons.play)
                          : const FCircularProgress(),
                      child: Flexible(
                        child: Text(_testing == null ? '测试连接' : '停止测试'),
                      ),
                    ),
                ],
              ),
              if (_probe != null) _probeResult(_probe!),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 12),
                  child: Text(_message!),
                ),
              if (_models.isNotEmpty) ...[
                const SizedBox(height: 4),
                FMultiSelect<String>.search(
                  {for (final m in _modelOptions) m: m},
                  // A new list gets a fresh selection.
                  key: ObjectKey(_models),
                  label: Text(_cli || _novelAI ? '常用模型（可多选）' : '从服务端模型列表多选'),
                  // Model IDs carry a vendor prefix, so match anywhere.
                  filter: (query) => _modelOptions.where(
                    (m) => m.toLowerCase().contains(query.toLowerCase()),
                  ),
                  control: FMultiValueControl<String>.lifted(
                    value: _selectedModels.toSet(),
                    onChange: (v) => setState(() => _model.text = v.join('\n')),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 16),
            if (_text)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: FTextFormField(
                      control: FTextFieldControl.managed(controller: _context),
                      keyboardType: TextInputType.number,
                      label: const Text('上下文 token 上限'),
                      validator: _positive,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FTextFormField(
                      control: FTextFieldControl.managed(controller: _output),
                      keyboardType: TextInputType.number,
                      label: const Text('输出 token 上限'),
                      validator: _positive,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            if (!_cli && _text)
              FAccordion(
                control: FAccordionControl.lifted(
                  expanded: (_) => _advanced,
                  onChange: (_, value) => setState(() => _advanced = value),
                ),
                children: [
                  FAccordionItem(
                    title: const Text('高级参数'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FSelect<String>(
                          label: const Text('输出长度参数'),
                          items: {for (final p in tokenParameters) p: p},
                          control: FSelectControl<String>.lifted(
                            value: _tokenParameter,
                            onChange: (v) {
                              if (v != null) {
                                setState(() => _tokenParameter = v);
                              }
                            },
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_protocol == ModelProtocol.openAICompatible) ...[
                          const Text('ST 常用采样参数'),
                          const SizedBox(height: 8),
                          Text(
                            '开启后发送预设中的值；后端不支持时可关闭。预设未设置的参数不会发送。',
                            style: theme.typography.body.sm,
                          ),
                          for (final parameter in stSamplingParameters)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: FSwitch(
                                label: Text(parameter),
                                value: !_disabledSampling.contains(parameter),
                                onChange: (enabled) => setState(() {
                                  if (enabled) {
                                    _disabledSampling.remove(parameter);
                                  } else {
                                    _disabledSampling.add(parameter);
                                  }
                                }),
                              ),
                            ),
                          const SizedBox(height: 16),
                        ],
                        FTextFormField(
                          control: FTextFieldControl.managed(
                            controller: _extras,
                          ),
                          label: const Text('后端支持的额外参数'),
                          description: const Text(
                            '其他参数名用逗号分隔，例如 reasoning_effort',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        SizedBox(
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              alignment: widget.connection == null
                  ? WrapAlignment.end
                  : WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.connection != null)
                  if (constraints.maxWidth < 400)
                    FTooltip(
                      tipBuilder: (_, _) => const Text('删除此连接'),
                      child: FButton.icon(
                        variant: FButtonVariant.ghost,
                        onPress: _busy ? null : _delete,
                        semanticsLabel: '删除此连接',
                        child: Icon(
                          FLucideIcons.trash2,
                          color: theme.colors.destructive,
                        ),
                      ),
                    )
                  else
                    FButton(
                      variant: FButtonVariant.ghost,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _delete,
                      prefix: Icon(
                        FLucideIcons.trash2,
                        color: theme.colors.destructive,
                      ),
                      child: Text(
                        '删除此连接',
                        style: TextStyle(color: theme.colors.destructive),
                      ),
                    ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FButton(
                      variant: FButtonVariant.outline,
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    FButton(
                      mainAxisSize: MainAxisSize.min,
                      onPress: _busy ? null : _save,
                      child: const Text('保存连接'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String? _required(String? value) =>
      value?.trim().isEmpty != false ? '请填写此项' : null;
  String? _positive(String? value) =>
      (int.tryParse(value ?? '') ?? 0) > 0 ? null : '请输入正整数';
}
