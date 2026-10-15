import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../remote/share_screen.dart';
import '../../app/widgets.dart';
import 'skill_providers.dart';

/// The assistant's skills, in the open Agent Skills (SKILL.md) format: turn
/// them on or off, import community skills, or write your own.
class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key});

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Agent Skill',
          extensions: ['md', 'zip', 'skill'],
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null) return;
    try {
      if (await file.length() > 16 * 1024 * 1024) {
        throw const FormatException('技能包不能超过 16 MB');
      }
      final bytes = await file.readAsBytes();
      final lower = file.name.toLowerCase();
      final skills = lower.endsWith('.md')
          ? [parseSkill(utf8.decode(bytes, allowMalformed: true))]
          : skillsFromArchive(bytes);
      if (!context.mounted) return;
      final existing = {
        for (final e in ref.read(skillsProvider).value ?? const [])
          e.skill.name,
      };
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) {
          final theme = context.theme;
          return AppDialog(
            maxWidth: 520,
            title: Text('导入 ${skills.length} 个技能'),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in skills) ...[
                  Text(
                    '${s.title}${existing.contains(s.name) ? '（将替换同名技能）' : ''}',
                    style: theme.typography.body.sm.copyWith(
                      color: theme.colors.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(s.description),
                  for (final d in s.diagnostics)
                    Text(
                      '· $d',
                      style: theme.typography.body.xs.copyWith(
                        color: theme.colors.mutedForeground,
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                const Text('技能是给助手的做事说明，会随对话发给模型。只导入你信任来源的技能；脚本不会被执行。'),
              ],
            ),
            actions: [
              FButton(
                variant: FButtonVariant.outline,
                onPress: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FButton(
                onPress: () => Navigator.pop(context, true),
                child: const Text('导入'),
              ),
            ],
          );
        },
      );
      if (ok == true) await ref.read(servicesProvider).skills.install(skills);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '助手技能',
    actions: [
      HeaderIconAction(
        icon: FLucideIcons.fileUp,
        tooltip: '导入技能（SKILL.md 或 .zip）',
        onPress: () => _import(context, ref),
      ),
    ],
    floatingActionButton: FloatingAction(
      key: const Key('skill-create'),
      icon: FLucideIcons.plus,
      label: '新建技能',
      onPress: () => Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const SkillEditScreen()),
      ),
    ),
    body: AsyncView(
      value: ref.watch(skillsProvider),
      builder: (entries) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '技能是可复用的做事方法，采用通用的 Agent Skills（SKILL.md）格式，可以直接导入 Claude、Codex 等社区里分享的技能。'
                  '助手平时只看到名称和简介，任务相符时才加载完整说明；也可以在对话开头输入“/技能名”直接启用。',
                  style: TextStyle(color: context.theme.colors.mutedForeground),
                ),
              ),
              const SizedBox(height: 8),
              if (entries.isNotEmpty)
                FTileGroup(
                  children: [
                    for (final e in entries)
                      FTile(
                        prefix: Icon(
                          e.skill.builtIn
                              ? FLucideIcons.sparkles
                              : FLucideIcons.puzzle,
                        ),
                        title: Text(e.skill.title),
                        subtitle: Text(
                          '/${e.skill.name}${e.skill.builtIn ? ' · 内置' : ''}'
                          '${e.skill.modelInvocable ? '' : ' · 仅手动启用'}\n${e.skill.description}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onPress: () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => SkillDetailScreen(skill: e.skill),
                          ),
                        ),
                        suffix: FSwitch(
                          key: Key('skill-enabled-${e.skill.name}'),
                          value: e.enabled,
                          onChange: (v) => ref
                              .read(servicesProvider)
                              .skills
                              .setEnabled(e.skill.name, v),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class SkillDetailScreen extends ConsumerWidget {
  const SkillDetailScreen({super.key, required this.skill});
  final AgentSkill skill;

  Future<void> _export(BuildContext context) async {
    try {
      final bytes = Uint8List.fromList(utf8.encode(skill.toSkillMd()));
      final file = XFile.fromData(
        bytes,
        mimeType: 'text/markdown',
        name: 'SKILL.md',
      );
      if (Platform.isAndroid || Platform.isIOS) {
        await SharePlus.instance.share(ShareParams(files: [file]));
      } else {
        final location = await getSaveLocation(
          suggestedName: '${skill.name}-SKILL.md',
        );
        if (location != null) await file.saveTo(location.path);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = context.theme;
    final muted = theme.typography.body.sm.copyWith(
      color: theme.colors.mutedForeground,
    );
    return PageScaffold(
      title: skill.title,
      actions: [
        HeaderIconAction(
          icon: FLucideIcons.pencil,
          tooltip: skill.builtIn ? '复制为我的技能并编辑' : '编辑技能',
          onPress: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute<void>(
              builder: (_) => SkillEditScreen(skill: skill),
            ),
          ),
        ),
        MenuAction(
          header: true,
          tooltip: '技能操作',
          entries: [
            menuEntry(
              '导出 SKILL.md',
              () => _export(context),
              icon: FLucideIcons.download,
            ),
            if (!skill.builtIn)
              menuEntry(
                '扫码分享',
                () => shareByQr(context, () async => skillShare(skill)),
                icon: FLucideIcons.qrCode,
              ),
            if (!skill.builtIn)
              menuEntry(
                '删除技能',
                () async {
                  await ref.read(servicesProvider).skills.remove(skill.name);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: FLucideIcons.trash2,
                destructive: true,
              ),
          ],
        ),
      ],
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                '/${skill.name}',
                style: theme.typography.body.sm.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(skill.description),
              if (skill.license.isNotEmpty || skill.compatibility.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    [
                      if (skill.license.isNotEmpty) '许可：${skill.license}',
                      if (skill.compatibility.isNotEmpty)
                        '环境：${skill.compatibility}',
                    ].join(' · '),
                    style: muted,
                  ),
                ),
              for (final d in skill.diagnostics)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: FAlert(
                    icon: const Icon(FLucideIcons.info),
                    title: Text(d),
                  ),
                ),
              const FDivider(),
              SelectableText(skill.body, style: const TextStyle(height: 1.6)),
              if (skill.files.isNotEmpty ||
                  skill.unsupportedFiles.isNotEmpty) ...[
                const FDivider(),
                Text(
                  '附带文件',
                  style: theme.typography.body.md.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (skill.files.isNotEmpty)
                  FAccordion(
                    children: [
                      for (final e in skill.files.entries)
                        FAccordionItem(
                          title: Text(e.key),
                          child: SelectableText(e.value),
                        ),
                    ],
                  ),
                for (final path in skill.unsupportedFiles)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FTile(
                      prefix: const Icon(FLucideIcons.fileX),
                      title: Text(path),
                      subtitle: const Text('脚本或二进制文件，不会读取或执行'),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Writes a skill as SKILL.md fields. Editing a built-in skill saves a copy
/// with the same name, which then takes its place.
class SkillEditScreen extends ConsumerStatefulWidget {
  const SkillEditScreen({super.key, this.skill});
  final AgentSkill? skill;
  @override
  ConsumerState<SkillEditScreen> createState() => _SkillEditState();
}

class _SkillEditState extends ConsumerState<SkillEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.skill?.name ?? '');
  late final _title = TextEditingController(
    text: widget.skill?.metadata['display-name'] ?? '',
  );
  late final _description = TextEditingController(
    text: widget.skill?.description ?? '',
  );
  late final _body = TextEditingController(
    text: widget.skill?.body ?? '# 技能名称\n\n## 步骤\n1. \n\n## 输出\n- ',
  );
  late bool _modelInvocable = widget.skill?.modelInvocable ?? true;

  @override
  void dispose() {
    for (final c in [_name, _title, _description, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    try {
      final old = widget.skill;
      final metadata = {...?old?.metadata}..remove('display-name');
      if (_title.text.trim().isNotEmpty) {
        metadata['display-name'] = _title.text.trim();
      }
      final skill = AgentSkill(
        name: _name.text.trim(),
        description: _description.text.trim(),
        body: _body.text.trim(),
        files: old?.files ?? const {},
        unsupportedFiles: old?.unsupportedFiles ?? const [],
        metadata: metadata,
        license: old?.license ?? '',
        compatibility: old?.compatibility ?? '',
        modelInvocable: _modelInvocable,
      );
      final library = ref.read(servicesProvider).skills;
      if (old != null && !old.builtIn && old.name != skill.name) {
        await library.remove(old.name);
      }
      await library.install([skill]);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: widget.skill == null ? '新建技能' : '编辑技能',
    actions: [
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: FButton(
          key: const Key('skill-save'),
          size: FButtonSizeVariant.sm,
          mainAxisSize: MainAxisSize.min,
          onPress: _save,
          child: const Text('保存'),
        ),
      ),
    ],
    body: Form(
      key: _form,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            children: [
              FTextFormField(
                key: const Key('skill-name'),
                control: FTextFieldControl.managed(controller: _name),
                label: const Text('名称（name）'),
                description: const Text(
                  '小写字母、数字和连字符，例如 villain-voice；对话里用 /名称 启用',
                ),
                validator: (v) {
                  final value = v?.trim() ?? '';
                  if (!RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$').hasMatch(value)) {
                    return '只能包含小写字母、数字和单个连字符';
                  }
                  return value.length > 64 ? '最多 64 个字符' : null;
                },
              ),
              const SizedBox(height: 16),
              FTextFormField(
                control: FTextFieldControl.managed(controller: _title),
                label: const Text('显示名称（可选）'),
              ),
              const SizedBox(height: 16),
              FTextFormField(
                key: const Key('skill-description'),
                control: FTextFieldControl.managed(controller: _description),
                minLines: 2,
                maxLines: 4,
                maxLength: 1024,
                label: const Text('简介（description）'),
                description: const Text('写清做什么、什么时候用。助手靠它判断是否加载这个技能'),
                validator: (v) => (v?.trim().isEmpty ?? true) ? '请填写简介' : null,
              ),
              const SizedBox(height: 16),
              FTile(
                title: const Text('允许助手自动使用'),
                subtitle: const Text('关闭后只能在对话里输入 /名称 手动启用'),
                suffix: FSwitch(
                  value: _modelInvocable,
                  onChange: (v) => setState(() => _modelInvocable = v),
                ),
                onPress: () =>
                    setState(() => _modelInvocable = !_modelInvocable),
              ),
              const SizedBox(height: 16),
              FTextFormField(
                key: const Key('skill-body'),
                control: FTextFieldControl.managed(controller: _body),
                minLines: 12,
                maxLines: null,
                label: const Text('说明（SKILL.md 正文，Markdown）'),
                validator: (v) => (v?.trim().isEmpty ?? true) ? '请填写说明' : null,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
