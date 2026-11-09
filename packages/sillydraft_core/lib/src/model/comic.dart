import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../transfer/project_snapshot.dart' show canonicalJson;
import 'story.dart';

const comicBatchLength = 6000;

/// Stable UTF-16 ranges, including whitespace. Never normalize source text.
List<Map<String, dynamic>> splitComicSource(
  String text, {
  int maxUnitLength = 1400,
}) {
  if (maxUnitLength < 2) throw ArgumentError.value(maxUnitLength);
  final result = <Map<String, dynamic>>[];
  var start = 0;
  while (start < text.length) {
    var end = min(start + maxUnitLength, text.length);
    for (var i = start; i < end; i++) {
      if ('\n。！？!?'.contains(text[i])) {
        end = i + 1;
        break;
      }
    }
    if (end < text.length && _lowSurrogate(text.codeUnitAt(end))) end--;
    final value = text.substring(start, end);
    final unusual = RegExp(r'<[^>]+>|```|~~~|\uFFFC').hasMatch(value);
    result.add({
      'id': 'u$start',
      'start': start,
      'end': end,
      'text': value,
      'disposition': value.trim().isEmpty
          ? 'decoration'
          : unusual
          ? 'unresolved'
          : 'story',
      'reason': value.trim().isEmpty ? '空白' : '',
    });
    start = end;
  }
  return result;
}

bool _lowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;

/// Immutable, portable comic content. JSON copies keep UI edits out of saved revisions.
final class ComicDocument {
  ComicDocument._(this._encoded);
  final String _encoded;

  factory ComicDocument.draft({
    required Chapter chapter,
    String style = '',
    List<Map<String, dynamic>> priorSources = const [],
    String context = '',
  }) => ComicDocument.fromJson({
    'version': 1,
    'adaptationId': const Uuid().v4(),
    'chapterId': chapter.id,
    'sourceRevisionId': chapter.revisionId,
    'sourceText': chapter.content.text,
    'priorSources': priorSources,
    'context': context,
    'style': style,
    'units': splitComicSource(chapter.content.text),
    'facts': <dynamic>[],
    'panels': <dynamic>[],
    'continuity': '',
    'audit': null,
  });

  factory ComicDocument.original({
    required String chapterId,
    required String instruction,
    String style = '',
    List<Map<String, dynamic>> priorComics = const [],
  }) => ComicDocument.fromJson({
    'version': 2,
    'origin': 'original',
    'adaptationId': const Uuid().v4(),
    'chapterId': chapterId,
    'instruction': instruction,
    'priorComics': priorComics,
    'sourceText': '',
    'priorSources': <dynamic>[],
    'context': '',
    'style': style,
    'units': <dynamic>[],
    'facts': <dynamic>[],
    'panels': <dynamic>[],
    'pages': <dynamic>[],
    'continuity': '',
    'audit': null,
  });

