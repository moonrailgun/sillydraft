import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../editor/workspace_screen.dart';

class CardStartScreen extends ConsumerStatefulWidget {
  const CardStartScreen({super.key, required this.resourceId});
  final String resourceId;
  @override
  ConsumerState<CardStartScreen> createState() => _CardStartState();
}

class _CardStartState extends ConsumerState<CardStartScreen> {
  final _title = TextEditingController(),
      _user = TextEditingController(text: '主角'),
      _persona = TextEditingController(),
      _opening = TextEditingController();
  CharacterCard? _card;
  int _greeting = 0;
  String _pov = '第三人称';
  bool _edited = false, _busy = false;
  Object? _error;
  DateTime _openingClock = DateTime.now().toUtc();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final card = await ref
          .read(servicesProvider)
          .library
          .character(widget.resourceId);
      if (!mounted) return;
      _title.text = '${card.name}的故事';
      setState(() => _card = card);
      _refreshOpening();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _refreshOpening() {
    final card = _card;
    if (card == null) return;
    _openingClock = DateTime.now().toUtc();
    final macros = MacroEngine(
      values: {
        'char': card.name,
        'user': _user.text.trim(),
        'description': card.description,
        'personality': card.personality,
        'scenario': card.scenario,
        'persona': _persona.text,
      },
      clock: _openingClock,
      seed: 0,
    );
    _opening.text = macros.render(card.greetings[_greeting]);
    setState(() {
      _edited = false;
      _error =
          macros.diagnostics.any((d) => d.severity == DiagnosticSeverity.error)
          ? FormatException(macros.diagnostics.map((d) => d.message).join('\n'))
          : null;
    });
  }

  @override
  void dispose() {
    for (final c in [_title, _user, _persona, _opening]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final novel = await ref
          .read(repositoryProvider)
          .createNovelFromCard(
            resourceId: widget.resourceId,
            title: _title.text,
            userName: _user.text.trim(),
            persona: _persona.text,
            pointOfView: _pov,
            greetingIndex: _greeting,
            openingOverride: _edited ? _opening.text : null,
            openingClock: _openingClock,
          );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => NovelWorkspace(novelId: novel.id),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('从角色卡开始故事')),
    body: _card == null
        ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : ErrorPane(message: _error.toString(), retry: _load))
        : SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  '以 ${_card!.name} 为起点',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                const Text('选中的开场成为第一幕，人物和世界设定存入旁路资料。其他备用开场仍保留在角色卡里。'),
                const SizedBox(height: 24),
                TextField(
                  controller: _title,
                  decoration: const InputDecoration(labelText: '作品名称'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _user,
                  onChanged: (_) => _refreshOpening(),
                  decoration: const InputDecoration(
                    labelText: '{{user}} 对应的主角名字',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _persona,
                  minLines: 2,
                  maxLines: 4,
                  onChanged: (_) => _refreshOpening(),
                  decoration: const InputDecoration(
                    labelText: '主角身份 / Persona',
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _pov,
                  decoration: const InputDecoration(labelText: '叙事视角'),
                  items: [
                    for (final v in ['第三人称', '第一人称', '多视角'])
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => setState(() => _pov = v!),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _greeting,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '采用哪个开场'),
                  items: [
                    for (final (i, text) in _card!.greetings.indexed)
                      DropdownMenuItem(
                        value: i,
                        child: Text(
                          '${i == 0 ? '默认开场' : '备用开场 $i'} · ${text.replaceAll('\n', ' ')}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    _greeting = v!;
                    _refreshOpening();
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _opening,
                  minLines: 5,
                  maxLines: 14,
                  onChanged: (_) => setState(() {
                    _edited = true;
                    _error = null;
                  }),
                  decoration: const InputDecoration(
                    labelText: '第一幕正文',
                    alignLabelWithHint: true,
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '开场需要手动调整：$_error',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy || _error != null ? null : _create,
                  icon: const Icon(Icons.auto_stories_outlined),
                  label: const Text('创建小说与初始资料'),
                ),
              ],
            ),
          ),
  );
}
