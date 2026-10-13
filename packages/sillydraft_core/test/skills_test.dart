import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

import 'task_runner_test.dart' show ScriptProvider;

const _toolNames = {
  'list_lore',
  'read_lore',
  'propose_lore',
  'list_chapters',
  'read_chapter',
  'propose_chapter',
  'activate_skill',
  'read_skill_file',
};

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile(e.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('SKILL.md parsing', () {
    test('reads the standard fields and body', () {
      final skill = parseSkill('''
---
name: plot-doctor
description: Diagnose plot holes. Use when the plot feels broken.
license: MIT
metadata:
  display-name: 情节医生
  version: "1.0"
---

# Plot doctor
Step one.
''');
      expect(skill.name, 'plot-doctor');
      expect(skill.title, '情节医生');
      expect(skill.license, 'MIT');
      expect(skill.body, '# Plot doctor\nStep one.');
      expect(skill.diagnostics, isEmpty);
      expect(skill.modelInvocable, isTrue);
      expect(
        parseSkill(skill.toSkillMd()).raw,
        skill.raw,
        reason: 'round trip',
      );
    });

    test('is lenient like other clients: colons, odd names, model opt-out', () {
      final skill = parseSkill('''
---
name: Plot_Doctor
description: Use this skill when: the plot breaks
disable-model-invocation: true
---
body''', directory: 'plot');
      expect(skill.description, 'Use this skill when: the plot breaks');
      expect(skill.name, 'plot-doctor');
      expect(skill.modelInvocable, isFalse);
      expect(skill.diagnostics.join(), contains('已改为 plot-doctor'));
      expect(skill.diagnostics.join(), contains('目录名 plot'));
    });

    test('rejects what cannot work: no description, no frontmatter', () {
      expect(
        () => parseSkill('---\nname: a\n---\nbody'),
        throwsFormatException,
      );
      expect(() => parseSkill('# just markdown'), throwsFormatException);
    });
  });

  test('a zip package yields each skill with its text files only', () {
    final skills = skillsFromArchive(
      _zip({
        'pack/one/SKILL.md':
            '---\nname: one\ndescription: First.\n---\nUse references/a.md',
        'pack/one/references/a.md': 'reference text',
        'pack/one/scripts/run.py': 'print(1)',
        'pack/two/SKILL.md': '---\nname: two\ndescription: Second.\n---\nbody',
        '__MACOSX/pack/one/._SKILL.md': 'junk',
      }),
    );
    expect(skills.map((s) => s.name), ['one', 'two']);
    final one = skills.first;
    expect(one.files, {'references/a.md': 'reference text'});
    expect(one.unsupportedFiles, ['scripts/run.py']);
    expect(one.diagnostics.join(), contains('不会被读取或执行'));
    expect(skillContent(one), contains('<file>references/a.md</file>'));
    expect(
      () => skillsFromArchive(_zip({'readme.md': 'x'})),
      throwsFormatException,
    );
  });

  test('built-in skills are valid and only use the assistant\'s tools', () {
    final skills = builtInSkills();
    expect(skills.length, greaterThanOrEqualTo(5));
    for (final s in skills) {
      expect(s.diagnostics, isEmpty, reason: s.name);
      expect(s.builtIn, isTrue);
      expect(s.description.length, lessThanOrEqualTo(1024));
      final used = RegExp(r'\b([a-z]+_[a-z_]+)\b')
          .allMatches(s.body)
          .map((m) => m.group(1)!)
          .where((w) => w.startsWith(RegExp(r'list|read|propose|activate')));
      expect(_toolNames.containsAll(used), isTrue, reason: '${s.name}: $used');
      for (final path in RegExp(
        r'references/[\w.-]+',
      ).allMatches(s.body).map((m) => m.group(0)!)) {
        expect(s.files.containsKey(path), isTrue, reason: '${s.name}: $path');
      }
    }
  });

  test(
    'the library installs, overrides, disables and removes skills',
    () async {
      final repo = StoryRepository.memory();
      addTearDown(repo.close);
      final library = SkillLibrary(repo);
      final builtIn = builtInSkills().first;
      expect(
        (await library.enabled()).map((s) => s.name),
        contains(builtIn.name),
      );

      await library.install([
        parseSkill('---\nname: ${builtIn.name}\ndescription: Mine.\n---\nmine'),
        parseSkill('---\nname: extra\ndescription: Extra.\n---\nx'),
      ]);
      final all = await library.all();
      expect(
        all.where((s) => s.name == builtIn.name).single.description,
        'Mine.',
      );
      expect(all.where((s) => s.name == builtIn.name).single.builtIn, isFalse);

      await library.setEnabled('extra', false);
      expect(
        (await library.enabled()).map((s) => s.name),
        isNot(contains('extra')),
      );
      await library.remove(builtIn.name);
      expect(
        (await library.all())
            .where((s) => s.name == builtIn.name)
            .single
            .builtIn,
        isTrue,
        reason: 'removing an override brings the built-in back',
      );
    },
  );

  test('the assistant discovers, activates, keeps and reads skills', () async {
    final repo = StoryRepository.memory();
    addTearDown(repo.close);
    final novel = await repo.createNovel(title: '雾港');
    final conversation = await repo.createConversation(
      branchId: novel.activeBranchId,
    );
    final skill = parseSkill(
      '---\nname: plot-doctor\ndescription: 诊断情节漏洞。\n---\n先列出所有冲突。',
      files: {'references/holes.md': '常见漏洞清单'},
    );
    final hidden = parseSkill(
      '---\nname: manual-only\ndescription: 只能手动启用。\ndisable-model-invocation: true\n---\n手动技能正文',
    );
    final requests = <ProviderRequest>[];
    var script = <List<ProviderEvent>>[];
    final runner = TaskRunner(
      repository: repo,
      providerFactory: (c) async => ScriptProvider(c, (request, _) async* {
        requests.add(request);
        for (final e in script.removeAt(0)) {
          yield e;
        }
      }),
    );
    addTearDown(runner.close);
    final agent = EditorAgent(repository: repo, runner: runner);
    final connection = ModelConnection(
      id: 't',
      name: 't',
      baseUrl: 'http://localhost:1',
      model: 't',
    );
    Future<GenerationTask> send(String text) async {
      final task = await agent.send(
        conversationId: conversation,
        connection: connection,
        message: text,
        skills: [skill, hidden],
      );
      await runner.wait(task.id);
      return repo.getTask(task.id);
    }

    // Turn 1: the model sees only the catalog, activates, then reads a file.
    script = [
      [
        ToolCallReady('a', 'activate_skill', {'name': 'plot-doctor'}),
        const GenerationFinished('tool_calls'),
      ],
      [
        ToolCallReady('b', 'read_skill_file', {
          'name': 'plot-doctor',
          'path': 'references/holes.md',
        }),
        const GenerationFinished('tool_calls'),
      ],
      [const TextDelta('诊断完成'), const GenerationFinished('stop')],
    ];
    expect((await send('看看情节')).status, TaskStatus.completed);
    final system = requests.first.messages.first['content'] as String;
    expect(system, contains('<name>plot-doctor</name>'));
    expect(system, isNot(contains('manual-only')), reason: 'opted out');
    expect(system, isNot(contains('先列出所有冲突')), reason: 'body not yet loaded');
    final toolNames = requests.first.tools
        .map((t) => (t['function'] as Map)['name'])
        .toList();
    expect(toolNames, containsAll(['activate_skill', 'read_skill_file']));
    final enumNames =
        ((requests.first.tools.firstWhere(
                  (t) => (t['function'] as Map)['name'] == 'activate_skill',
                )['function']
                as Map)['parameters']
            as Map)['properties']['name']['enum'];
    expect(enumNames, ['plot-doctor']);
    expect(requests[1].messages.last['content'], contains('先列出所有冲突'));
    expect(requests[2].messages.last['content'], contains('常见漏洞清单'));

    // Turn 2: the skill is still in force, sent once, and not reloaded.
    requests.clear();
    script = [
      [
        ToolCallReady('c', 'activate_skill', {'name': 'plot-doctor'}),
        const GenerationFinished('tool_calls'),
      ],
      [const TextDelta('继续'), const GenerationFinished('stop')],
    ];
    await send('继续');
    final carried = requests.first.messages
        .where(
          (m) =>
              '${m['content']}'.contains('<skill_content name="plot-doctor">'),
        )
        .length;
    expect(carried, 1);
    expect(requests[1].messages.last['content'], contains('已在本会话中加载'));

    // Turn 3: the author loads a model-hidden skill explicitly.
    requests.clear();
    script = [
      [const TextDelta('好'), const GenerationFinished('stop')],
    ];
    await send('/manual-only 帮我检查');
    final contents = requests.first.messages
        .map((m) => '${m['content']}')
        .toList();
    expect(contents.where((c) => c.contains('手动技能正文')).length, 1);
    expect(contents.last, '帮我检查', reason: 'the command is not sent as text');
  });
}