  factory ComicDocument.fromJson(Map<String, dynamic> json) {
    _keys(json, {
      'version',
      if (json['version'] == 2) ...[
        'origin',
        'instruction',
        'priorComics',
        'pages',
      ],
      'adaptationId',
      'chapterId',
      'sourceRevisionId',
      'sourceText',
      'priorSources',
      'context',
      'style',
      'units',
      'facts',
      'panels',
      'continuity',
      'audit',
    });
    if (![1, 2].contains(json['version'])) _invalid('不支持的漫画文档版本');
    final original = json['version'] == 2 && json['origin'] == 'original';
    if (json['version'] == 2) {
      _enum(json, 'origin', ['original', 'adaptation']);
      if (original) {
        _string(json, 'instruction', required: true);
        if (json['sourceRevisionId'] != null ||
            json['sourceText'] != '' ||
            _maps(json, 'units').isNotEmpty ||
            _maps(json, 'facts').isNotEmpty ||
            _maps(json, 'priorSources').isNotEmpty) {
          _invalid('原创漫画不能包含小说来源');
        }
        final seen = <String>{};
        for (final ref in _maps(json, 'priorComics')) {
          _keys(ref, {'chapterId', 'revisionId'});
          _string(ref, 'chapterId', required: true);
          if (ref['revisionId'] != null) {
            _string(ref, 'revisionId', required: true);
          }
          if (!seen.add(ref['chapterId'] as String) ||
              ref['chapterId'] == json['chapterId']) {
            _invalid('漫画前情引用重复');
          }
        }
      } else if (json.containsKey('instruction') ||
          json.containsKey('priorComics')) {
        _invalid('改编漫画不能包含原创来源');
      }
    }
    for (final key in [
      'adaptationId',
      'chapterId',
      if (!original) 'sourceRevisionId',
    ]) {
      _string(json, key, required: true);
    }
    _string(json, 'sourceText', limit: 4000000);
    for (final key in ['context', 'style', 'continuity']) {
      _string(json, key);
    }
    final source = json['sourceText'] as String;
    final prior = _maps(json, 'priorSources');
    final priorIds = <String>{};
    for (final p in prior) {
      _keys(p, {'chapterId', 'revisionId'});
      _string(p, 'chapterId', required: true);
      _string(p, 'revisionId', required: true);
      if (!priorIds.add(p['chapterId'] as String) ||
          p['chapterId'] == json['chapterId']) {
        _invalid('前情章节重复');
      }
    }
    final units = _maps(json, 'units');
    final unitIds = _ids(units);
    var offset = 0;
    for (final u in units) {
      _keys(u, {'id', 'start', 'end', 'text', 'disposition', 'reason'});
      if (u['start'] != offset ||
          u['end'] is! int ||
          (u['end'] as int) <= offset ||
          (u['end'] as int) > source.length) {
        _invalid('漫画源文范围无效');
      }
      final end = u['end'] as int;
      if (end < source.length && _lowSurrogate(source.codeUnitAt(end))) {
        _invalid('漫画源文截断字符');
      }
      if (source.substring(offset, end) != u['text']) _invalid('漫画源文与范围不符');
      _enum(u, 'disposition', [
        'story',
        'decoration',
        'presentation',
        'unresolved',
      ]);
      _string(u, 'reason');
      if (['decoration', 'presentation'].contains(u['disposition']) &&
          (u['reason'] as String).trim().isEmpty) {
        _invalid('排除来源需要说明理由');
      }
      offset = end;
    }
    if (offset != source.length) _invalid('漫画源文没有完整覆盖');
    final facts = _maps(json, 'facts');
    final factIds = _ids(facts), preceding = <String>{};
    for (final f in facts) {
      _keys(f, {
        'id',
        'kind',
        'summary',
        'unitIds',
        'evidence',
        'dependsOn',
        'speaker',
        'quote',
      });
      _enum(f, 'kind', [
        'action',
        'dialogue',
        'emotion',
        'thought',
        'setting',
        'cause',
        'negation',
        'clue',
        'metaphor',
      ]);
      _string(f, 'summary', required: true);
      _string(f, 'evidence', required: true);
      final refs = _refs(f, 'unitIds', unitIds, nonempty: true);
      final evidence = units
          .where((u) => refs.contains(u['id']))
          .map((u) => u['text'])
          .join();
      if (!evidence.contains(f['evidence'] as String)) _invalid('事实证据不是原文');
      _refs(f, 'dependsOn', preceding);
      if (f['kind'] == 'dialogue') {
        _string(f, 'speaker', required: true);
        _string(f, 'quote', required: true);
        if (!evidence.contains(f['quote'] as String)) _invalid('对白不是原句');
      } else if (f.containsKey('speaker') || f.containsKey('quote')) {
        _invalid('只有对白事实包含说话者和原句');
      }
      preceding.add(f['id'] as String);
    }
    final panels = _maps(json, 'panels');
    _ids(panels);
    final previousPanels = <String>{};
    for (final p in panels) {
      _keys(p, {
        'id',
        'factIds',
        'sceneId',
        'description',
        'continuity',
        'texts',
        'assetId',
        'referenceAssetIds',
        'previousPanelId',
        'visualReview',
        'imageTaskId',
      });
      final refs = _refs(p, 'factIds', factIds, nonempty: !original);
      for (final key in ['sceneId', 'description']) {
        _string(p, key, required: true);
      }
      _string(p, 'continuity');
      for (final key in ['assetId', 'imageTaskId']) {
        if (p[key] != null) _string(p, key, required: true);
      }
      _strings(p['referenceAssetIds']);
      if ((p['referenceAssetIds'] as List).length > 16) _invalid('参考图过多');
      if (p['previousPanelId'] != null &&
          !previousPanels.contains(p['previousPanelId'])) {
        _invalid('前一格引用倒置');
      }
      if (p['visualReview'] != null && p['visualReview'] is! bool) {
        _invalid('画面复核状态无效');
      }
      for (final t in _maps(p, 'texts')) {
        _keys(t, {'kind', 'speaker', 'text', 'factId'});
        _enum(t, 'kind', ['dialogue', 'thought', 'narration', 'sound']);
        _string(t, 'speaker');
        _string(t, 'text', required: true);
        if (!original && !refs.contains(t['factId'])) _invalid('文字缺少本格事实来源');
        if (original && t.containsKey('factId')) _invalid('原创对白不能伪造事实来源');
      }
      previousPanels.add(p['id'] as String);
    }
    if (json['version'] == 2) {
      final pages = _maps(json, 'pages');
      _ids(pages);
      final members = <String>[];
      for (final page in pages) {
        _keys(page, {
          'id',
          'panelIds',
          'assetId',
          'imageTaskId',
          'fingerprint',
          'visualReview',
          'referenceAssetIds',
          'characters',
        });
        members.addAll(_refs(page, 'panelIds', previousPanels, nonempty: true));
        _strings(page['referenceAssetIds']);
        if ((page['referenceAssetIds'] as List).length > 16) _invalid('参考图过多');
        // Names that pick automatic reference images, main characters first.
        if (page['characters'] != null) {
          final names = _strings(page['characters']);
          if (names.length > 16 ||
              names.toSet().length != names.length ||
              names.any((n) => n.trim().isEmpty || n.length > 100)) {
            _invalid('漫画页人物无效');
          }
        }
        for (final key in ['assetId', 'imageTaskId', 'fingerprint']) {
          if (page[key] != null) _string(page, key, required: true);
        }
        if (page['assetId'] != null && page['fingerprint'] == null) {
          _invalid('漫画页缺少绘制指纹');
        }
        if (page['visualReview'] != null && page['visualReview'] is! bool) {
          _invalid('漫画页复核状态无效');
        }
      }
      if (canonicalJson(members) !=
          canonicalJson(panels.map((p) => p['id']).toList())) {
        _invalid('漫画页必须按顺序完整覆盖分镜');
      }
      if (panels.any((p) => p['assetId'] != null || p['imageTaskId'] != null)) {
        _invalid('新版漫画图片属于页');
      }
    }
    final doc = ComicDocument._(jsonEncode(json));
    if (json['audit'] != null) {
      final audit = _map(json['audit']);
      _keys(audit, {'fingerprint', 'reviews'});
      if (audit['fingerprint'] != doc.fingerprint) _invalid('漫画检查已过期');
      final reviews = _maps(audit, 'reviews');
      final expected = doc.reviewScopes;
      if (reviews.length != expected.length ||
          _ids(reviews).length != expected.length) {
        _invalid('漫画检查不完整');
      }
      for (final r in reviews) {
        _keys(r, {'id', 'unitIds', 'issues'});
        if (!expected.containsKey(r['id']) ||
            canonicalJson(r['unitIds']) != canonicalJson(expected[r['id']])) {
          _invalid('漫画检查缺少来源或边界');
        }
        _strings(r['issues']);
      }
      if (doc.auditIssues.isEmpty && doc.structuralIssues.isNotEmpty) {
        _invalid('漫画结构有遗漏，不能标为通过');
      }
    }
    return doc;
  }

  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  String get chapterId => toJson()['chapterId'] as String;
  String? get sourceRevisionId => toJson()['sourceRevisionId'] as String?;
  bool get isOriginal => toJson()['origin'] == 'original';
  bool get hasPages => toJson()['version'] == 2;
  List<Map<String, dynamic>> get pages =>
      hasPages ? _maps(toJson(), 'pages') : [];
  List<Map<String, dynamic>> get priorComics =>
      isOriginal ? _maps(toJson(), 'priorComics') : [];
  List<Map<String, dynamic>> get imageItems => hasPages ? pages : panels;

