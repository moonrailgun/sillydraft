import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

final connectionsProvider = FutureProvider<List<ModelConnection>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(servicesProvider).connections();
});

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appearance = ref.watch(settingProvider('appearance')).value;
    final roles = ref.watch(settingProvider('modelRoles')).value ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '让工具适合你的写作方式',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 24),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '外观',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
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
                            ChoiceChip(
                              label: Text(entry.value),
                              selected:
                                  (appearance?['mode'] ?? 'system') ==
                                  entry.key,
                              onSelected: (_) =>
                                  ref.read(repositoryProvider).setSetting(
                                    'appearance',
                                    {'mode': entry.key},
                                  ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '模型连接',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => const ConnectionDialog(),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('添加连接'),
                  ),
                ],
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('支持 OpenAI 兼容的聊天与文本补全接口。密钥只保存在系统安全存储中。'),
              ),
              AsyncView(
                value: ref.watch(connectionsProvider),
                builder: (List<ModelConnection> connections) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (connections.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('尚未配置模型。你仍然可以离线编辑和阅读，添加连接后即可使用 AI 创作。'),
                        ),
                      ),
                    for (final connection in connections)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Card(
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 8,
                            ),
                            leading: const Icon(Icons.hub_outlined),
                            title: Text(connection.name),
                            subtitle: Text(
                              '${connection.model}\n${connection.baseUrl}',
                            ),
                            isThreeLine: true,
                            trailing: IconButton(
                              tooltip: '编辑连接',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => showDialog<void>(
                                context: context,
                                builder: (_) =>
                                    ConnectionDialog(connection: connection),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (connections.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text(
                        '任务使用的模型',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),
                      for (final role in {
                        'writing': '正文写作',
                        'editor': '编辑 Agent',
                        'analysis': '资料整理',
                        'image': '插画生成',
                      }.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: DropdownButtonFormField<String>(
                            key: ValueKey(
                              '${role.key}:${roles[role.key]}:${connections.length}',
                            ),
                            isExpanded: true,
                            initialValue:
                                connections.any((c) => c.id == roles[role.key])
                                ? roles[role.key] as String
                                : connections.first.id,
                            decoration: InputDecoration(labelText: role.value),
                            items: connections
                                .map(
                                  (c) => DropdownMenuItem(
                                    value: c.id,
                                    child: Text(
                                      '${c.name} · ${c.model}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) =>
                                ref.read(repositoryProvider).setSetting(
                                  'modelRoles',
                                  {...roles, role.key: value},
                                ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 32),
              const Divider(),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.auto_stories_outlined),
                title: Text('SillyDraft · 胡闹草稿'),
                subtitle: Text('正文属于作品，Agent 是创作工具。\n本地优先，支持手机与桌面。'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
  late final _model = TextEditingController(text: widget.connection?.model);
  final _key = TextEditingController();
  late final _context = TextEditingController(
    text: '${widget.connection?.contextWindow ?? 32768}',
  );
  late final _output = TextEditingController(
    text: '${widget.connection?.maxOutputTokens ?? 2048}',
  );
  late final _extras = TextEditingController(
    text: widget.connection?.extraParameters.join(', ') ?? '',
  );
  late String _tokenParameter =
      widget.connection?.outputTokenParameter ?? 'max_tokens';
  late final _id =
      widget.connection?.id ??
      List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  bool _busy = false, _obscure = true;
  List<String> _models = [];
  String? _message;
  @override
  void dispose() {
    for (final c in [_name, _url, _model, _key, _context, _output, _extras]) {
      c.dispose();
    }
    super.dispose();
  }

  ModelConnection _configuration({bool listing = false}) => ModelConnection(
    id: _id,
    name: _name.text.trim(),
    baseUrl: _url.text.trim(),
    model: _model.text.trim().isEmpty && listing
        ? 'model-list'
        : _model.text.trim(),
    contextWindow: int.parse(_context.text),
    maxOutputTokens: int.parse(_output.text),
    outputTokenParameter: _tokenParameter,
    extraParameters: _extras.text
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(),
  );
  Future<void> _list() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    ModelProvider? provider;
    try {
      final secret = _key.text.isNotEmpty
          ? _key.text
          : await ref.read(servicesProvider).secrets.read('model/$_id') ?? '';
      provider = OpenAICompatibleProvider(
        config: _configuration(listing: true),
        apiKey: secret,
      );
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
    setState(() => _busy = true);
    try {
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

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.all(20),
    title: Text(widget.connection == null ? '添加模型连接' : '编辑模型连接'),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: '连接名称'),
                validator: _required,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _url,
                decoration: const InputDecoration(
                  labelText: 'API 基础地址',
                  helperText: '例如 https://服务地址/v1，不含 /chat/completions',
                ),
                keyboardType: TextInputType.url,
                validator: _required,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _key,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  helperText: widget.connection == null
                      ? '本地无鉴权服务可以留空'
                      : '留空保留现有密钥',
                  suffixIcon: IconButton(
                    tooltip: _obscure ? '显示密钥' : '隐藏密钥',
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: '模型名称',
                  hintText: '服务商提供的模型 ID',
                ),
                validator: _required,
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _list,
                  icon: const Icon(Icons.sync),
                  label: Text(_busy ? '连接中…' : '检查连接并获取模型'),
                ),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_message!),
                ),
              if (_models.isNotEmpty)
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '从服务端模型列表选择'),
                  items: _models
                      .map(
                        (m) => DropdownMenuItem(
                          value: m,
                          child: Text(m, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => _model.text = v!,
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _context,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '上下文 token 上限',
                      ),
                      validator: _positive,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _output,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '输出 token 上限',
                      ),
                      validator: _positive,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('高级参数'),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _tokenParameter,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '输出长度参数'),
                    items: const [
                      DropdownMenuItem(
                        value: 'max_tokens',
                        child: Text('max_tokens'),
                      ),
                      DropdownMenuItem(
                        value: 'max_completion_tokens',
                        child: Text('max_completion_tokens'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _tokenParameter = v!),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _extras,
                    decoration: const InputDecoration(
                      labelText: '后端支持的额外参数',
                      helperText: '逗号分隔，例如 top_k, min_p',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      if (widget.connection != null)
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('删除此连接？'),
                      content: const Text('系统中保存的密钥也会删除。已有作品与任务结果会保留。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(c, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(c, true),
                          child: const Text('删除'),
                        ),
                      ],
                    ),
                  );
                  if (yes == true) {
                    await ref.read(servicesProvider).removeConnection(_id);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
          child: const Text('删除'),
        ),
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('保存连接')),
    ],
  );
  String? _required(String? value) =>
      value?.trim().isEmpty != false ? '请填写此项' : null;
  String? _positive(String? value) =>
      (int.tryParse(value ?? '') ?? 0) > 0 ? null : '请输入正整数';
}
