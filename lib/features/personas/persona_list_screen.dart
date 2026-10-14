import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';
import 'persona_editor_screen.dart';
import 'persona_picker.dart';

/// Every persona, “我” first, with a way to add one.
class PersonaListScreen extends ConsumerWidget {
  const PersonaListScreen({super.key});

  void _open(BuildContext context, String? id) => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => PersonaEditorScreen(personaId: id)),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) => PageScaffold(
    title: '人设',
    floatingActionButton: FloatingAction(
      icon: FLucideIcons.userPlus,
      label: '新建人设',
      onPress: () => _open(context, null),
    ),
    body: AsyncView(
      value: ref.watch(personasProvider),
      builder: (personas) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 110),
        itemCount: personas.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final persona = personas[i];
          final summary = persona.prompt.split('\n').first;
          return FTile(
            prefix: const Icon(FLucideIcons.user),
            title: Text(persona.name),
            subtitle: Text(
              summary.isEmpty
                  ? persona.id == Persona.meId
                        ? '内置 · 尚未填写'
                        : '尚未填写'
                  : summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            suffix: const Icon(FLucideIcons.chevronRight),
            onPress: () => _open(context, persona.id),
          );
        },
      ),
    ),
  );
}