  /// Originals only need every page drawn; stale and flagged pages are hints.
  bool get complete => isOriginal
      ? pages.isNotEmpty && pages.every((p) => p['assetId'] != null)
      : imageItems.isNotEmpty &&
            imageItems.every(
              (p) =>
                  p['assetId'] != null &&
                  p['visualReview'] != true &&
                  (!hasPages || p['fingerprint'] == pageFingerprint(p)),
            );

  /// Drawn pages whose storyboard changed after drawing.
  List<String> get stalePageIds => [
    for (final p in pages)
      if (p['assetId'] != null && p['fingerprint'] != pageFingerprint(p))
        p['id'] as String,
  ];

  String? get lastPageId => pages.lastOrNull?['id'] as String?;

  String pageFingerprint(Map<String, dynamic> page) => sha256
      .convert(
        utf8.encode(
          canonicalJson({
            'style': style,
            'panelIds': page['panelIds'],
            'panels': panels
                .where((p) => (page['panelIds'] as List).contains(p['id']))
                .toList(),
            'referenceAssetIds': page['referenceAssetIds'],
          }),
        ),
      )
      .toString();

  String pageTranscript(Map<String, dynamic> page) => panels
      .where((p) => (page['panelIds'] as List).contains(p['id']))
      .map(
        (p) =>
            '${p['description']}\n${(p['texts'] as List).map((t) => '${t['speaker']}：${t['text']}').join('\n')}',
      )
      .join('\n\n');

