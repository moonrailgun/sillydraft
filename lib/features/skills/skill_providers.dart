import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';

/// Every skill (installed first, then built-in) with whether it is switched on.
final skillsProvider = FutureProvider<List<({AgentSkill skill, bool enabled})>>(
  (ref) async {
    ref.watch(repositoryChangesProvider);
    final library = ref.watch(servicesProvider).skills;
    final off = await library.disabled();
    return [
      for (final s in await library.all())
        (skill: s, enabled: !off.contains(s.name)),
    ];
  },
);
