part of 'story_repository.dart';

extension PersonaOperations on StoryRepository {
  /// Every persona, the built-in “我” first even before it is first saved.
  Future<List<Persona>> listPersonas() async {
    final stored = [
      for (final item
          in (await getSetting('personas'))?['items'] as List? ?? const [])
        Persona.fromJson(item as Map<String, dynamic>),
    ];
    return [
      stored.where((p) => p.id == Persona.meId).firstOrNull ?? Persona.me,
      ...stored.where((p) => p.id != Persona.meId),
    ];
  }

  /// The persona a writing profile binds: “我” when it binds none, or one
  /// that no longer exists.
  Future<Persona> personaFor(Map<String, dynamic> profile) async {
    final all = await listPersonas();
    return all.where((p) => p.id == profile['personaId']).firstOrNull ??
        all.first;
  }

  /// Adds or replaces [persona]; a new one (empty id) gets its id here.
  Future<Persona> savePersona(Persona persona) => _write(() async {
    if (persona.name.trim().isEmpty) {
      throw const FormatException('请填写人设名字');
    }
    if (persona.images.length > Persona.maxImages) {
      throw const FormatException('最多 8 张参考图');
    }
    final saved = persona.id.isEmpty ? persona.copyWith(id: _id()) : persona;
    final all = await listPersonas();
    final index = all.indexWhere((p) => p.id == saved.id);
    if (index < 0) {
      all.add(saved);
    } else {
      all[index] = saved;
    }
    await _storePersonas(all);
    return saved;
  });

  /// Refused for “我” and for a persona any novel still binds.
  Future<void> deletePersona(String id) => _write(() async {
    if (id == Persona.meId) throw const FormatException('内置人设“我”不能删除');
    final novels = {
      for (final row in await _rows(
        "SELECT s.value_json, b.novel_id FROM app_settings s JOIN branches b ON s.key = 'writing/' || b.id",
      ))
        if ((jsonDecode(row['value_json'] as String) as Map)['personaId'] == id)
          row['novel_id'] as String,
    };
    if (novels.isNotEmpty) {
      throw FormatException('人设被 ${novels.length} 部作品使用，请先在作品中改用其他人设');
    }
    await _storePersonas([
      for (final p in await listPersonas())
        if (p.id != id) p,
    ]);
  });

  /// Binds writing profiles that still carry the free-text `userName` /
  /// `persona` fields, or a `personaSnapshot` from another installation, to
  /// a persona, and drops those fields. Safe to repeat; runs at startup and
  /// after a project is restored.
  Future<void> migrateLegacyPersonas() => _write(() async {
    final rows = [
      for (final row in await _rows(
        "SELECT key,value_json FROM app_settings WHERE key LIKE 'writing/%'",
      ))
        if (const ['userName', 'persona', 'personaSnapshot'].any(
          (key) =>
              (jsonDecode(row['value_json'] as String) as Map).containsKey(key),
        ))
          row,
    ];
    if (rows.isEmpty) return;
    // Rewriting profiles changes a novel's export fingerprint. A novel that
    // was in sync stays in sync; one with local edits keeps its old state.
    final synced = <String, Map<String, dynamic>>{};
    for (final row in await _rows(
      "SELECT DISTINCT b.novel_id FROM branches b JOIN app_settings s ON s.key = 'writing/' || b.id WHERE s.key IN (${List.filled(rows.length, '?').join(',')})",
      [for (final row in rows) row['key']],
    )) {
      final id = row['novel_id'] as String,
          state = await getSetting('syncState/$id');
      if (state != null &&
          state['localFingerprint'] == (await exportProject(id)).fingerprint) {
        synced[id] = state;
      }
    }
    final all = await listPersonas();
    var created = false;
    for (final row in rows) {
      final value =
          jsonDecode(row['value_json'] as String) as Map<String, dynamic>;
      final snapshot = value.remove('personaSnapshot'),
          userName = value.remove('userName'),
          text = value.remove('persona');
      if (snapshot == null && userName == null && text == null) continue;
      if (value['personaId'] == null) {
        final source = snapshot is Map ? snapshot : const <String, Object?>{};
        String field(String key) =>
            source[key] is String ? source[key] as String : '';
        final name =
                (snapshot == null ? userName as String? ?? '' : field('name'))
                    .trim(),
            description = snapshot == null
                ? text as String? ?? ''
                : field('description');
        final wanted = Persona(
          id: '',
          name: name.isEmpty ? Persona.me.name : name,
          description: description,
          appearance: field('appearance'),
          outfit: field('outfit'),
        );
        // The old default, “主角” with no description, becomes “我”.
        final persona =
            snapshot == null &&
                (name.isEmpty || name == '主角') &&
                description.trim().isEmpty
            ? all.first
            : all
                      .where(
                        (p) =>
                            jsonEncode(p.snapshot) ==
                            jsonEncode(wanted.snapshot),
                      )
                      .firstOrNull ??
                  wanted.copyWith(id: _id());
        if (!all.contains(persona)) {
          all.add(persona);
          created = true;
        }
        value['personaId'] = persona.id;
      }
      await setSetting(row['key'] as String, value);
    }
    if (created) await _storePersonas(all);
    for (final MapEntry(:key, :value) in synced.entries) {
      await setSetting('syncState/$key', {
        ...value,
        'localFingerprint': (await exportProject(key)).fingerprint,
      });
    }
  });

  Future<void> _storePersonas(List<Persona> all) => setSetting('personas', {
    'items': [for (final p in all) p.toJson()],
  });
}