  ComicDocument withImage(
    String id, {
    required String assetId,
    required String taskId,
    bool needsReview = false,
  }) {
    final items = imageItems;
    final item = items.firstWhere((p) => p['id'] == id);
    item.addAll({
      'assetId': assetId,
      'imageTaskId': taskId,
      'visualReview': needsReview,
      if (hasPages) 'fingerprint': pageFingerprint(item),
    });
    return ComicDocument.fromJson({
      ...toJson(),
      hasPages ? 'pages' : 'panels': items,
    });
  }

  /// Legacy images remain in history; explicit redraw upgrades their layout.
  ComicDocument asPages() {
    if (hasPages) return this;
    final values = panels;
    for (final p in values) {
      for (final key in ['assetId', 'imageTaskId', 'visualReview']) {
        p.remove(key);
      }
    }
    final next = ComicDocument.fromJson({
      ...toJson(),
      'version': 2,
      'origin': 'adaptation',
      'panels': values,
      'audit': null,
      'pages': [
        for (var i = 0; i < values.length; i += 6)
          <String, dynamic>{
            'id': 'page-${values[i]['id']}',
            'panelIds': values.skip(i).take(6).map((p) => p['id']).toList(),
            'referenceAssetIds': <String>[],
          },
      ],
    });
    return ComicDocument.fromJson({
      ...next.toJson(),
      if (checked)
        'audit': <String, dynamic>{
          ...toJson()['audit'] as Map<String, dynamic>,
          'fingerprint': next.fingerprint,
        },
    });
  }

  String get sourceText => toJson()['sourceText'] as String;
  String get style => toJson()['style'] as String;
  List<Map<String, dynamic>> get units => _maps(toJson(), 'units');
  List<Map<String, dynamic>> get facts => _maps(toJson(), 'facts');
  List<Map<String, dynamic>> get panels => _maps(toJson(), 'panels');
  List<Map<String, dynamic>> get priorSources =>
      _maps(toJson(), 'priorSources');

  List<List<Map<String, dynamic>>> get batches {
    final out = <List<Map<String, dynamic>>>[];
    var batch = <Map<String, dynamic>>[], length = 0;
    for (final u in units) {
      final size = (u['text'] as String).length;
      if (batch.isNotEmpty && length + size > comicBatchLength) {
        out.add(batch);
        batch = [];
        length = 0;
      }
      batch.add(u);
      length += size;
    }
    if (batch.isNotEmpty) out.add(batch);
    return out;
  }

  Map<String, List<String>> get reviewScopes {
    if (isOriginal) return {'original': <String>[]};
    final chunks = batches;
    return {
      for (var i = 0; i < chunks.length; i++)
        'batch-$i': chunks[i].map((u) => u['id'] as String).toList(),
      for (var i = 1; i < chunks.length; i++)
        'boundary-$i': [
          chunks[i - 1].last['id'] as String,
          chunks[i].first['id'] as String,
        ],
    };
  }

  String get fingerprint {
    final json = toJson()..remove('audit');
    for (final p in (json['panels'] as List).cast<Map>()) {
      for (final key in [
        'assetId',
        'imageTaskId',
        'referenceAssetIds',
        'visualReview',
      ]) {
        p.remove(key);
      }
    }
    for (final page in (json['pages'] as List? ?? [])) {
      for (final key in [
        'assetId',
        'imageTaskId',
        'fingerprint',
        'visualReview',
        'referenceAssetIds',
        'characters',
      ]) {
        page.remove(key);
      }
    }
    return sha256.convert(utf8.encode(canonicalJson(json))).toString();
  }

