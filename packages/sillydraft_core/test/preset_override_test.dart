import 'dart:convert';
import 'dart:typed_data';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'branch customizations survive forks and copied project backups',
    () async {
      final repo = StoryRepository.memory();
      final restored = StoryRepository.memory();
      addTearDown(repo.close);
      addTearDown(restored.close);
      final library = ResourceLibrary(
        repository: repo,
        keyProvider: () async => List.filled(32, 1),
      );
      final resource = await library.import(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'name': '原件',
              'temperature': 1,
              'prompts': <dynamic>[],
            }),
          ),
        ),
        filename: 'preset.json',
        kind: ResourceKind.preset,
      );
      final novel = await repo.createNovel(title: '分支预设');
      final override = {
        ...resource.data,
        'temperature': 0.4,
        'extensions': {
          'unknown': {'resourceId': resource.id},
          'regex_scripts': [
            {
              'findRegex': '雾',
              'replaceString': '雨',
              'placement': [2],
            },
          ],
        },
      };
      final setting = {
        'presetId': resource.id,
        'presetOverrides': {resource.id: override},
      };
      await repo.setSetting('writing/${novel.activeBranchId}', setting);
      expect(
        (await repo.displayContext(novel.activeBranchId))
            .rules
            .single['replaceString'],
        '雨',
      );
      final fork = await repo.forkBranch(
        branchId: novel.activeBranchId,
        name: '支线',
      );
      expect(await repo.getSetting('writing/${fork.id}'), setting);

      // No active preset: inactive customizations must still pull in their originals.
      await repo.setSetting('writing/${novel.activeBranchId}', {
        'presetOverrides': {resource.id: override},
      });
      await repo.removeSetting('writing/${fork.id}');
      expect((await repo.displayContext(novel.activeBranchId)).rules, isEmpty);
      final snapshot = await repo.exportProject(novel.id);
      expect(snapshot.tables['library_resources'], hasLength(1));
      final copied = snapshot.copy();
      final copiedId = copied.ids[resource.id]!;
      await restored.restoreProject(
        copied.snapshot,
        encryptedSources: {
          copiedId: await library.protectOriginal(
            copiedId,
            await library.original(resource.id),
          ),
        },
      );
      final saved = (await restored.getSetting(
        'writing/${copied.ids[novel.activeBranchId]}',
      ))!;
      expect(saved['presetOverrides'], {
        copiedId: override,
      }, reason: 'remap only the resource key, preserving all preset contents');

      for (final invalid in [
        <dynamic>[],
        {'missing-resource': override},
        {resource.id: 'not a preset'},
      ]) {
        final raw = snapshot.toJson();
        final settings = (raw['tables'] as Map)['app_settings'] as List;
        (settings.single as Map)['value_json'] = jsonEncode({
          'presetOverrides': invalid,
        });
        await expectLater(
          restored.restoreProject(
            ProjectSnapshot.fromJson(raw),
            encryptedSources: {},
          ),
          throwsFormatException,
        );
      }
    },
  );
}
