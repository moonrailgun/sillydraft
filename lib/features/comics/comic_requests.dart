import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../settings/model_select.dart';
import 'comic_editor.dart';

enum ComicRequestKind { adapt, check, images }

Future<GenerationTask?> requestComicTask(
  BuildContext context, {
  required AppServices services,
  required StorySnapshot story,
  required String chapterId,
  required ComicRequestKind kind,
  ComicRevision? head,
  String? panelId,
}) async {
  final connections = await services.connections();
  final analysis = await services.connectionFor('analysis');
  final image = await services.connectionFor('image');
  final nsfw = await services.connectionFor('imageNsfw');
  if (!context.mounted) return null;
  return showAppDialog<GenerationTask>(
    context: context,
    builder: (_) => _ComicRequest(
      services: services,
      story: story,
      chapterId: chapterId,
      kind: kind,
      head: head,
      panelId: panelId,
      connections: connections,
      analysis: analysis,
      image: image,
      nsfw: nsfw,
    ),
  );
}

class _ComicRequest extends StatefulWidget {
  const _ComicRequest({
    required this.services,
    required this.story,
    required this.chapterId,
    required this.kind,
    required this.head,
    required this.panelId,
    required this.connections,
    required this.analysis,
    required this.image,
    required this.nsfw,
  });
  final AppServices services;
  final StorySnapshot story;
  final String chapterId;
  final ComicRequestKind kind;
  final ComicRevision? head;
  final String? panelId;
  final List<ModelConnection> connections;
  final ModelConnection? analysis, image, nsfw;
  @override
  State<_ComicRequest> createState() => _ComicRequestState();
}