  List<String> get structuralIssues {
    final issues = <String>[];
    final allFacts = facts, allPanels = panels;
    if (isOriginal) return allPanels.isEmpty ? ['没有分镜'] : [];
    final coveredUnits = {for (final f in allFacts) ...f['unitIds'] as List};
    final coveredFacts = {for (final p in allPanels) ...p['factIds'] as List};
    for (final u in units) {
      if (u['disposition'] == 'unresolved') {
        issues.add('${u['id']}：代码、HTML 或附件尚未处理');
      }
      if (u['disposition'] == 'story' && !coveredUnits.contains(u['id'])) {
        issues.add('${u['id']}：未提取事实');
      }
    }
    if (allPanels.isEmpty) issues.add('没有分镜');
    final firstPanel = <String, int>{};
    for (var i = 0; i < allPanels.length; i++) {
      for (final id in allPanels[i]['factIds'] as List) {
        firstPanel.putIfAbsent(id as String, () => i);
      }
    }
    final dialogue = [
      for (final p in allPanels)
        for (final t in _maps(p, 'texts'))
          if (t['kind'] == 'dialogue') t,
    ];
    final sourceOrder = <({String id, int offset, int index})>[];
    for (final f in allFacts) {
      if (!coveredFacts.contains(f['id'])) issues.add('${f['id']}：事实未进入分镜');
      for (final id in f['dependsOn'] as List) {
        if ((firstPanel[id] ?? 999999) > (firstPanel[f['id']] ?? -1)) {
          issues.add('${f['id']}：因果顺序倒置');
        }
      }
      if (f['kind'] == 'dialogue') {
        final selected = units
            .where((u) => (f['unitIds'] as List).contains(u['id']))
            .toList();
        final text = selected.map((u) => u['text']).join();
        final evidence = f['evidence'] as String;
        final quote = f['quote'] as String;
        // Evidence disambiguates identical lines spoken at different moments.
        var offset = evidence.contains(quote)
            ? text.indexOf(evidence) + evidence.indexOf(quote)
            : text.indexOf(quote);
        for (final u in selected) {
          final length = (u['text'] as String).length;
          if (offset < length) {
            sourceOrder.add((
              id: f['id'] as String,
              offset: (u['start'] as int) + offset,
              index: sourceOrder.length,
            ));
            break;
          }
          offset -= length;
        }
        final texts = dialogue.where((t) => t['factId'] == f['id']).toList();
        if (texts.length != 1 ||
            texts.single['text'] != f['quote'] ||
            texts.single['speaker'] != f['speaker']) {
          issues.add('${f['id']}：对白缺失、重复或说话者不符');
        }
      }
    }
    sourceOrder.sort((a, b) {
      final position = a.offset.compareTo(b.offset);
      return position == 0 ? a.index.compareTo(b.index) : position;
    });
    if (dialogue.length == sourceOrder.length &&
        sourceOrder.indexed.any((e) => dialogue[e.$1]['factId'] != e.$2.id)) {
      issues.add('对白顺序与原文不符');
    }
    return issues;
  }

  List<String> get auditIssues => toJson()['audit'] == null
      ? []
      : [
          for (final r in (toJson()['audit']['reviews'] as List))
            ...(r['issues'] as List).cast<String>(),
        ];
  bool get checked =>
      toJson()['audit'] != null &&
      auditIssues.isEmpty &&
      structuralIssues.isEmpty;
  Set<String> get assetIds => {
    for (final p in pages) ...[
      if (p['assetId'] is String) p['assetId'] as String,
      ...(p['referenceAssetIds'] as List).cast<String>(),
    ],
    for (final p in panels) ...[
      if (p['assetId'] is String) p['assetId'] as String,
      ...(p['referenceAssetIds'] as List).cast<String>(),
    ],
  };

  ComicDocument edit(Map<String, dynamic> changes) =>
      ComicDocument.fromJson({...toJson(), ...changes, 'audit': null});

