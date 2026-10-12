import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:uuid/uuid.dart';

import '../model/resource.dart';
import '../storage/story_repository.dart';
import 'card_importer.dart';
import 'import_types.dart';
import 'preset_importer.dart';
import 'world_book.dart';

final class ResourcePreview extends JsonSource {
  ResourcePreview({
    required this.kind,
    required this.name,
    required Map<String, dynamic> data,
    required this.diagnostics,
  }) : super(data);
  final ResourceKind kind;
  final String name;
  final List<CompatibilityDiagnostic> diagnostics;
}

/// Normal data and shares contain sanitized JSON. Exact originals (including
/// PNG/CHARX assets) are authenticated encrypted; the key lives in OS storage.
final class ResourceLibrary {
  ResourceLibrary({required this.repository, required this.keyProvider});
  final StoryRepository repository;
  final Future<List<int>> Function() keyProvider;
  final _cipher = AesGcm.with256bits();

  /// Re-wrap an authenticated backup original using this installation's key.
  /// The resource identity is authenticated too; copying requires a new box.
  Future<Uint8List> protectOriginal(String id, Uint8List bytes) async {
    final key = await keyProvider();
    if (key.length != 32) throw const FormatException('资源保险库密钥无效');
    final box = await _cipher.encrypt(
      bytes,
      secretKey: SecretKey(key),
      aad: utf8.encode(id),
    );
    return Uint8List.fromList(box.concatenation());
  }

  ResourcePreview inspect(
    Uint8List bytes, {
    required String filename,
    required ResourceKind kind,
  }) {
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
      throw const FormatException('资源为空或超过 32 MB');
    }
    if (kind == ResourceKind.character) {
      final card = const CardImporter().decode(bytes, filename);
      return ResourcePreview(
        kind: kind,
        name: card.name,
        data: card.exportJson(),
        diagnostics: card.diagnostics,
      );
    }
    final raw = jsonObject(jsonDecode(utf8.decode(bytes)), '资源');
    final diagnostics = <CompatibilityDiagnostic>[];
    String name;
    if (kind == ResourceKind.preset) {
      final preset = PresetImporter().decode(raw);
      name = preset.name;
      diagnostics.addAll(preset.diagnostics);
    } else if (kind == ResourceKind.worldBook) {
      name = WorldBook.fromJson(raw).name;
    } else {
      final rules = raw['scripts'] is List ? raw['scripts'] as List : [raw];
      for (final rule in rules) {
        final data = jsonObject(rule, '正则');
        if (data['findRegex'] is! String || data['placement'] is! List) {
          throw const FormatException('正则缺少 findRegex 或 placement');
        }
      }
      name = stringField(raw, 'scriptName', fallback: stringField(raw, 'name'));
    }
    if (jsonEncode(raw) != jsonEncode(redactCredentials(raw))) {
      diagnostics.add(
        const CompatibilityDiagnostic(
          'protected-credentials',
          '含有连接凭据：原文件将加密保存，资源预览与普通导出会移除凭据。导入不会启用该连接。',
        ),
      );
    }
    return ResourcePreview(
      kind: kind,
      name: name.isEmpty ? filename : name,
      data: redactCredentials(raw),
      diagnostics: diagnostics,
    );
  }

  Future<LibraryResource> import(
    Uint8List bytes, {
    required String filename,
    required ResourceKind kind,
    String? parentId,
  }) async {
    final preview = inspect(bytes, filename: filename, kind: kind);
    final id = const Uuid().v4();
    final key = await keyProvider();
    if (key.length != 32) throw const FormatException('资源保险库密钥无效');
    final box = await _cipher.encrypt(
      bytes,
      secretKey: SecretKey(key),
      aad: utf8.encode(id),
    );
    return repository.storeResource(
      id: id,
      kind: kind,
      name: preview.name,
      filename: filename,
      sourceHash: sha256.convert(bytes).toString(),
      data: preview.raw,
      encryptedSource: box.concatenation(),
      parentId: parentId,
    );
  }

  Future<Uint8List> original(String id) async {
    final bytes = await repository.encryptedResourceSource(id);
    try {
      final box = SecretBox.fromConcatenation(
        bytes,
        nonceLength: _cipher.nonceLength,
        macLength: _cipher.macAlgorithm.macLength,
      );
      return Uint8List.fromList(
        await _cipher.decrypt(
          box,
          secretKey: SecretKey(await keyProvider()),
          aad: utf8.encode(id),
        ),
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('无法解密资源原文件，请检查本机安全存储或重新导入。');
    }
  }

  Future<LibraryResource> edit(String id, Map<String, dynamic> data) async {
    final old = await repository.getResource(id);
    return import(
      Uint8List.fromList(utf8.encode(jsonEncode(redactCredentials(data)))),
      filename: '${old.name}.json',
      kind: old.kind,
      parentId: id,
    );
  }

  Future<CharacterCard> character(String id) async {
    final resource = await repository.getResource(id);
    if (resource.kind != ResourceKind.character) {
      throw const FormatException('此资源不是角色卡');
    }
    // The writing runtime consumes sanitized metadata. Attachments remain in the
    // encrypted original for the asset service to import explicitly.
    return const CardImporter().decode(
      Uint8List.fromList(utf8.encode(jsonEncode(resource.data))),
      'card.json',
    );
  }

  Future<ImportedPreset> preset(String id) async {
    final resource = await repository.getResource(id);
    if (resource.kind != ResourceKind.preset) {
      throw const FormatException('此资源不是预设');
    }
    return PresetImporter().decode(resource.data);
  }
}
