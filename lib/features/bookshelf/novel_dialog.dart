import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

Future<Novel?> showNovelDialog(BuildContext context, {Novel? novel}) =>
    showDialog<Novel>(
      context: context,
      builder: (_) => NovelDialog(novel: novel),
    );

class NovelDialog extends ConsumerStatefulWidget {
  const NovelDialog({super.key, this.novel});
  final Novel? novel;
  @override
  ConsumerState<NovelDialog> createState() => _NovelDialogState();
}

class _NovelDialogState extends ConsumerState<NovelDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.novel?.title);
  late final _synopsis = TextEditingController(text: widget.novel?.synopsis);
  late final _style = TextEditingController(text: widget.novel?.style);
  final _goal = TextEditingController();
  late String _genre = widget.novel?.genre ?? '自由创作';
  late String _pointOfView = widget.novel?.pointOfView ?? '第三人称';
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    final novel = widget.novel;
    if (novel != null) {
      ref.read(repositoryProvider).getSetting('goal/${novel.id}').then((value) {
        if (mounted && _goal.text.isEmpty) {
          _goal.text = '${value?['words'] ?? ''}';
        }
      });
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _synopsis.dispose();
    _style.dispose();
    _goal.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final repo = ref.read(repositoryProvider);
      final old = widget.novel;
      Novel result;
      if (old == null) {
        result = await repo.createNovel(
          title: _title.text.trim(),
          synopsis: _synopsis.text.trim(),
          genre: _genre,
          style: _style.text.trim(),
          pointOfView: _pointOfView,
        );
        final chapter = await repo.createChapter(
          branchId: result.activeBranchId,
          title: '第一章',
        );
        await repo.createScene(
          branchId: result.activeBranchId,
          chapterId: chapter.id,
          title: '第一幕',
        );
      } else {
        result = old.copyWith(
          title: _title.text.trim(),
          synopsis: _synopsis.text.trim(),
          genre: _genre,
          style: _style.text.trim(),
          pointOfView: _pointOfView,
        );
        await repo.updateNovel(result);
      }
      await repo.setSetting('goal/${result.id}', {
        'words': int.tryParse(_goal.text.trim()) ?? 0,
      });
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.all(20),
    title: Text(widget.novel == null ? '开始一个新故事' : '作品信息'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const Key('novel-title'),
                controller: _title,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '作品名称',
                  hintText: '给你的故事一个名字',
                ),
                validator: (value) =>
                    value?.trim().isEmpty != false ? '请填写作品名称' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _genre,
                decoration: const InputDecoration(labelText: '题材'),
                items: {'自由创作', '悬疑幻想', '科幻', '奇幻', '都市', '言情', '历史', _genre}
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => _genre = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _synopsis,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '故事简介',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _pointOfView,
                decoration: const InputDecoration(labelText: '叙事视角'),
                items: {'第三人称', '第一人称', '多视角', _pointOfView}
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => _pointOfView = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _style,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '文风偏好',
                  hintText: '例如：细腻、克制，重视人物对话',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _goal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '目标字数',
                  hintText: '留空表示自由写作',
                ),
                validator: (value) =>
                    value == null ||
                        value.trim().isEmpty ||
                        (int.tryParse(value.trim()) ?? -1) >= 0
                    ? null
                    : '请填写非负整数',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(
          _busy
              ? '保存中…'
              : widget.novel == null
              ? '创建小说'
              : '保存修改',
        ),
      ),
    ],
  );
}
