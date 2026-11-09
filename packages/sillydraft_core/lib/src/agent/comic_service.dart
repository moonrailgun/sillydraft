import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../model/comic.dart';
import '../model/lore.dart';
import '../model/task.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';
import 'illustration_service.dart';

/// Freezes manuscript versions before any model request; never writes prose.
final class ComicService {
  const ComicService({
    required this.repository,
    required this.runner,
    this.agentCall,
  });
  final StoryRepository repository;
  final TaskControl runner;
  final Map<String, dynamic>? agentCall;

  Future<GenerationTask> _start({
    required String branchId,
    required TaskKind kind,
    required Map<String, dynamic> input,
  }) => runner.start(
    branchId: branchId,
    kind: kind,
    input: {...input, 'agentComicCall': ?agentCall},
  );

  /// Freeze drawn comics up to the target; prose is never story input.
  Future<Map<String, dynamic>> _originalInput(
    String branchId,
    String chapterId,
    String? expectedRevisionId, {
    bool includeCurrent = true,
  }) async {
    final story = await repository.getStory(branchId);
    final index = story.chapters.indexWhere((c) => c.id == chapterId);
    if (index < 0) throw const FormatException('漫画话不存在');
    final head = await repository.getComic(branchId, chapterId);
    if (head?.id != expectedRevisionId) throw const ComicConflict();
    if (head != null && !head.document.isOriginal) {
      throw const FormatException('小说改编漫画请继续使用原文改编');
    }
    final prior = <Map<String, dynamic>>[], context = <Map<String, dynamic>>[];
    Map<String, dynamic>? previous;
    for (final c in story.chapters.take(index + (includeCurrent ? 1 : 0))) {
      var comic = await repository.getComic(branchId, c.id);
      // An adaptation episode is context only when checked, complete and
      // current; otherwise it is skipped, never a blocker (ruling R18).
      if (comic != null &&
          !comic.document.isOriginal &&
          (!comic.document.checked ||
              !comic.document.complete ||
              !await repository.comicSourcesCurrent(
                branchId,
                comic.document,
              ))) {
        comic = null;
      }
      if (comic != null) {
        if (comic.document.isOriginal) {
          // Checks, review flags and stale pages are hints; only gaps block.
          final page = comic.document.pages.indexWhere(
            (p) => p['assetId'] == null,
          );
          if (page >= 0) {
            throw FormatException('第 ${page + 1} 页还没有画好，请先重试或删除这一页');
          }
        }
        context.add({
          'chapterId': c.id,
          'revisionId': comic.id,
          'panels': comic.document.panels,
          'pages': comic.document.pages,
          'continuity': comic.document.toJson()['continuity'],
        });
        // An emptied episode must not hide the one before it.
        previous = comic.document.imageItems.lastOrNull ?? previous;
      }
      if (c.id != chapterId) {
        prior.add({'chapterId': c.id, 'revisionId': comic?.id});
      }
    }
    return {
      'comicHeads': {chapterId: head?.id},
      'comicDocuments': [if (head != null) head.document.toJson()],
      'comicContext': context,
      'comicPrior': prior,
      'comicPreviousPanel': ?previous,
      'comicStyle': story.novel.style,
    };
  }

