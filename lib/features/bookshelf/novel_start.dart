import 'dart:isolate';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../editor/workspace_screen.dart';
import '../resources/card_start_screen.dart';
import 'novel_dialog.dart';

const _cardExtensions = ['png', 'json', 'charx'];

/// Every way a work can begin: written from nothing, started from a
/// SillyTavern character card, or continued from an existing book.
class NovelStartOptions extends StatelessWidget {
  const NovelStartOptions({super.key, this.onChosen});

  /// Called before an option runs, e.g. to close the sheet it sits in.
  final VoidCallback? onChosen;

  @override
  Widget build(BuildContext context) {
    // The sheet closes before the option runs, so act on a context that stays.
    final host = Navigator.of(context, rootNavigator: true).context;
    void choose(Future<void> Function(BuildContext) start) {
      onChosen?.call();
      start(host);
    }

    return FTileGroup(
      description: _canDrop ? const Text('也可以把小说或角色卡文件直接拖进书架。') : null,
      children: [
        _option(
          context,
          key: const Key('start-blank'),
          icon: FLucideIcons.squarePen,
          title: '空白作品',
          subtitle: '填写书名和设定，从第一幕写起',
          onTap: () => choose(startBlankNovel),
        ),
        _option(
          context,
          key: const Key('start-card'),
          icon: FLucideIcons.userRound,
          title: '从角色卡开始',
          subtitle: '用 SillyTavern 角色卡（PNG、JSON、CHARX），选一个开场作为第一幕',
          onTap: () => choose(startFromCard),
        ),
        _option(
          context,
          key: const Key('start-import'),
          icon: FLucideIcons.bookOpenText,
          title: '续写已有小说',
          subtitle: '导入 TXT、Markdown 或 EPUB，自动分章，接着往下写',
          onTap: () => choose(startFromBook),
        ),
      ],
    );
  }

  FTile _option(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final colors = context.theme.colors;
    return FTile(
      key: key,
      prefix: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colors.secondary,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: colors.secondaryForeground),
      ),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 3),
      suffix: const Icon(FLucideIcons.chevronRight),
      onPress: onTap,
    );
  }
}

bool get _canDrop =>
    !kIsWeb &&
    const [
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ].contains(defaultTargetPlatform);

/// Whether files can be dropped onto the app on this platform.
bool get canDropFiles => _canDrop;

Future<void> showNovelStart(BuildContext context) => showAppSheet<void>(
  context: context,
  title: '开始一部作品',
  builder: (sheet) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: NovelStartOptions(onChosen: () => Navigator.pop(sheet)),
  ),
);

void _openWorkspace(BuildContext context, Novel novel) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => NovelWorkspace(novelId: novel.id)),
);

Future<void> startBlankNovel(BuildContext context) async {
  final novel = await showNovelDialog(context);
  if (novel != null && context.mounted) _openWorkspace(context, novel);
}

/// Pick one of the imported cards, or import a new card file.
Future<void> startFromCard(BuildContext context) async {
  final services = ProviderScope.containerOf(context).read(servicesProvider);
  try {
    final cards = await services.repository.listResources(
      kind: ResourceKind.character,
    );
    if (!context.mounted) return;
    if (cards.isEmpty) return await _pickCardFile(context);
    // A record tells "import a file" (card: null) apart from dismissing.
    final choice = await showAppSheet<({LibraryResource? card})>(
      context: context,
      title: '用哪张角色卡开始',
      mainAxisMaxRatio: .7,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          FItem(
            key: const Key('import-card-file'),
            prefix: const Icon(FLucideIcons.fileInput),
            title: const Text('导入角色卡文件…'),
            subtitle: const Text('PNG、JSON 或 CHARX'),
            onPress: () => Navigator.pop(sheet, (card: null)),
          ),
          const FDivider(),
          for (final card in cards)
            FItem(
              prefix: const Icon(FLucideIcons.userRound),
              title: Text(card.name),
              subtitle: Text(card.filename),
              onPress: () => Navigator.pop(sheet, (card: card)),
            ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    final card = choice.card;
    if (card == null) return await _pickCardFile(context);
    _openCardStart(context, card.id);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _pickCardFile(BuildContext context) async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: '角色卡',
        extensions: _cardExtensions,
        uniformTypeIdentifiers: ['public.png', 'public.json', 'public.data'],
      ),
    ],
  );
  if (file == null || !context.mounted) return;
  await startFromFile(context, name: file.name, read: file.readAsBytes);
}

Future<void> startFromBook(BuildContext context) async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: '小说',
        extensions: ManuscriptImporter.extensions,
        uniformTypeIdentifiers: [
          'public.plain-text',
          'net.daringfireball.markdown',
          'org.idpf.epub-container',
          'public.data',
        ],
      ),
    ],
  );
  if (file == null || !context.mounted) return;
  await startFromFile(context, name: file.name, read: file.readAsBytes);
}

