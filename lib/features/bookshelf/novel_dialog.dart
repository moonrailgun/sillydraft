import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

Future<Novel?> showNovelDialog(BuildContext context, {Novel? novel}) =>
    showAppDialog<Novel>(
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
  late var _numerals = widget.novel?.chapterNumerals ?? ChapterNumerals.chinese;
  late var _format = widget.novel?.workFormat ?? WorkFormat.novel;
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
          pointOfView: _format == WorkFormat.comic ? '' : _pointOfView,
          chapterNumerals: _numerals,
          workFormat: _format,
        );
        ApplicationTracking.current?.event('Story Created', {
          'source': 'blank',
        });
        await repo.createChapter(branchId: result.activeBranchId);
      } else {
        result = old.copyWith(
          title: _title.text.trim(),
          synopsis: _synopsis.text.trim(),
          genre: _genre,
          style: _style.text.trim(),
          pointOfView: _format == WorkFormat.comic
              ? old.pointOfView
              : _pointOfView,
          chapterNumerals: _numerals,
          workFormat: _format,
        );
        await repo.updateNovel(result);
      }
      if (_format != WorkFormat.comic) {
        await repo.setSetting('goal/${result.id}', {
          'words': int.tryParse(_goal.text.trim()) ?? 0,
        });
      }
      if (mounted) Navigator.pop(context, result);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: Text(widget.novel == null ? '开始一个新故事' : '作品信息'),
    body: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FTextFormField(
            key: const Key('novel-title'),
            control: FTextFieldControl.managed(controller: _title),
            autofocus: true,
            textInputAction: TextInputAction.next,
            label: const Text('作品名称'),
            hint: '给你的故事一个名字',
            validator: (value) =>
                value?.trim().isEmpty != false ? '请填写作品名称' : null,
          ),
          const SizedBox(height: 16),
          if (widget.novel != null ||
              ref.watch(settingProvider('beta')).value?['enabled'] == true) ...[
            FSelect<WorkFormat>(
              label: const Text('作品类型'),
              items: const {'小说': WorkFormat.novel, '漫画': WorkFormat.comic},
              control: FSelectControl.lifted(
                value: _format,
                onChange: (value) => setState(() => _format = value ?? _format),
              ),
            ),
            const SizedBox(height: 16),
          ],
          FSelect<String>(
            label: const Text('题材'),
            items: {
              for (final v in {
                '自由创作',
                '悬疑幻想',
                '科幻',
                '奇幻',
                '都市',
                '言情',
                '历史',
                _genre,
              })
                v: v,
            },
            control: FSelectControl.lifted(
              value: _genre,
              onChange: (v) => setState(() => _genre = v ?? _genre),
            ),
          ),
          const SizedBox(height: 16),
          FTextFormField(
            control: FTextFieldControl.managed(controller: _synopsis),
            maxLines: 3,
            label: const Text('故事简介'),
          ),
          const SizedBox(height: 16),
          if (_format != WorkFormat.comic) ...[
            FSelect<String>(
              label: const Text('叙事视角'),
              items: {
                for (final v in {'第三人称', '第一人称', '多视角', _pointOfView}) v: v,
              },
              control: FSelectControl.lifted(
                value: _pointOfView,
                onChange: (v) =>
                    setState(() => _pointOfView = v ?? _pointOfView),
              ),
            ),
            const SizedBox(height: 16),
          ],
          FSelect<ChapterNumerals>(
            label: const Text('章节编号'),
            items: const {
              '中文数字（第六章）': ChapterNumerals.chinese,
              '阿拉伯数字（第6章）': ChapterNumerals.arabic,
            },
            control: FSelectControl.lifted(
              value: _numerals,
              onChange: (v) => setState(() => _numerals = v ?? _numerals),
            ),
          ),
          const SizedBox(height: 16),
          FTextFormField(
            control: FTextFieldControl.managed(controller: _style),
            maxLines: 2,
            label: Text(_format == WorkFormat.comic ? '画风与视觉设定' : '文风偏好'),
            hint: _format == WorkFormat.comic
                ? '描述画风、配色和阅读方向'
                : '例如：细腻、克制，重视人物对话',
          ),
          const SizedBox(height: 16),
          if (_format != WorkFormat.comic)
            FTextFormField(
              control: FTextFieldControl.managed(controller: _goal),
              keyboardType: TextInputType.number,
              label: const Text('目标字数'),
              hint: '留空表示自由写作',
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
    actions: [
      FButton(
        variant: FButtonVariant.outline,
        onPress: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FButton(
        onPress: _busy ? null : _save,
        child: Text(
          _busy
              ? '保存中…'
              : widget.novel == null
              ? (_format == WorkFormat.comic ? '创建漫画' : '创建小说')
              : '保存修改',
        ),
      ),
    ],
  );
}