  Future<GenerationTask> compose({
    required String branchId,
    required String chapterId,
    required String instruction,
    required ModelConnection connection,
    ModelConnection? imageConnection,
    ModelConnection? nsfwConnection,
    String? expectedRevisionId,
    bool characterSheets = false,
  }) async {
    if (instruction.trim().isEmpty) throw const FormatException('请输入开场或下一页剧情');
    final input = await _originalInput(branchId, chapterId, expectedRevisionId);
    // Sheets only for the opening: no page here and no earlier original pages.
    var opening =
        characterSheets &&
        (input['comicDocuments'] as List).every(
          (d) => (d['pages'] as List).isEmpty,
        );
    for (final prior in input['comicPrior'] as List) {
      if (!opening) break;
      final comic = await repository.getComic(
        branchId,
        prior['chapterId'] as String,
      );
      opening = comic == null || !comic.document.isOriginal;
    }
    if ((input['comicDocuments'] as List).isEmpty) {
      input['comicDocuments'] = [
        ComicDocument.original(
          chapterId: chapterId,
          instruction: instruction.trim(),
          style: input['comicStyle'] as String,
          priorComics: (input['comicPrior'] as List)
              .cast<Map<String, dynamic>>(),
        ).toJson(),
      ];
    }
    return _start(
      branchId: branchId,
      kind: TaskKind.comic,
      input: {
        ...input,
        'comicAction': 'compose',
        'comicInstruction': instruction.trim(),
        'comicCreationId': const Uuid().v4(),
        'connection': connection.raw,
        'promptConnection': connection.raw,
        'imageConnection': ?imageConnection?.raw,
        'nsfwConnection': ?nsfwConnection?.raw,
        if (opening) 'comicCharacterSheets': true,
      },
    );
  }

  /// One reference sheet for a visible character, saved to its lore entry.
  /// Comics are untouched; later pages pick the image up automatically.
  Future<String> drawCharacterSheet({
    required String branchId,
    required String chapterId,
    required String name,
    required ModelConnection connection,
  }) async {
    final entry = (await repository.listLore(
      branchId,
      throughChapterId: chapterId,
      kind: LoreKind.character,
    )).where((e) => e.name == name).firstOrNull;
    if (entry == null) throw FormatException('找不到角色资料：$name');
    final saved = entry.data['referencePrompt'] as String? ?? '';
    final prompt = saved.trim().isEmpty ? entry.content.trim() : saved;
    if (prompt.isEmpty) throw FormatException('$name缺少固定外观描述，请先在资料中补充');
    final illustration = IllustrationService(
      repository: repository,
      runner: runner,
    );
    final reference = VisualReference(
      kind: LoreKind.character,
      name: entry.name,
      prompt: prompt,
      entry: entry,
    );
    await illustration.ensureReference(
      branchId: branchId,
      chapterId: chapterId,
      connection: connection,
      reference: reference,
      defaults: await illustration.savedDefaults(connection),
    );
    return reference.assetId!;
  }

  Future<GenerationTask> suggestDirections({
    required String branchId,
    required String chapterId,
    required ModelConnection connection,
    required String expectedRevisionId,
  }) async {
    final input = await _originalInput(branchId, chapterId, expectedRevisionId);
    return _start(
      branchId: branchId,
      kind: TaskKind.comic,
      input: {
        ...input,
        'comicAction': 'directions',
        'connection': connection.raw,
      },
    );
  }

  Future<GenerationTask> adapt({
    required String branchId,
    required List<String> chapterIds,
    required ModelConnection connection,
    String style = '',
  }) async {
    final story = await repository.getStory(branchId);
    final start = story.chapters.indexWhere(
      (c) => c.id == chapterIds.firstOrNull,
    );
    if (start < 0 ||
        chapterIds.isEmpty ||
        start + chapterIds.length > story.chapters.length ||
        List.generate(
              chapterIds.length,
              (i) => story.chapters[start + i].id,
            ).join(',') !=
            chapterIds.join(',')) {
      throw const FormatException('请选择按阅读顺序排列的连续章节');
    }
    final documents = <Map<String, dynamic>>[], heads = <String, dynamic>{};
    for (var i = start; i < start + chapterIds.length; i++) {
      final chapter = story.chapters[i];
      if (chapter.content.text.trim().isEmpty) {
        throw const FormatException('请先选择有正文的小说章节');
      }
      documents.add(
        ComicDocument.draft(
          chapter: chapter,
          style: style,
          priorSources: [
            for (final prior in story.chapters.take(i))
              {'chapterId': prior.id, 'revisionId': prior.revisionId},
          ],
        ).toJson(),
      );
      heads[chapter.id] = (await repository.getComic(branchId, chapter.id))?.id;
    }
    return _start(
      branchId: branchId,
      kind: TaskKind.comic,
      input: {
        'comicAction': 'adapt',
        'connection': connection.raw,
        'comicDocuments': documents,
        'comicHeads': heads,
        'comicPreviousPanel': ?(await _previousComic(
          branchId,
          chapterIds.first,
        ))?.document.panels.lastOrNull,
        'comicPreceding': [
          for (final c in story.chapters.take(start))
            {
              'chapterId': c.id,
              'revisionId': c.revisionId,
              'text': c.content.text,
            },
        ],
      },
    );
  }

