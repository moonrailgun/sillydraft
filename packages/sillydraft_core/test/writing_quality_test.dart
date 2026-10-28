import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

void main() {
  for (final textCompletion in [false, true]) {
    test(
      'quality requests preserve the ${textCompletion ? 'text' : 'chat'} HTTP endpoint',
      () async {
        final repo = StoryRepository.memory();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final paths = <String>[];
        final bodies = <Map<String, dynamic>>[];
        final endpoint = textCompletion
            ? '/v1/completions'
            : '/v1/chat/completions';
        final outputs = [
          '他很害怕。他很害怕。',
          jsonEncode({
            'issues': [
              {'quote': '他很害怕。他很害怕。', 'reason': '重复解释'},
            ],
          }),
          jsonEncode({
            'edits': [
              {'before': '他很害怕。他很害怕。', 'after': '他握紧了门把。'},
            ],
          }),
          '{"issues":[]}',
        ];
        server.listen((request) async {
          paths.add(request.uri.path);
          bodies.add(
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>,
          );
          if (request.uri.path != endpoint) {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'choices': [
                  {
                    if (textCompletion)
                      'text': outputs[paths.length - 1]
                    else
                      'message': {
                        'role': 'assistant',
                        'content': outputs[paths.length - 1],
                      },
                    'finish_reason': 'stop',
                  },
                ],
              }),
            );
          }
          await request.response.close();
        });
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async =>
              OpenAICompatibleProvider(config: c, apiKey: ''),
        );
        addTearDown(() async {
          await runner.close();
          await server.close(force: true);
          await repo.close();
        });
        final novel = await repo.createNovel(title: '接口回归');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
        );
        final task = await WritingService(repository: repo, runner: runner)
            .generate(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              connection: ModelConnection(
                id: 'local',
                name: 'Local',
                baseUrl: 'http://127.0.0.1:${server.port}/v1',
                model: 'test',
              ),
              preset: textCompletion
                  ? PresetImporter().decode({
                      'temp': 0.8,
                    }, kindHint: PresetKind.textCompletion)
                  : null,
              brief: '继续写',
              autoAccept: true,
            );
        final done = await runner.wait(task.id);
        expect(done.status, TaskStatus.completed);
        expect((done.result['quality'] as Map)['status'], 'revised');
        expect(paths, List.filled(4, endpoint));
        for (final body in bodies) {
          expect(body, contains(textCompletion ? 'prompt' : 'messages'));
          expect(body, isNot(contains(textCompletion ? 'messages' : 'prompt')));
        }
        final saved = await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        );
        expect(saved.content.text.trim(), '他握紧了门把。');
      },
    );
  }

  const quote = '他很害怕。他很害怕。';
  final prefix = '${'街上的灯次第熄灭。' * 70}\n';
  const suffix = '\n她仍然选择留在这里，等他回来。';
  final draft = '$prefix$quote$suffix';
  for (final scenario in [
    (
      name: 'whole draft replacement',
      quote: quote,
      before: draft,
      after: '结束了。',
      accepted: false,
      calls: 3,
    ),
    (
      name: 'extra context outside the quote',
      quote: quote,
      before: '$quote$suffix',
      after: '结束了。',
      accepted: false,
      calls: 3,
    ),
    (
      name: 'whole draft quoted as an issue',
      quote: draft,
      before: draft,
      after: '结束了。',
      accepted: false,
      calls: 2,
    ),
    (
      name: 'oversized replacement',
      quote: quote,
      before: quote,
      after: '雨' * 401,
      accepted: false,
      calls: 3,
    ),
    (
      name: 'quote just above the limit',
      quote: '雨' * 201,
      before: '雨' * 201,
      after: '天晴了。',
      accepted: false,
      calls: 2,
    ),
    (
      name: 'local replacement at both limits',
      quote: '雨' * 200,
      before: '雨' * 200,
      after: '晴' * 400,
      accepted: true,
      calls: 4,
    ),
  ]) {
    test('quality bounds ${scenario.name}', () async {
      final repo = StoryRepository.memory();
      final novel = await repo.createNovel(title: '返修范围');
      final chapter = await repo.createChapter(branchId: novel.activeBranchId);
      final original = scenario.quote == draft
          ? draft
          : '$prefix${scenario.quote}$suffix';
      var calls = 0;
      final runner = TaskRunner(
        repository: repo,
        providerFactory: (c) async => ScriptProvider(c, (_, _) async* {
          yield TextDelta(switch (calls++) {
            0 => original,
            1 => jsonEncode({
              'issues': [
                {'quote': scenario.quote, 'reason': '重复解释'},
              ],
            }),
            2 => jsonEncode({
              'edits': [
                {'before': scenario.before, 'after': scenario.after},
              ],
            }),
            _ => '{"issues":[]}',
          });
          yield const GenerationFinished('stop');
        }),
      );
      addTearDown(() async {
        await runner.close();
        await repo.close();
      });
      final task = await WritingService(repository: repo, runner: runner)
          .generate(
            branchId: novel.activeBranchId,
            chapterId: chapter.id,
            connection: ModelConnection(
              id: 'test',
              name: 'Test',
              baseUrl: 'http://localhost:1234/v1',
              model: 'test',
            ),
            brief: '继续写',
            autoAccept: true,
          );
      final done = await runner.wait(task.id);
      final saved = await repo.getChapter(
        branchId: novel.activeBranchId,
        chapterId: chapter.id,
      );
      expect(done.status, TaskStatus.completed);
      expect(
        saved.content.text.trim(),
        scenario.accepted ? '$prefix${scenario.after}$suffix' : original,
      );
      expect(
        (done.result['quality'] as Map)['status'],
        scenario.accepted ? 'revised' : 'unavailable',
      );
      expect(calls, scenario.calls);
    });
  }

  for (final scenario in [
    'pass',
    'repair',
    'reject',
    'invalid',
    'error',
    'cancel',
    'conflict',
    'append',
    'range',
    'markup',
  ]) {
    test(
      'automatic quality $scenario preserves the draft until verified',
      () async {
        final repo = StoryRepository.memory();
        final novel = await repo.createNovel(title: '质量检查');
        final chapter = await repo.createChapter(
          branchId: novel.activeBranchId,
          content: ManuscriptContent.plainText('原文'),
        );
        final connection = ModelConnection(
          id: 'test',
          name: 'Test',
          baseUrl: 'http://localhost:1234/v1',
          model: 'test',
        );
        var calls = 0;
        final requests = <ProviderRequest>[];
        final runner = TaskRunner(
          repository: repo,
          providerFactory: (c) async => ScriptProvider(c, (
            request,
            cancel,
          ) async* {
            requests.add(request);
            final current = await repo.getChapter(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
            );
            if (scenario != 'conflict' || calls < 2) {
              expect(current.revisionId, chapter.revisionId);
            }
            final turn = calls++;
            if (turn == 0) {
              yield TextDelta(
                scenario == 'markup' ? '<div>保留页面</div>' : '他很害怕。他很害怕。',
              );
            } else if (scenario == 'cancel') {
              cancel.cancel();
              cancel.check();
            } else if (scenario == 'error') {
              throw const ProviderException('network', '模拟审读失败');
            } else if (turn == 2) {
              yield TextDelta(
                jsonEncode({
                  'edits': [
                    {
                      'before': scenario == 'invalid' ? '不存在的原句' : '他很害怕。他很害怕。',
                      'after': '他握紧了门把。',
                    },
                  ],
                }),
              );
            } else {
              if (scenario == 'conflict') {
                await repo.saveChapter(
                  branchId: novel.activeBranchId,
                  chapterId: chapter.id,
                  expectedRevisionId: chapter.revisionId,
                  content: ManuscriptContent.plainText('手动修改'),
                );
              }
              yield TextDelta(
                jsonEncode({
                  'issues': [
                    if (!['pass', 'conflict'].contains(scenario) &&
                        (turn == 1 || scenario == 'reject'))
                      {
                        'quote': turn == 1 ? '他很害怕。他很害怕。' : '他握紧了门把。',
                        'reason': '重复解释，没有推进动作',
                      },
                  ],
                }),
              );
            }
            yield const GenerationFinished('stop');
          }),
        );
        addTearDown(() async {
          await runner.close();
          await repo.close();
        });
        final task = await WritingService(repository: repo, runner: runner)
            .generate(
              branchId: novel.activeBranchId,
              chapterId: chapter.id,
              connection: connection,
              brief: '保持克制，不改变人物关系',
              autoAccept: true,
              append: scenario == 'append',
              rangeStart: scenario == 'range' ? 0 : null,
              rangeEnd: scenario == 'range' ? 1 : null,
            );
        final done = await runner.wait(task.id);
        expect(
          done.status,
          scenario == 'cancel' ? TaskStatus.cancelled : TaskStatus.completed,
        );
        final saved = await repo.getChapter(
          branchId: novel.activeBranchId,
          chapterId: chapter.id,
        );
        expect(saved.content.text.trim(), switch (scenario) {
          'repair' => '他握紧了门把。',
          'append' => '原文\n\n他握紧了门把。',
          'range' => '他握紧了门把。文',
          'cancel' => '原文',
          'conflict' => '手动修改',
          'markup' => '<div>保留页面</div>',
          _ => '他很害怕。他很害怕。',
        });
        expect(
          calls,
          scenario == 'markup'
              ? 1
              : ['pass', 'error', 'cancel', 'conflict'].contains(scenario)
              ? 2
              : scenario == 'invalid'
              ? 3
              : 4,
        );
        expect((done.result['quality'] as Map)['status'], switch (scenario) {
          'pass' || 'conflict' => 'passed',
          'cancel' => 'reviewing',
          'markup' => 'skipped',
          'repair' || 'append' || 'range' => 'revised',
          'reject' => 'kept_original',
          _ => 'unavailable',
        });
        expect(
          requests.map((r) => r.executionId).whereType<String>().toSet().length,
          calls - 1,
        );
      },
    );
  }
}