  /// Author edits preserve text checks only when the text is unchanged.
  ComicDocument editPanels(List<Map<String, dynamic>> values) {
    final next = (jsonDecode(jsonEncode(values)) as List)
        .cast<Map<String, dynamic>>();
    final old = {for (final p in panels) p['id']: p};
    final seen = <String>{}, affected = <String>{}, images = <String>{};
    final order = panels.map((p) => p['id']).toList();
    for (final (i, p) in next.indexed) {
      final before = old[p['id']];
      if (!seen.contains(p['previousPanelId'])) p.remove('previousPanelId');
      final changed =
          before == null ||
          i >= order.length ||
          order[i] != p['id'] ||
          [
            'description',
            'continuity',
            'sceneId',
            'assetId',
            'referenceAssetIds',
            'previousPanelId',
          ].any((key) => canonicalJson(before[key]) != canonicalJson(p[key]));
      if (changed) {
        affected.add(p['id'] as String);
        if (before?['assetId'] case final String id) images.add(id);
      }
      seen.add(p['id'] as String);
    }
    for (final p in old.values.where((p) => !seen.contains(p['id']))) {
      affected.add(p['id'] as String);
      if (p['assetId'] case final String id) images.add(id);
    }
    // Explicit references can point backwards or form cycles.
    int count;
    do {
      count = affected.length;
      for (final p in next) {
        if (affected.contains(p['id']) ||
            affected.contains(p['previousPanelId']) ||
            (p['referenceAssetIds'] as List).any(images.contains)) {
          affected.add(p['id'] as String);
          if (old[p['id']]?['assetId'] case final String id) images.add(id);
          if (p['assetId'] != null) p['visualReview'] = true;
        }
      }
    } while (affected.length != count);
    var offset = 0;
    final nextPages = <Map<String, dynamic>>[];
    if (hasPages) {
      for (final page in pages) {
        final count = (page['panelIds'] as List)
            .where((id) => seen.contains(id))
            .length;
        if (count == 0) continue;
        nextPages.add({
          ...page,
          'panelIds': next
              .skip(offset)
              .take(count)
              .map((p) => p['id'])
              .toList(),
        });
        offset += count;
      }
      if (offset != next.length) throw const FormatException('新增分镜请使用续画或分镜规划');
    }
    final result = edit({'panels': next, if (hasPages) 'pages': nextPages});
    return result.fingerprint == fingerprint
        ? ComicDocument.fromJson({
            ...result.toJson(),
            'audit': toJson()['audit'],
          })
        : result;
  }

  /// Drops the page and its panels; the image stays in history.
  ComicDocument withoutPage(String pageId) {
    final removed = (_page(pageId)['panelIds'] as List).toSet();
    return _withLayout(
      panels.where((p) => !removed.contains(p['id'])).toList(),
      pages.where((p) => p['id'] != pageId).toList(),
    );
  }

  /// Replaces one page's panels in place. Images stay, possibly stale; the
  /// check survives only an unchanged storyboard.
  ComicDocument editPage(String pageId, List<Map<String, dynamic>> values) {
    if (values.isEmpty) throw const FormatException('每页至少需要一格分镜');
    final old = (_page(pageId)['panelIds'] as List).toSet();
    final next = (jsonDecode(jsonEncode(values)) as List)
        .cast<Map<String, dynamic>>();
    final all = panels;
    // Pages cover panels in order, so this page's panels are contiguous.
    final start = all.indexWhere((p) => old.contains(p['id']));
    final result = _withLayout(
      [...all.take(start), ...next, ...all.skip(start + old.length)],
      [
        for (final p in pages)
          p['id'] == pageId
              ? {...p, 'panelIds': next.map((p) => p['id']).toList()}
              : p,
      ],
      edited: pageId,
    );
    return result.fingerprint == fingerprint
        ? ComicDocument.fromJson({
            ...result.toJson(),
            'audit': toJson()['audit'],
          })
        : result;
  }

  Map<String, dynamic> _page(String id) =>
      pages.where((p) => p['id'] == id).firstOrNull ?? _invalid('漫画页不存在');

  // Links to removed or now-later panels would fail validation. Dropping one
  // is layout, not an edit: drawn pages other than [edited] stay fresh.
  ComicDocument _withLayout(
    List<Map<String, dynamic>> panels,
    List<Map<String, dynamic>> pages, {
    String? edited,
  }) {
    final seen = <Object?>{};
    for (final p in panels) {
      if (p['previousPanelId'] != null &&
          !seen.contains(p['previousPanelId'])) {
        p.remove('previousPanelId');
      }
      seen.add(p['id']);
    }
    final fresh = {
      for (final p in this.pages)
        if (p['id'] != edited &&
            p['assetId'] != null &&
            p['fingerprint'] == pageFingerprint(p))
          p['id'],
    };
    final next = edit({'panels': panels, 'pages': pages});
    return next.edit({
      'pages': [
        for (final p in next.pages)
          fresh.contains(p['id'])
              ? {...p, 'fingerprint': next.pageFingerprint(p)}
              : p,
      ],
    });
  }
}