  Future<GenerationTask> check({
    required String branchId,
    required String chapterId,
    required ModelConnection connection,
    String? expectedRevisionId,
  }) async {
    final head = await repository.getComic(branchId, chapterId);
    if (head == null) throw const FormatException('请先生成分镜');
    if (expectedRevisionId != null && head.id != expectedRevisionId) {
      throw const ComicConflict();
    }
    var document = head.document.edit({});
    if (document.isOriginal) {
      final input = await _originalInput(
        branchId,
        chapterId,
        head.id,
        includeCurrent: false,
      );
      document = document.edit({
        'priorComics': input['comicPrior'],
        'context': jsonEncode(input['comicContext']),
      });
    }
    return _start(
      branchId: branchId,
      kind: TaskKind.comic,
      input: {
        'comicAction': 'check',
        'connection': connection.raw,
        'comicDocuments': [document.toJson()],
        'comicHeads': {chapterId: head.id},
      },
    );
  }

  Future<GenerationTask> generateImages({
    required String branchId,
    required String chapterId,
    required ModelConnection connection,
    required ModelConnection promptConnection,
    ModelConnection? nsfwConnection,
    String? panelId,
    bool checkFirst = false,
    String? expectedRevisionId,
  }) async {
    final head = await repository.getComic(branchId, chapterId);
    if (expectedRevisionId != null && head?.id != expectedRevisionId) {
      throw const ComicConflict();
    }
    if (head == null ||
        !checkFirst && !head.document.isOriginal && !head.document.checked) {
      throw const FormatException('请先检查分镜并修正所有问题');
    }
    if (!await repository.comicSourcesCurrent(branchId, head.document)) {
      throw const ComicConflict();
    }
    if (panelId != null &&
        !head.document.imageItems.any((p) => p['id'] == panelId)) {
      throw const FormatException('分镜不存在');
    }
    final document = head.document.asPages();
    if (panelId != null && !head.document.hasPages) {
      panelId =
          document.pages.firstWhere(
                (p) => (p['panelIds'] as List).contains(panelId),
              )['id']
              as String;
    }
    final previous = await _previousComic(
      branchId,
      chapterId,
      original: head.document.isOriginal,
    );
    return _start(
      branchId: branchId,
      kind: TaskKind.comic,
      input: {
        'comicAction': 'images',
        'comicCheckFirst': checkFirst,
        'connection': connection.raw,
        'promptConnection': promptConnection.raw,
        'nsfwConnection': ?nsfwConnection?.raw,
        'comicPreviousPanel': ?previous?.document.imageItems.lastOrNull,
        'comicPreviousChapterId': ?previous?.chapterId,
        'comicPreviousRevisionId': ?previous?.id,
        'comicDocuments': [document.toJson()],
        'comicHeads': {chapterId: head.id},
        'panelId': ?panelId,
      },
    );
  }

  Future<ComicRevision?> _previousComic(
    String branchId,
    String chapterId, {
    bool original = false,
  }) async {
    final chapters = (await repository.getStory(branchId)).chapters;
    final index = chapters.indexWhere((c) => c.id == chapterId);
    if (index <= 0) return null;
    final prior = await repository.getComic(branchId, chapters[index - 1].id);
    // Originals continue from the last drawn page; checks and flags are hints.
    if (original && prior != null && prior.document.isOriginal) {
      return prior.document.imageItems.lastOrNull?['assetId'] == null
          ? null
          : prior;
    }
    if (prior == null ||
        !prior.document.checked ||
        !prior.document.complete ||
        !await repository.comicSourcesCurrent(branchId, prior.document)) {
      return null;
    }
    return prior;
  }
}