/// Starts a work from a file the author picked or dropped: a book to
/// continue, or a character card.
Future<void> startFromFile(
  BuildContext context, {
  required String name,
  required Future<Uint8List> Function() read,
}) async {
  final extension = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  try {
    if (ManuscriptImporter.supports(name)) {
      final bytes = await read();
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => NovelImportScreen(filename: name, bytes: bytes),
        ),
      );
    } else if (_cardExtensions.contains(extension)) {
      final bytes = await read();
      if (!context.mounted) return;
      final resource = await _importCard(context, bytes, name);
      if (context.mounted) _openCardStart(context, resource.id);
    } else if (extension == 'sillydraft') {
      throw const FormatException('这是项目备份，请在书架右上角的“恢复项目备份”中打开');
    } else {
      throw const FormatException(
        '可以拖入或选择小说（TXT、Markdown、EPUB）或角色卡（PNG、JSON、CHARX）',
      );
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Imports a card into the resource library, reusing an identical earlier
/// import instead of keeping two copies.
Future<LibraryResource> _importCard(
  BuildContext context,
  Uint8List bytes,
  String name,
) async {
  final services = ProviderScope.containerOf(context).read(servicesProvider);
  try {
    services.library.inspect(
      bytes,
      filename: name,
      kind: ResourceKind.character,
    );
  } on FormatException catch (e) {
    throw FormatException(
      name.toLowerCase().endsWith('.json')
          ? '这个 JSON 不是角色卡。预设、世界书和正则脚本请在“资源”中导入。'
          : '无法读取角色卡：${e.message}',
    );
  }
  return services.library.importOnce(
    bytes,
    filename: name,
    kind: ResourceKind.character,
  );
}

void _openCardStart(BuildContext context, String resourceId) => Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => CardStartScreen(resourceId: resourceId),
  ),
);

/// Shows what was read from a book before it becomes a work: chapters found,
/// where the story currently ends, and anything that could not be kept.
class NovelImportScreen extends ConsumerStatefulWidget {
  const NovelImportScreen({
    super.key,
    required this.filename,
    required this.bytes,
  });
  final String filename;
  final Uint8List bytes;
  @override
  ConsumerState<NovelImportScreen> createState() => _NovelImportState();
}

class _NovelImportState extends ConsumerState<NovelImportScreen> {
  final _title = TextEditingController(), _synopsis = TextEditingController();
  ImportedManuscript? _book;
  Object? _error;
  String _pov = '第三人称';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  Future<void> _parse() async {
    setState(() => _error = null);
    final bytes = widget.bytes, filename = widget.filename;
    try {
      // Large books take a moment to split; keep the UI responsive. Small
      // ones parse in milliseconds, not worth an isolate.
      final book = bytes.length < 512 * 1024
          ? ManuscriptImporter.parse(bytes, filename: filename)
          : await Isolate.run(
              () => ManuscriptImporter.parse(bytes, filename: filename),
            );
      if (!mounted) return;
      _title.text = book.title;
      _synopsis.text = book.synopsis;
      setState(() => _book = book);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _synopsis.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final book = _book!;
    if (_title.text.trim().isEmpty) {
      showError(context, const FormatException('请填写作品名称'));
      return;
    }
    setState(() => _busy = true);
    try {
      final novel = await ref
          .read(repositoryProvider)
          .createNovelFromManuscript(
            ImportedManuscript(
              title: _title.text.trim(),
              synopsis: _synopsis.text.trim(),
              chapters: book.chapters,
            ),
            pointOfView: _pov,
          );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => NovelWorkspace(novelId: novel.id),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _book;
    return PageScaffold(
      title: '续写已有小说',
      body: book == null
          ? (_error == null
                ? const Center(child: FCircularProgress())
                : ErrorPane(message: _error.toString(), retry: _parse))
          : SafeArea(top: false, child: _form(book)),
    );
  }

  Widget _form(ImportedManuscript book) {
    final theme = context.theme, colors = theme.colors;
    final small = theme.typography.body.xs.copyWith(
      color: colors.mutedForeground,
    );
    final chapters = book.chapters;
    // Enough of the start to check the splitting, and the end, where the
    // author will pick up.
    final head = chapters.length > 12 ? chapters.take(8).toList() : chapters;
    final tail = chapters.length > 12
        ? chapters.skip(chapters.length - 3).toList()
        : const <ImportedChapter>[];
    int count(ImportedChapter c) => c.scenes.fold(
      0,
      (sum, s) => sum + s.text.replaceAll(RegExp(r'\s'), '').length,
    );
    Widget chapter(ImportedChapter c) => FItem(
      prefix: const Icon(FLucideIcons.fileText),
      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      details: Text('${count(c)} 字'),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '${chapters.length} 章 · ${book.characters} 字',
              key: const Key('import-summary'),
              style: theme.typography.body.xl2.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '来自 ${widget.filename}。导入后正文属于新作品，原文件不会改动；之后可以从最后一章接着写，也可以让助手续写。',
              style: theme.typography.body.sm.copyWith(
                color: colors.mutedForeground,
              ),
            ),
            for (final warning in book.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: FAlert(
                  icon: const Icon(FLucideIcons.triangleAlert),
                  title: Text(warning),
                ),
              ),
            const SizedBox(height: 24),
            FTextField(
              key: const Key('import-title'),
              control: FTextFieldControl.managed(controller: _title),
              label: const Text('作品名称'),
            ),
            const SizedBox(height: 16),
            FTextField(
              control: FTextFieldControl.managed(controller: _synopsis),
              minLines: 2,
              maxLines: 5,
              label: const Text('故事简介'),
            ),
            const SizedBox(height: 16),
            FSelect<String>(
              label: const Text('叙事视角'),
              items: {
                for (final v in ['第三人称', '第一人称', '多视角']) v: v,
              },
              control: FSelectControl.lifted(
                value: _pov,
                onChange: (v) => setState(() => _pov = v ?? _pov),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '识别到的章节',
              style: theme.typography.body.md.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.foreground,
              ),
            ),
            const SizedBox(height: 8),
            FCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (final c in head) chapter(c),
                    if (tail.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '…… 中间还有 ${chapters.length - head.length - tail.length} 章',
                          style: small,
                        ),
                      ),
                      for (final c in tail) chapter(c),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            FButton(
              key: const Key('import-create'),
              onPress: _busy ? null : _create,
              prefix: const Icon(FLucideIcons.bookOpen),
              child: Text(_busy ? '正在导入…' : '导入并开始续写'),
            ),
          ],
        ),
      ),
    );
  }
}
