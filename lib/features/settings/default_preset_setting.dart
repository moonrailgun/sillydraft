import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../resources/writing_profile.dart';

class DefaultPresetSetting extends ConsumerWidget {
  const DefaultPresetSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(settingProvider('writingDefaults')),
    builder: (defaults) => AsyncView(
      value: ref.watch(resourcesProvider),
      builder: (resources) {
        final selected = defaults?['presetId'] as String?;
        final parents = {for (final resource in resources) resource.parentId};
        final names = {
          for (final resource in resources)
            if (resource.kind == ResourceKind.preset &&
                (resource.id == selected ||
                    (!resource.archived && !parents.contains(resource.id))))
              resource.id:
                  '${resource.name}${resource.archived ? ' · 已归档' : ''}',
        };
        return FSelect<String>.rich(
          key: const Key('default-preset-select'),
          label: const Text('默认预设'),
          description: Text(
            names.isEmpty && selected == null
                ? '先到资源库导入预设，再在这里选择。新建小说时会自动使用。'
                : '新建空白小说、从角色卡开书或导入小说时自动使用，不影响已有小说。',
          ),
          forceErrorText: selected != null && !names.containsKey(selected)
              ? '默认预设已失效，请重新选择或清除。'
              : null,
          format: (id) => id.isEmpty ? '不使用默认预设' : names[id] ?? '预设不可用',
          control: FSelectControl<String>.lifted(
            value: selected ?? '',
            onChange: (id) async {
              try {
                await ref.read(repositoryProvider).setSetting(
                  'writingDefaults',
                  {if (id != null && id.isNotEmpty) 'presetId': id},
                );
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
          children: [
            const FSelectItem<String>(title: Text('不使用默认预设'), value: ''),
            for (final entry in names.entries)
              FSelectItem<String>(
                title: Text(
                  entry.value,
                  softWrap: true,
                  overflow: TextOverflow.visible,
                ),
                value: entry.key,
              ),
          ],
        );
      },
    ),
  );
}
