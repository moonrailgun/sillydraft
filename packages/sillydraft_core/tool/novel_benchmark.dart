import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4 ||
      args.length > 5 ||
      (args.length == 5 && args[4].trim().isEmpty)) {
    throw ArgumentError(
      'Usage: fixture.json story-id output-dir base-url [reviewer-model]',
    );
  }
  final fixture = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final story = (fixture['stories'] as List).cast<Map>().singleWhere(
    (s) => s['id'] == args[1],
  );
  final goals = (story['chapters'] as List).cast<String>();
  if (goals.length != 16 || goals.any((g) => g.isEmpty)) {
    throw const FormatException('Expected 16 nonempty chapter goals');
  }
  final output = Directory(args[2])..createSync(recursive: true);
  final snapshot = File('${output.path}/fixture.json');
  final serialized = jsonEncode(fixture);
  if (snapshot.existsSync() && snapshot.readAsStringSync() != serialized) {
    throw StateError('Fixture changed; use a new run directory');
  }
  snapshot.writeAsStringSync(serialized);
  final repo = StoryRepository.open('${output.path}/library.sqlite');
  final connection = ModelConnection(
    id: 'benchmark',
    name: 'Benchmark Magpie',
    baseUrl: args[3],
    model: fixture['writer'] as String,
    contextWindow: 200000,
    maxOutputTokens: 16000,
  );
  final reviewer = args.length == 5
      ? ModelConnection(
          id: 'benchmark-reviewer',
          name: 'Benchmark reviewer',
          baseUrl: args[3],
          model: args[4],
          contextWindow: 200000,
          maxOutputTokens: 16000,
        )
      : null;
  final runner = TaskRunner(
    repository: repo,
    providerFactory: (config) async =>
        OpenAICompatibleProvider(config: config, apiKey: 'magpie'),
  );
  final bible = [
    '书名：${story['title']}\n题材：${story['genre']}',
    '文风：${story['style']}',
    '作者设定：${story['bible']}',
    '以下是未来创作计划，不能当作已发生的事实：',
    for (var i = 0; i < goals.length; i++) '第${i + 1}章：${goals[i]}',
  ].join('\n\n');
  try {
    final novels = await repo.listNovels();
    final configFile = File('${output.path}/run-config.json');
    final config = jsonEncode({
      'story': args[1],
      'writer': connection.raw,
      'reviewer': reviewer?.raw,
    });
    if (configFile.existsSync()) {
      if (configFile.readAsStringSync() != config) {
        throw StateError('Run configuration changed; use a new run directory');
      }
    } else {
      if (reviewer != null && novels.isNotEmpty) {
        throw StateError(
          'Cannot add a reviewer to an existing unconfigured run',
        );
      }
      configFile.writeAsStringSync(config);
    }
    await repo.setSetting('connections', {
      'items': [connection.raw, if (reviewer != null) reviewer.raw],
    });
    await repo.setSetting('modelRoles', {
      'writing': connection.id,
      if (reviewer != null) 'review': reviewer.id,
    });
    final novel = novels.isEmpty
        ? await repo.createNovel(
            title: story['title'] as String,
            genre: story['genre'] as String,
            style: story['style'] as String,
            synopsis: story['bible'] as String,
            pointOfView: '第三人称限知',
          )
        : novels.single;
    for (var i = 0; i < goals.length; i++) {
      final number = (i + 1).toString().padLeft(2, '0');
      final doneFile = File('${output.path}/$number.json');
      if (doneFile.existsSync()) continue;
      final chapters = (await repo.getStory(novel.activeBranchId)).chapters;
      final chapter = i < chapters.length
          ? chapters[i]
          : await repo.createChapter(
              branchId: novel.activeBranchId,
              title: '第${i + 1}章',
            );
      GenerationTask? writing;
      if (chapter.content.text.trim().isEmpty) {
        stdout.writeln('${DateTime.now().toIso8601String()} writing $number');
        final task = await WritingService(repository: repo, runner: runner)
            .generate(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              connection: connection,
              preset: PresetImporter().decode({
                ...defaultWritingPreset().raw,
                'temperature': 0.7,
              }),
              brief:
                  '$bible\n\n本次只写第${i + 1}章：${goals[i]}\n'
                  '目标 ${fixture['chapterCharacters']} 汉字（不含标点），'
                  '写成完整场景，不要用提纲概述替代正文，不提前写后续章。',
              autoAccept: true,
            );
        writing = await runner.wait(task.id);
        if (writing.status != TaskStatus.completed) {
          throw StateError('Writing ${writing.id}: ${writing.error}');
        }
      }
      final saved = await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      );
      if (saved.content.text.trim().isEmpty) {
        throw StateError('Chapter $number was not accepted');
      }
      File('${output.path}/$number.txt').writeAsStringSync(saved.content.text);
      stdout.writeln('${DateTime.now().toIso8601String()} sidecar $number');
      final tasks = await repo.listTasks(branchId: novel.activeBranchId);
      final previousSidecars = tasks.where(
        (t) => t.kind == TaskKind.sidecar && t.chapterId == chapter.id,
      );
      if (previousSidecars.any(
        (t) =>
            t.status != TaskStatus.completed &&
            t.status != TaskStatus.failed &&
            t.status != TaskStatus.interrupted,
      )) {
        throw StateError('Resolve unfinished sidecar before resuming $number');
      }
      final sidecar = previousSidecars.isNotEmpty
          ? await repo.getTask(previousSidecars.first.id)
          : await runner.wait(
              (await SidecarAgent(repository: repo, runner: runner).start(
                branchId: novel.activeBranchId,
                chapterId: chapter.id,
                connection: connection,
                duties: SidecarDuty.values.toSet(),
              )).id,
            );
      // Match awaitSidecar: failed or recovered interrupted runs do not block.
      final result = {
        'chapter': i + 1,
        'chapterId': chapter.id,
        'characters': saved.content.text.runes.length,
        'writingTaskId': writing?.id,
        'writingResult': writing?.result,
        'sidecarTaskId': sidecar.id,
        'sidecarStatus': sidecar.status.name,
        'sidecarError': sidecar.error,
        'sidecarAttemptIds': {
          sidecar.id,
          for (final previous in previousSidecars) previous.id,
        }.toList(),
        'sidecarResult': sidecar.result,
      };
      doneFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(result),
      );
      stdout.writeln(jsonEncode(result));
    }
  } finally {
    await runner.close();
    await repo.close();
  }
}
