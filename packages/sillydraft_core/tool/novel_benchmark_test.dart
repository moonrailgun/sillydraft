import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'novel_benchmark.dart' as benchmark;

void main() {
  Future<({Directory dir, List<String> args})> completedRun() async {
    final dir = Directory.systemTemp.createTempSync('novel-review-test-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final fixture = File('${dir.path}/input.json')
      ..writeAsStringSync(
        jsonEncode({
          'writer': 'writer',
          'stories': [
            {
              'id': 'test',
              'title': '测试',
              'genre': '',
              'style': '',
              'bible': '',
              'chapters': List.filled(16, '测试目标'),
            },
          ],
        }),
      );
    for (var i = 1; i <= 16; i++) {
      File('${dir.path}/${i.toString().padLeft(2, '0')}.json')
          .writeAsStringSync('{}');
    }
    return (
      dir: dir,
      args: [fixture.path, 'test', dir.path, 'http://127.0.0.1:1/v1'],
    );
  }

  test(
    'reviewer is stored and frozen across resume without inference',
    () async {
      final run = await completedRun();
      await benchmark.main([...run.args, 'reviewer']);
      final config = File('${run.dir.path}/run-config.json').readAsStringSync();
      await benchmark.main([...run.args, 'reviewer']);
      expect(
        File('${run.dir.path}/run-config.json').readAsStringSync(),
        config,
      );
      for (final changed in [
        run.args,
        [...run.args, 'different'],
      ]) {
        await expectLater(benchmark.main(changed), throwsStateError);
      }
      final repo = StoryRepository.open('${run.dir.path}/library.sqlite');
      addTearDown(repo.close);
      expect((await repo.connectionFor('review'))!.model, 'reviewer');
      expect((await repo.connectionFor('writing'))!.model, 'writer');
      expect(await repo.listTasks(), isEmpty);
    },
  );

  test('an unconfigured resumed book cannot acquire a reviewer', () async {
    final run = await completedRun();
    final repo = StoryRepository.open('${run.dir.path}/library.sqlite');
    final novel = await repo.createNovel(title: '测试');
    await repo.createChapter(
      branchId: novel.activeBranchId,
      content: ManuscriptContent.plainText('已有正文。'),
    );
    await repo.close();
    await expectLater(
      benchmark.main([...run.args, 'reviewer']),
      throwsStateError,
    );
    expect(File('${run.dir.path}/run-config.json').existsSync(), isFalse);
    await benchmark.main(run.args);
    final reopened = StoryRepository.open('${run.dir.path}/library.sqlite');
    addTearDown(reopened.close);
    expect(await reopened.connectionFor('review'), isNull);
    expect(
      (await reopened.getStory(novel.activeBranchId))
          .chapters
          .single
          .content
          .text
          .trim(),
      '已有正文。',
    );
  });

  for (final status in [
    TaskStatus.failed,
    TaskStatus.interrupted,
    TaskStatus.running,
  ]) {
    test('resume preserves a $status sidecar without new inference', () async {
      final dir = Directory.systemTemp.createTempSync('novel-benchmark-test-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final fixture = File('${dir.path}/input.json')
        ..writeAsStringSync(
          jsonEncode({
            'writer': 'local-test-only',
            'stories': [
              {
                'id': 'test',
                'title': '测试',
                'genre': '',
                'style': '',
                'bible': '',
                'chapters': List.filled(16, '测试目标'),
              },
            ],
          }),
        );
      final repo = StoryRepository.open('${dir.path}/library.sqlite');
      final novel = await repo.createNovel(title: '测试');
      for (var i = 1; i < 16; i++) {
        File('${dir.path}/${i.toString().padLeft(2, '0')}.json')
            .writeAsStringSync('{}');
        await repo.createChapter(branchId: novel.activeBranchId);
      }
      final chapter = await repo.createChapter(
        branchId: novel.activeBranchId,
        content: ManuscriptContent.plainText('已采纳的正文。'),
      );
      final sidecar = await repo.createTask(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
        kind: TaskKind.sidecar,
        input: {},
      );
      await repo.updateTask(sidecar.id, status: status, error: 'tool limit');
      await repo.close();
      final run = benchmark.main([
        fixture.path,
        'test',
        dir.path,
        'http://127.0.0.1:1/v1',
      ]);
      if (status == TaskStatus.running) {
        await expectLater(run, throwsStateError);
        expect(File('${dir.path}/16.json').existsSync(), isFalse);
      } else {
        await run;
        final result = jsonDecode(
          File('${dir.path}/16.json').readAsStringSync(),
        );
        expect(result['sidecarStatus'], status.name);
        expect(result['sidecarError'], 'tool limit');
        expect(result['sidecarAttemptIds'], [sidecar.id]);
        expect(File('${dir.path}/16.txt').readAsStringSync().trim(), '已采纳的正文。');
      }
      final reopened = StoryRepository.open('${dir.path}/library.sqlite');
      expect(await reopened.listTasks(), hasLength(1));
      await reopened.close();
    });
  }
}
