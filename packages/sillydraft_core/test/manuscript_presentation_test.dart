import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test('display regex uses frozen task context without changing document or variables', () {
    final content = ManuscriptContent.fromDelta([
      {
        'insert': '雾',
        'attributes': {'bold': true},
      },
      {'insert': '归来\n后续正文\n'},
    ]);
    final task = GenerationTask(
      id: 'task',
      branchId: 'branch',
      kind: TaskKind.writing,
      status: TaskStatus.completed,
      partialText: '雾归来',
      reasoning: '',
      error: '',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'macroValues': {'char': '阿雾'},
        'variableResult': {
          'local': {'seen': 'old'},
          'global': <String, dynamic>{},
        },
        'outputRegex': [
          {
            'findRegex': '/雾/g',
            'replaceString': '{{char}}的薄雾{{setvar::seen::new}}',
            'placement': [2],
            'markdownOnly': true,
          },
          {
            'findRegex': '/正文/g',
            'replaceString': '不能出现在显示阶段',
            'placement': [2],
            'promptOnly': true,
          },
        ],
      },
    );
    final original = content.encoded;
    final shown = ManuscriptPresentation.fromTask(content, task);
    expect(shown.content.text, '阿雾的薄雾归来\n后续正文\n');
    expect(shown.content.delta.first['attributes'], {'bold': true});
    expect(
      shown.sourceOffset(shown.content.text.indexOf('后续')),
      content.text.indexOf('后续'),
    );
    expect(
      shown.displayOffset(content.text.indexOf('后续')),
      shown.content.text.indexOf('后续'),
    );
    expect(content.encoded, original);
    expect(
      ((task.input['variableResult'] as Map)['local'] as Map)['seen'],
      'old',
    );
    expect(
      ManuscriptPresentation.fromTask(content, task, rules: []).content,
      content,
      reason: 'an empty current rule list must not restore frozen rules',
    );
  });

  test('current branch rules refresh generated and manual revisions without rewriting snapshots', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '显示规则');
    final branch = novel.activeBranchId;
    final chapter = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('暗号'),
    );
    final rule = <String, dynamic>{
      'findRegex': '/暗号/g',
      'replaceString': '{{user}}的来信',
      'placement': [2],
      'markdownOnly': true,
      'disabled': true,
    };
    await repo.storeResource(
      id: 'preset',
      kind: ResourceKind.preset,
      name: '显示预设',
      filename: 'display.json',
      sourceHash: 'fixture',
      encryptedSource: [],
      data: {
        'extensions': {
          'regex_scripts': [rule],
        },
      },
    );
    await repo.setSetting('writing/$branch', {'presetId': 'preset'});
    final task = await repo.createTask(
      branchId: branch,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      kind: TaskKind.writing,
      input: {
        'clock': '2026-01-01T00:00:00Z',
        'seed': 1,
        'macroValues': {'user': '阿雾'},
        'outputRegex': [rule],
      },
    );
    final proposal = await repo.createProposal(
      branchId: branch,
      chapterId: chapter.id,
      baseRevisionId: chapter.revisionId,
      taskId: task.id,
      content: ManuscriptContent.plainText('暗号到了。'),
    );
    final accepted = await repo.acceptProposal(proposal.id);
    final manual = await repo.createChapter(
      branchId: branch,
      content: ManuscriptContent.plainText('暗号'),
    );
    final fork = await repo.forkBranch(branchId: branch, name: '支线');
    await repo.setSetting('writing/${fork.id}', {
      'presetId': 'preset',
      'presetOverrides': {
        'preset': {
          'extensions': {
            'regex_scripts': [
              {...rule, 'disabled': false},
            ],
          },
        },
      },
    });
    expect(
      (await repo.presentRevision(accepted.id, branchId: fork.id)).content.text,
      '阿雾的来信到了。\n',
      reason: 'live rules use the task macro values',
    );
    expect(
      (await repo.presentRevision(accepted.id, branchId: branch)).content.text,
      accepted.content.text,
      reason: 'another branch retains its own disabled setting',
    );
    expect(
      (await repo.presentRevision(
        manual.revisionId,
        branchId: fork.id,
      )).content.text,
      '主角的来信\n',
      reason:
          'manual revisions also use the viewing branch, not originBranchId',
    );
    final edited = await repo.saveChapter(
      branchId: fork.id,
      chapterId: chapter.id,
      expectedRevisionId: accepted.id,
      content: ManuscriptContent.plainText('暗号归来。'),
    );
    expect(
      (await repo.presentRevision(
        edited.revisionId,
        branchId: fork.id,
      )).content.text,
      '阿雾的来信归来。\n',
      reason: 'manual edits inherit the task macro context',
    );
    expect((await repo.presentRevision(accepted.id)).content, accepted.content);
    expect((await repo.presentProposal(proposal.id)).content, proposal.content);
    expect((await repo.getTask(task.id)).input, task.input);
    expect((await repo.getRevision(accepted.id)).content, accepted.content);
  });
}
