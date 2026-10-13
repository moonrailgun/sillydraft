import 'package:flutter/widgets.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/widgets.dart';

/// A model choice keeps the connection id intact so all models share its key.
class ConnectionModelSelect extends StatelessWidget {
  const ConnectionModelSelect({
    super.key,
    required this.label,
    required this.connections,
    required this.value,
    required this.onChange,
    this.enabled = true,
  });
  final String label;
  final List<ModelConnection> connections;
  final ModelConnection? value;
  final ValueChanged<ModelConnection> onChange;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final choices = {
      for (final c in connections)
        for (final model in c.models) (c.id, model): c.withModel(model),
    };
    final selected = value == null ? null : (value!.id, value!.model);
    return FSelect<(String, String)>.rich(
      label: Text(label),
      enabled: enabled,
      control: FSelectControl.lifted(
        value: choices.containsKey(selected) ? selected : null,
        onChange: (key) {
          if (key != null) onChange(choices[key]!);
        },
      ),
      format: (key) => '${choices[key]!.name} · ${key.$2}',
      children: [
        for (final entry in choices.entries)
          FSelectItem(
            value: entry.key,
            title: Text(
              '${entry.value.name} · ${entry.key.$2}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