class _ComicRequestState extends State<_ComicRequest> {
  late var _first = widget.story.chapters.indexWhere(
    (c) => c.id == widget.chapterId,
  );
  late var _last = _first;
  late var _analysis = widget.analysis,
      _image = widget.image,
      _nsfw = widget.nsfw;
  late var _useNsfw = _nsfw != null;
  late var _style = widget.head?.document.style ?? '';
  bool _busy = false;
  bool get _images => widget.kind == ComicRequestKind.images;
  bool get _adapt => widget.kind == ComicRequestKind.adapt;

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final service = widget.services.comics;
      final branch = widget.story.branch.id;
      final task = switch (widget.kind) {
        ComicRequestKind.adapt => await service.adapt(
          branchId: branch,
          chapterIds: widget.story.chapters
              .sublist(_first, _last + 1)
              .map((c) => c.id)
              .toList(),
          connection: _analysis!,
          style: _style,
        ),
        ComicRequestKind.check => await service.check(
          branchId: branch,
          chapterId: widget.chapterId,
          connection: _analysis!,
          expectedRevisionId: widget.head!.id,
        ),
        ComicRequestKind.images => await service.generateImages(
          branchId: branch,
          chapterId: widget.chapterId,
          connection: _image!,
          promptConnection: _analysis!,
          nsfwConnection: _useNsfw ? _nsfw : null,
          panelId: widget.panelId,
          expectedRevisionId: widget.head!.id,
        ),
      };
      if (mounted) Navigator.pop(context, task);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.head?.document.asPages();
    final pages = document?.pages ?? <Map<String, dynamic>>[];
    final legacyPage = pages
        .where((p) => (p['panelIds'] as List).contains(widget.panelId))
        .firstOrNull;
    final selected =
        widget.head?.document.hasPages == false && widget.panelId != null
        ? (legacyPage?['id'])
        : widget.panelId;
    final pending = pages
        .where(
          (p) => selected != null
              ? p['id'] == selected
              : p['assetId'] == null ||
                    p['visualReview'] == true ||
                    p['fingerprint'] != document!.pageFingerprint(p),
        )
        .toList();
    final count = pending.length;
    final existing = pages.where((p) => p['assetId'] != null).length;
    final original = document?.isOriginal == true;
    return AppDialog(
      title: Text(
        _images
            ? '确认生成漫画'
            : _adapt
            ? '生成分镜'
            : original
            ? '检查连续性'
            : '检查改编',
      ),
      maxWidth: 680,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_adapt) ...[
            ComicChapterRange(
              chapters: widget.story.chapters,
              first: _first,
              last: _last,
              onChange: (first, last) => setState(() {
                _first = first;
                _last = last;
              }),
            ),
            const SizedBox(height: 16),
            Text(
              _first == 0
                  ? '从首章开始，无额外前情处理。'
                  : '会先整理第 1 至 $_first 章作为前情，增加文本调用；不会生成前情图片。',
            ),
            const SizedBox(height: 12),
            const Text(
              '逐章提取事实、编排分镜并对照原文检查。已有漫画的章节会生成候选，人工修改不会自动合入；采用后旧稿和图片仍保留在历史中。',
            ),
            const SizedBox(height: 16),
            comicField(
              '画风与视觉设定',
              _style,
              (v) => _style = v,
              key: const Key('comic-style'),
              lines: 4,
            ),
          ],
          ConnectionModelSelect(
            label: _images
                ? '分级与提示词模型'
                : original
                ? '连续性检查模型'
                : '改编与检查模型',
            connections: widget.connections
                .where((c) => connectionServes(c, 'analysis'))
                .toList(),
            value: _analysis,
            onChange: (c) => setState(() => _analysis = c),
            enabled: !_busy,
            hint: '请先在设置中配置文本模型',
          ),
          if (_images) ...[
            const SizedBox(height: 16),
            ConnectionModelSelect(
              label: '生图模型',
              connections: widget.connections
                  .where((c) => connectionServes(c, 'image'))
                  .toList(),
              value: _image,
              onChange: (c) => setState(() => _image = c),
              enabled: !_busy,
              hint: '请先在设置中配置生图模型',
            ),
            const SizedBox(height: 16),
            FCheckbox(
              label: const Text('按内容分级切换到 NSFW 生图模型'),
              value: _useNsfw,
              onChange: _busy ? null : (v) => setState(() => _useNsfw = v),
            ),
            if (_useNsfw) ...[
              const SizedBox(height: 12),
              ConnectionModelSelect(
                label: 'NSFW 生图模型',
                connections: widget.connections
                    .where((c) => connectionServes(c, 'imageNsfw'))
                    .toList(),
                value: _nsfw,
                onChange: (c) => setState(() => _nsfw = c),
                enabled: !_busy,
              ),
            ],
            const SizedBox(height: 16),
            Text(
              '共 ${pages.length} 页，已有 $existing 张。\n本次${widget.panelId == null ? '补齐或重画待处理页面' : '重画指定页面'}：$count 张。',
            ),
            const SizedBox(height: 12),
            const Text(
              '每页先做内容分级和提示词转换，再绘制包含分镜及对白的完整漫画页。失败即停，可继续未完成部分；有效图片会复用。',
            ),
            const SizedBox(height: 12),
            if (_image != null) Text(_referenceMessage(_image!)),
            if (_useNsfw && _nsfw != null)
              Text('NSFW：${_referenceMessage(_nsfw!)}'),
            const SizedBox(height: 16),
            FAccordion(
              children: [
                FAccordionItem(
                  title: const Text('查看画风、视觉设定与本次画面'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(_style.isEmpty ? '画风：未指定' : '画风：$_style'),
                      const SizedBox(height: 12),
                      for (final (i, p) in pages.indexed)
                        if (pending.any((v) => v['id'] == p['id']))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              '第 ${i + 1} 页：\n${document!.pageTranscript(p)}\n已选参考图：${(p['referenceAssetIds'] as List).length} 张',
                            ),
                          ),
                    ],
                  ),
                ),
              ],
            ),
          ] else if (!_adapt) ...[
            const SizedBox(height: 16),
            Text(
              original
                  ? '根据此前漫画检查人物、场景、对白和剧情连续性。仍有问题时请编辑分镜；页面内容变化后需要重画。'
                  : '会逐段对照冻结原文，检查遗漏、虚构、否定、说话者和前后衔接。检查结果绑定本次分镜版本；仍有问题时请继续编辑。',
            ),
          ],
        ],
      ),
      actions: [
        comicButton('取消', _busy ? null : () => Navigator.pop(context)),
        FButton(
          onPress:
              _busy ||
                  _analysis == null ||
                  _images &&
                      (_image == null ||
                          count == 0 ||
                          _useNsfw && _nsfw == null)
              ? null
              : _start,
          child: Text(
            _busy
                ? '正在创建任务…'
                : _images
                ? '确认生成 $count 张'
                : _adapt
                ? '生成分镜'
                : '开始检查',
          ),
        ),
      ],
    );
  }

  String _referenceMessage(ModelConnection c) => referenceLimit(c) == 0
      ? '${c.name} 仅使用文字设定，不支持参考图。'
      : '${c.name} 最多使用 ${referenceLimit(c)} 张参考图，按所选顺序加入，再加入前页；超出部分不发送。';
}

class ComicChapterRange extends StatelessWidget {
  const ComicChapterRange({
    super.key,
    required this.chapters,
    required this.first,
    required this.last,
    required this.onChange,
  });
  final List<Chapter> chapters;
  final int first, last;
  final void Function(int, int) onChange;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      FSelect<int>(
        label: const Text('起始章节'),
        items: {
          for (final (i, c) in chapters.indexed) '${i + 1} · ${c.title}': i,
        },
        control: FSelectControl.lifted(
          value: first,
          onChange: (v) {
            if (v != null) onChange(v, last < v ? v : last);
          },
        ),
      ),
      const SizedBox(height: 16),
      FSelect<int>(
        label: const Text('结束章节'),
        items: {
          for (final (i, c) in chapters.indexed)
            if (i >= first) '${i + 1} · ${c.title}': i,
        },
        control: FSelectControl.lifted(
          value: last,
          onChange: (v) {
            if (v != null) onChange(first, v);
          },
        ),
      ),
    ],
  );
}
