import 'dart:convert';

import 'package:flutter/material.dart' show MaterialPageRoute, SelectableText;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../editor/workspace_screen.dart';

class ProjectSyncScreen extends ConsumerStatefulWidget {
  const ProjectSyncScreen({super.key, this.novelId});
  final String? novelId;
  @override
  ConsumerState<ProjectSyncScreen> createState() => _SyncState();
}

class _SyncState extends ConsumerState<ProjectSyncScreen> {
  final _form = GlobalKey<FormState>();
  final _url = TextEditingController(),
      _user = TextEditingController(),
      _password = TextEditingController(),
      _phrase = TextEditingController();
  String _auth = 'none';
  String? _loadedUrl, _loadedUser, _loadedAuth, _message;
  bool _insecure = false, _busy = false, _loaded = false;
  Map<String, dynamic> _state = {};
  HttpSnapshotTransport? _transport;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final id = widget.novelId;
      if (id != null) {
        final repo = ref.read(repositoryProvider),
            config =
                await ref
                    .read(repositoryProvider)
                    .getSetting('syncConfig/$id') ??
                {};
        _url.text = config['url'] as String? ?? '';
        _loadedUrl = _url.text;
        _user.text = config['username'] as String? ?? '';
        _auth = config['authType'] as String? ?? 'none';
        _loadedUser = _user.text;
        _loadedAuth = _auth;
        _insecure = config['allowHttp'] == true;
        _state = await repo.getSetting('syncState/$id') ?? {};
      }
      if (mounted) setState(() => _loaded = true);
    } catch (e) {
      if (mounted) {
        setState(() => _loaded = true);
        showError(context, e);
      }
    }
  }

  @override
  void dispose() {
    _transport?.close();
    for (final c in [_url, _user, _password, _phrase]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<({String authorization, String passphrase})> _credentials() async {
    final services = ref.read(servicesProvider), id = widget.novelId;
    var auth = '';
    if (_auth != 'none') {
      if (_password.text.isNotEmpty) {
        auth = _auth == 'basic'
            ? 'Basic ${base64Encode(utf8.encode('${_user.text}:${_password.text}'))}'
            : 'Bearer ${_password.text}';
      } else if (id != null &&
          _loadedUrl == _url.text.trim() &&
          _loadedUser == _user.text &&
          _loadedAuth == _auth) {
        auth = await services.secrets.read('sync/$id/auth') ?? '';
      }
      if (auth.isEmpty ||
          (_auth == 'basic' && !auth.startsWith('Basic ')) ||
          (_auth == 'bearer' && !auth.startsWith('Bearer '))) {
        throw const FormatException('请填写此同步地址使用的认证信息');
      }
    }
    final savedPhrase = id == null
        ? null
        : await services.secrets.read('sync/$id/passphrase');
    if (_state['remoteEtag'] != null &&
        _loadedUrl == _url.text.trim() &&
        savedPhrase != null &&
        _phrase.text.isNotEmpty &&
        _phrase.text != savedPhrase) {
      throw const FormatException('此作品已有同步口令。更换口令请使用新的同步地址，并在所有设备重新连接。');
    }
    final phrase = _phrase.text.isNotEmpty ? _phrase.text : savedPhrase ?? '';
    if (phrase.runes.length < 12) {
      throw const FormatException('同步口令至少需要 12 个字符，所有设备须使用相同口令');
    }
    return (authorization: auth, passphrase: phrase);
  }

  Future<void> _saveConfig(
    String id,
    ({String authorization, String passphrase}) credentials,
  ) async {
    final services = ref.read(servicesProvider);
    await services.secrets.write('sync/$id/auth', credentials.authorization);
    await services.secrets.write('sync/$id/passphrase', credentials.passphrase);
    await services.repository.setSetting('syncConfig/$id', {
      'url': _url.text.trim(),
      'username': _user.text,
      'authType': _auth,
      'allowHttp': _insecure,
    });
  }

  Future<void> _synchronize({String? resolution}) async {
    if (!_form.currentState!.validate()) return;
    if (resolution != null) {
      final yes = await confirmAction(
        context,
        title: resolution == 'local' ? '将本机版本同步到远端？' : '采用远端版本？',
        message: resolution == 'local'
            ? '远端冲突副本会继续保留在书架，可随时查看。'
            : '会先保存本机冲突副本，再更新当前作品。',
        confirmLabel: '继续',
      );
      if (!yes || !mounted) return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final services = ref.read(servicesProvider),
          credentials = await _credentials();
      await services.flushDrafts();
      final transport = HttpSnapshotTransport(
        url: Uri.parse(_url.text.trim()),
        authorization: credentials.authorization,
        allowInsecureHttp: _insecure,
      );
      _transport = transport;
      final sync = ProjectSync(
        repository: services.repository,
        backup: services.backups,
        transport: transport,
        passphrase: credentials.passphrase,
      );
      final id = widget.novelId;
      if (id == null) {
        final novel = await sync.connect();
        await _saveConfig(novel.id, credentials);
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute<void>(
              builder: (_) => NovelWorkspace(novelId: novel.id),
            ),
          );
        }
      } else {
        if (_loadedUrl != null && _loadedUrl != _url.text.trim()) {
          await services.repository.removeSetting('syncState/$id');
        }
        await _saveConfig(id, credentials);
        _loadedUrl = _url.text.trim();
        _loadedUser = _user.text;
        _loadedAuth = _auth;
        final result = resolution == 'local'
            ? await sync.resolveWithLocal(
                id,
                observedEtag: _state['conflictEtag'] as String,
              )
            : resolution == 'remote'
            ? await sync.resolveWithRemote(
                id,
                observedEtag: _state['conflictEtag'] as String,
              )
            : await sync.synchronize(id);
        final state =
            await services.repository.getSetting('syncState/$id') ?? {};
        if (mounted) {
          setState(() {
            _state = state;
            _message = switch (result.action) {
              SyncAction.unchanged => '本机与远端内容一致',
              SyncAction.uploaded => '本机版本已上传',
              SyncAction.downloaded => '已接收远端版本',
              SyncAction.conflict => '两端都发生了修改，已保留远端冲突副本',
            };
          });
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      _transport?.close();
      _transport = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final id = widget.novelId;
    if (id == null) return;
    final yes = await confirmAction(
      context,
      title: '断开此作品的同步？',
      message: '本机作品与远端文件保留。本机保存的同步认证和口令会移除，请确认已另行保存口令。',
      confirmLabel: '断开同步',
    );
    if (!yes || !mounted) return;
    final services = ref.read(servicesProvider);
    await services.repository.removeSetting('syncConfig/$id');
    await services.repository.removeSetting('syncState/$id');
    await services.secrets.delete('sync/$id/auth');
    await services.secrets.delete('sync/$id/passphrase');
    if (mounted) {
      setState(() {
        _state = {};
        _loadedUrl = null;
        _message = '已断开同步，本机作品和远端文件保留';
        _password.clear();
        _phrase.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return PopScope(
      canPop: !_busy,
      child: PageScaffold(
        title: widget.novelId == null ? '连接远端作品' : '多设备同步',
        body: SafeArea(
          top: false,
          child: !_loaded
              ? const Center(child: FCircularProgress())
              : ContentLayout(
                  maxWidth: 720,
                  builder: (_, inset) => Form(
                    key: _form,
                    child: ListView(
                      padding: inset + const EdgeInsets.all(24),
                      children: [
                        const Text(
                          '使用自己的 HTTP / WebDAV 文件空间。服务需支持强 ETag 与条件 PUT；所有设备填写同一个文件地址和同步口令。',
                        ),
                        const SizedBox(height: 20),
                        FTextFormField(
                          control: FTextFieldControl.managed(controller: _url),
                          enabled: !_busy,
                          autocorrect: false,
                          keyboardType: TextInputType.url,
                          label: const Text('完整备份文件地址'),
                          hint: 'https://你的服务/novel.sillydraft',
                          validator: (v) =>
                              Uri.tryParse(v?.trim() ?? '')?.hasAuthority ==
                                  true
                              ? null
                              : '请填写完整文件地址',
                        ),
                        const SizedBox(height: 16),
                        FSelect<String>(
                          label: const Text('同步服务认证'),
                          enabled: !_busy,
                          items: const {
                            '无认证': 'none',
                            '用户名与密码（Basic）': 'basic',
                            '访问令牌（Bearer）': 'bearer',
                          },
                          control: FSelectControl.lifted(
                            value: _auth,
                            onChange: (v) {
                              if (v != null) setState(() => _auth = v);
                            },
                          ),
                        ),
                        if (_auth == 'basic') ...[
                          const SizedBox(height: 16),
                          FTextField(
                            control: FTextFieldControl.managed(
                              controller: _user,
                            ),
                            enabled: !_busy,
                            label: const Text('用户名'),
                          ),
                        ],
                        if (_auth != 'none') ...[
                          const SizedBox(height: 16),
                          FTextField(
                            control: FTextFieldControl.managed(
                              controller: _password,
                            ),
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            enabled: !_busy,
                            label: Text(_auth == 'basic' ? '密码' : '访问令牌'),
                            description: widget.novelId == null
                                ? null
                                : const Text('留空保留当前地址的认证；更换地址需重新填写'),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FTextField(
                          control: FTextFieldControl.managed(
                            controller: _phrase,
                          ),
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          enabled: !_busy,
                          label: const Text('项目同步口令（至少 12 个字符）'),
                          description: Text(
                            widget.novelId == null
                                ? '由另一设备创建同步时设置'
                                : '留空保留本机已保存的口令',
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('项目在上传前加密。请保留口令，口令无法重置；模型密钥不会上传。'),
                        const SizedBox(height: 12),
                        FCheckbox(
                          label: const Text('允许 HTTP（仅可信网络）'),
                          value: _insecure,
                          enabled: !_busy,
                          onChange: (v) => setState(() => _insecure = v),
                        ),
                        const SizedBox(height: 20),
                        FButton(
                          onPress: _busy ? null : () => _synchronize(),
                          prefix: const Icon(FLucideIcons.refreshCw),
                          child: Text(
                            widget.novelId == null ? '连接并下载作品' : '保存配置并同步',
                          ),
                        ),
                        if (_busy) ...[
                          const SizedBox(height: 20),
                          const FProgress(),
                          const SizedBox(height: 8),
                          const Text('正在加密或同步，请稍候…'),
                        ],
                        if (_message != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Text(_message!),
                          ),
                        if (widget.novelId != null &&
                            _state['conflictNovelId'] is String) ...[
                          const SizedBox(height: 24),
                          Text(
                            '处理并发修改',
                            style: theme.typography.body.lg.copyWith(
                              fontWeight: FontWeight.w600,
                              color: theme.colors.foreground,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text('比较后可以手动整合内容，再选择要同步的版本。未选择前，双方版本均保留。'),
                          const SizedBox(height: 12),
                          FButton(
                            variant: FButtonVariant.outline,
                            onPress: _busy
                                ? null
                                : () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => SyncConflictComparison(
                                        localId: widget.novelId!,
                                        copyId:
                                            _state['conflictNovelId'] as String,
                                      ),
                                    ),
                                  ),
                            child: const Text('比较本机与远端副本'),
                          ),
                          const SizedBox(height: 12),
                          FButton(
                            variant: FButtonVariant.outline,
                            onPress: _busy
                                ? null
                                : () => _synchronize(resolution: 'local'),
                            child: const Text('保留本机并上传'),
                          ),
                          const SizedBox(height: 12),
                          FButton(
                            variant: FButtonVariant.outline,
                            onPress: _busy
                                ? null
                                : () => _synchronize(resolution: 'remote'),
                            child: const Text('采用远端并保留本机副本'),
                          ),
                        ],
                        if (widget.novelId != null) ...[
                          const SizedBox(height: 24),
                          FButton(
                            variant: FButtonVariant.ghost,
                            onPress: _busy ? null : _disconnect,
                            child: const Text('断开此作品的同步'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class SyncConflictComparison extends ConsumerWidget {
  const SyncConflictComparison({
    super.key,
    required this.localId,
    required this.copyId,
  });
  final String localId, copyId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '同步冲突比较',
    body: SafeArea(
      top: false,
      child: AsyncView(
        value: ref.watch(novelProvider(localId)),
        builder: (Novel local) => AsyncView(
          value: ref.watch(novelProvider(copyId)),
          builder: (Novel remote) => AsyncView(
            value: ref.watch(storyProvider(local.activeBranchId)),
            builder: (StorySnapshot a) => AsyncView(
              value: ref.watch(storyProvider(remote.activeBranchId)),
              builder: (StorySnapshot b) {
                Widget panel(String label, StorySnapshot story) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FItem(
                      title: Text(label),
                      subtitle: Text(
                        '${story.branch.name} · ${story.chapters.length} 个章节',
                      ),
                      suffix: IconAction(
                        icon: FLucideIcons.externalLink,
                        tooltip: '打开此作品',
                        onPress: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                NovelWorkspace(novelId: story.novel.id),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: SelectableText(
                          story.text.replaceAll('￼', '[插图]'),
                          style: context.theme.typography.body.md.copyWith(
                            fontSize: 17,
                            height: 1.8,
                            color: context.theme.colors.foreground,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
                if (MediaQuery.sizeOf(context).width >= 900) {
                  return Row(
                    children: [
                      Expanded(child: panel('本机版本', a)),
                      const FDivider(
                        axis: Axis.vertical,
                        style: FDividerStyleDelta.delta(
                          padding: EdgeInsetsGeometryDelta.value(
                            EdgeInsets.zero,
                          ),
                        ),
                      ),
                      Expanded(child: panel('远端副本', b)),
                    ],
                  );
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: FTabs(
                    expands: true,
                    children: [
                      FTabEntry(
                        label: const Text('本机版本'),
                        child: panel('本机版本', a),
                      ),
                      FTabEntry(
                        label: const Text('远端副本'),
                        child: panel('远端副本', b),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
