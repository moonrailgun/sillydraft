import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import 'persona_list_screen.dart';

final personasProvider = FutureProvider<List<Persona>>((ref) {
  ref.watch(repositoryChangesProvider);
  return ref.watch(repositoryProvider).listPersonas();
});

/// Chooses the persona `{{user}}` and `{{persona}}` stand for.
class PersonaPicker extends ConsumerWidget {
  const PersonaPicker({super.key, required this.value, required this.onChange});

  /// The bound persona id; none, or one that is gone, shows “我”.
  final String? value;
  final ValueChanged<Persona> onChange;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncView(
    value: ref.watch(personasProvider),
    builder: (personas) {
      final selected =
          personas.where((p) => p.id == value).firstOrNull ?? personas.first;
      final names = {for (final p in personas) p.id: p.name};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FSelect<String>.rich(
            key: ValueKey('persona:${selected.id}'),
            label: const Text('{{user}} 人设'),
            format: (id) => names[id] ?? Persona.me.name,
            control: FSelectControl<String>.lifted(
              value: selected.id,
              onChange: (id) {
                final picked = personas.where((p) => p.id == id).firstOrNull;
                if (picked != null) onChange(picked);
              },
            ),
            children: [
              for (final p in personas)
                FSelectItem<String>(title: Text(p.name), value: p.id),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FButton(
              variant: FButtonVariant.ghost,
              mainAxisSize: MainAxisSize.min,
              onPress: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const PersonaListScreen(),
                ),
              ),
              child: const Text('管理人设'),
            ),
          ),
        ],
      );
    },
  );
}
