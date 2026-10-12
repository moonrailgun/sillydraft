import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../transfer/safe_archive.dart';
import 'import_types.dart';
import 'world_book.dart';

final class CharacterCard extends JsonSource {
  CharacterCard._(
    super.raw,
    this.version,
    this._data,
    Uint8List source,
    Map<String, Uint8List> assets,
    this.diagnostics,
  ) : _source = Uint8List.fromList(source),
      _assets = {
        for (final e in assets.entries) e.key: Uint8List.fromList(e.value),
      };
  final int version;
  final Map<String, dynamic> _data;
  final Uint8List _source;
  final Map<String, Uint8List> _assets;
  final List<CompatibilityDiagnostic> diagnostics;
  Uint8List get sourceBytes => Uint8List.fromList(_source);
  Map<String, Uint8List> get assets => {
    for (final e in _assets.entries) e.key: Uint8List.fromList(e.value),
  };
  String get name => stringField(_data, 'name');
  String get description => stringField(_data, 'description');
  String get personality => stringField(_data, 'personality');
  String get scenario => stringField(_data, 'scenario');
  String get firstMessage => stringField(_data, 'first_mes');
  String get examples => stringField(_data, 'mes_example');
  String get systemPrompt => stringField(_data, 'system_prompt');
  String get postHistoryInstructions =>
      stringField(_data, 'post_history_instructions');
  String get creatorNotes => stringField(_data, 'creator_notes');
  List<String> get greetings => List.unmodifiable([
    firstMessage,
    ...stringList(_data['alternate_greetings'], 'alternate_greetings'),
  ]);
  WorldBook? get worldBook => _data['character_book'] == null
      ? null
      : WorldBook.fromJson(
          jsonObject(_data['character_book'], 'character_book'),
        );
  Map<String, dynamic> get extensions => jsonObject(
    jsonDecode(jsonEncode(_data['extensions'] ?? <String, dynamic>{})),
    'extensions',
  );
}

final class CardImporter {
  const CardImporter({
    this.maxBytes = 32 * 1024 * 1024,
    this.maxExpandedBytes = 128 * 1024 * 1024,
  });
  final int maxBytes, maxExpandedBytes;

  CharacterCard decode(Uint8List bytes, String filename) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('角色卡为空或超过大小限制');
    }
    final assets = <String, Uint8List>{};
    Map<String, dynamic> raw;
    if (_isPng(bytes)) {
      final metadata = _readPng(bytes, assets);
      final payload = metadata['ccv3'] ?? metadata['chara'];
      if (payload == null) throw const FormatException('PNG 中没有角色卡');
      raw = _json(base64Decode(payload));
    } else if (filename.toLowerCase().endsWith('.charx') ||
        (bytes.length >= 4 && bytes[0] == 80 && bytes[1] == 75)) {
      assets.addAll(readSafeZip(bytes, maxExpandedBytes: maxExpandedBytes));
      final card = assets.remove('card.json');
      if (card == null) throw const FormatException('CHARX 缺少 card.json');
      raw = _json(card);
    } else {
      raw = _json(bytes);
    }
    final version = switch (raw['spec']) {
      null => 1,
      'chara_card_v2' => 2,
      'chara_card_v3' => 3,
      _ => throw const FormatException('不支持此角色卡规范'),
    };
    final data = version == 1 ? raw : jsonObject(raw['data'], 'data');
    if (stringField(data, 'name').trim().isEmpty) {
      throw const FormatException('角色卡缺少姓名');
    }
    for (final key in [
      'description',
      'personality',
      'scenario',
      'first_mes',
      'mes_example',
      'system_prompt',
      'post_history_instructions',
      'creator_notes',
    ]) {
      stringField(data, key);
    }
    stringList(data['alternate_greetings'], 'alternate_greetings');
    if (data['character_book'] != null) {
      WorldBook.fromJson(jsonObject(data['character_book'], 'character_book'));
    }
    final diagnostics = <CompatibilityDiagnostic>[];
    if (version > 1 && raw['spec_version'] != '$version.0') {
      diagnostics.add(
        const CompatibilityDiagnostic('card_spec_version', '保留此规范版本的未知字段'),
      );
    }
    final assetDeclarations = data['assets'];
    if (assetDeclarations is List) {
      for (final value in assetDeclarations) {
        final declaration = jsonObject(value, 'assets');
        final uri = stringField(declaration, 'uri');
        final prefix = uri.startsWith('embeded://')
            ? 'embeded://'
            : uri.startsWith('__asset:')
            ? '__asset:'
            : null;
        if (prefix != null) {
          final path = uri.substring(prefix.length);
          validateArchivePath(path);
          if (!assets.containsKey(path)) {
            diagnostics.add(
              CompatibilityDiagnostic('missing_asset', '角色卡资源缺失：$path'),
            );
          }
        } else if (uri != 'ccdefault:') {
          diagnostics.add(
            CompatibilityDiagnostic('external_asset', '外部资源保留引用，导入时不自动下载：$uri'),
          );
        }
      }
    }
    return CharacterCard._(
      raw,
      version,
      data,
      bytes,
      assets,
      List.unmodifiable(diagnostics),
    );
  }

  Map<String, dynamic> _json(List<int> bytes) {
    if (bytes.length > maxBytes) throw const FormatException('角色卡 JSON 超过大小限制');
    return jsonObject(
      jsonDecode(utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '')),
      '角色卡',
    );
  }

  bool _isPng(Uint8List bytes) =>
      bytes.length >= 8 &&
      const [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ].indexed.every((e) => bytes[e.$1] == e.$2);

  Map<String, String> _readPng(Uint8List bytes, Map<String, Uint8List> assets) {
    var offset = 8;
    var ended = false;
    final metadata = <String, String>{};
    final view = ByteData.sublistView(bytes);
    while (offset + 12 <= bytes.length) {
      final length = view.getUint32(offset);
      if (length > bytes.length - offset - 12) {
        throw const FormatException('PNG 数据截断');
      }
      final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
      final data = Uint8List.sublistView(
        bytes,
        offset + 8,
        offset + 8 + length,
      );
      if (getCrc32(bytes.sublist(offset + 4, offset + 8 + length)) !=
          view.getUint32(offset + 8 + length)) {
        throw const FormatException('PNG 校验失败');
      }
      if (type == 'tEXt') {
        final separator = data.indexOf(0);
        if (separator < 1 || separator > 79) {
          throw const FormatException('PNG 文本块格式无效');
        }
        final key = latin1.decode(data.sublist(0, separator));
        if (key == 'ccv3' || key == 'chara') {
          if (metadata.containsKey(key)) {
            throw const FormatException('PNG 中角色卡重复');
          }
          metadata[key] = ascii.decode(data.sublist(separator + 1));
        } else if (key.startsWith('chara-ext-asset_:')) {
          final path = key.substring('chara-ext-asset_:'.length);
          validateArchivePath(path);
          assets[path] = base64Decode(
            ascii.decode(data.sublist(separator + 1)),
          );
        }
      }
      offset += length + 12;
      if (type == 'IEND') {
        ended = true;
        break;
      }
    }
    if (!ended) throw const FormatException('PNG 缺少结束块');
    return metadata;
  }
}
