import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../model/comic.dart';
import '../model/task.dart';
import '../providers/provider.dart';
import '../storage/story_repository.dart';
import '../tasks/task_runner.dart';

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

  /// Freeze only completed comics up to the target; prose is never story input.
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
      final comic = await repository.getComic(branchId, c.id);
      if (comic != null) {
        if (!comic.document.checked || !comic.document.complete) {
          throw const FormatException('请先完成已有漫画页并处理待复核画面');
        }
        if (!await repository.comicSourcesCurrent(branchId, comic.document)) {
          throw const ComicConflict();
        }
        context.add({
          'chapterId': c.id,
          'revisionId': comic.id,
          'panels': comic.document.panels,
          'pages': comic.document.pages,
          'continuity': comic.document.toJson()['continuity'],
        });
        previous = comic.document.imageItems.lastOrNull;
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
  }) async {
    if (instruction.trim().isEmpty) throw const FormatException('请输入开场或下一页剧情');
    final input = await _originalInput(branchId, chapterId, expectedRevisionId);
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
      },
    );
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
    if (head == null || !checkFirst && !head.document.checked) {
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
    final previous = await _previousComic(branchId, chapterId);
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
    String chapterId,
  ) async {
    final chapters = (await repository.getStory(branchId)).chapters;
    final index = chapters.indexWhere((c) => c.id == chapterId);
    if (index <= 0) return null;
    final prior = await repository.getComic(branchId, chapters[index - 1].id);
    if (prior == null ||
        !prior.document.checked ||
        !prior.document.complete ||
        !await repository.comicSourcesCurrent(branchId, prior.document)) {
      return null;
    }
    return prior;
  }
}