Never _invalid(String message) => throw FormatException(message);
Map<String, dynamic> _map(Object? v) =>
    v is Map<String, dynamic> ? v : _invalid('漫画字段必须是对象');
void _keys(Map<String, dynamic> v, Set<String> keys) {
  if (v.keys.any((k) => !keys.contains(k))) _invalid('未知的漫画字段');
}

void _string(Map v, String key, {bool required = false, int limit = 100000}) {
  final x = v[key];
  if (x is! String || x.length > limit || required && x.trim().isEmpty) {
    _invalid('漫画字段 $key 无效');
  }
}

void _enum(Map v, String key, List<String> values) {
  if (!values.contains(v[key])) _invalid('漫画字段 $key 无效');
}

List<Map<String, dynamic>> _maps(Map v, String key) {
  final x = v[key];
  if (x is! List || x.length > 20000) _invalid('漫画列表 $key 无效或过大');
  return x.map(_map).toList();
}

List<String> _strings(Object? x) {
  if (x is! List ||
      x.length > 20000 ||
      x.any((s) => s is! String || s.length > 100000)) {
    _invalid('漫画引用列表无效');
  }
  return x.cast<String>();
}

Set<String> _ids(List<Map<String, dynamic>> items) {
  final ids = <String>{};
  for (final item in items) {
    _string(item, 'id', required: true, limit: 100);
    if (!ids.add(item['id'] as String)) _invalid('漫画 ID 重复');
  }
  return ids;
}

List<String> _refs(
  Map v,
  String key,
  Set<String> ids, {
  bool nonempty = false,
}) {
  final refs = _strings(v[key]);
  if (nonempty && refs.isEmpty ||
      refs.toSet().length != refs.length ||
      refs.any((id) => !ids.contains(id))) {
    _invalid('漫画 $key 引用无效或倒置');
  }
  return refs;
}

final class ComicRevision {
  const ComicRevision({
    required this.id,
    required this.novelId,
    required this.chapterId,
    required this.originBranchId,
    required this.document,
    required this.createdAt,
    required this.reason,
    this.parentRevisionId,
    this.taskId,
  });
  final String id, novelId, chapterId, originBranchId, reason;
  final String? parentRevisionId, taskId;
  final ComicDocument document;
  final DateTime createdAt;
}

final class ComicConflict implements Exception {
  const ComicConflict();
  @override
  String toString() => '漫画或来源已经更新，结果已保留，请比较最新版本后重新检查。';
}

/// External references move when copying a work; panel, fact and scene IDs do not.
ComicDocument remapComicDocument(ComicDocument doc, Map<String, String> ids) {
  final json = doc.toJson();
  void remap(Map value, String key) {
    if (value[key] is String) value[key] = ids[value[key]] ?? value[key];
  }

  for (final key in ['chapterId', 'sourceRevisionId']) {
    remap(json, key);
  }
  for (final p in [
    ...json['priorSources'] as List,
    ...?json['priorComics'] as List?,
  ]) {
    remap(p as Map, 'chapterId');
    remap(p, 'revisionId');
  }
  for (final p in [...json['panels'] as List, ...?json['pages'] as List?]) {
    for (final key in ['assetId', 'imageTaskId']) {
      remap(p as Map, key);
    }
    p['referenceAssetIds'] = [
      for (final id in p['referenceAssetIds'] as List) ids[id] ?? id,
    ];
  }
  for (final page in json['pages'] as List? ?? []) {
    final old = doc.pages.firstWhere((p) => p['id'] == page['id']);
    if (old['fingerprint'] == doc.pageFingerprint(old)) {
      page['fingerprint'] = ComicDocument.fromJson({...json, 'audit': null})
          .pageFingerprint(Map<String, dynamic>.from(page as Map));
    }
  }
  final audit = json.remove('audit');
  json['audit'] = null;
  final changed = ComicDocument.fromJson(json);
  if (audit != null) {
    audit['fingerprint'] = changed.fingerprint;
    json['audit'] = audit;
  }
  return ComicDocument.fromJson(json);
}
