import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:image/image.dart' as img;

import '../assets/asset_library.dart';
import '../model/resource.dart';
import '../model/story.dart';
import '../st/resource_library.dart';
import '../storage/story_repository.dart';
import 'project_snapshot.dart';
import 'safe_archive.dart';

final class BackupContents {
  BackupContents._(this.snapshot, this._files);
  final ProjectSnapshot snapshot;
  final Map<String, Uint8List> _files;
  int get assetCount => snapshot.tables['story_assets']!.length;
  int get branchCount => snapshot.tables['branches']!.length;
}

/// Exact ST originals may contain passwords. The whole portable backup is
/// authenticated encrypted; the local secrets file (resource key, model and sync keys) never leaves the device.
final class ProjectBackup {
  ProjectBackup({
    required this.repository,
    required this.assets,
    required this.resources,
  });
  final StoryRepository repository;
  final AssetLibrary assets;
  final ResourceLibrary resources;
  static const maxBytes = 128 * 1024 * 1024;
  static const maxExpandedBytes = 256 * 1024 * 1024;
  static const _maxMetadataBytes = 32 * 1024 * 1024;

  Future<Uint8List> create(
    String novelId, {
    required String passphrase,
  }) async => createSnapshot(
    await repository.exportProject(novelId),
    passphrase: passphrase,
  );

  Future<Uint8List> createSnapshot(
    ProjectSnapshot snapshot, {
    required String passphrase,
  }) async {
    _validatePassphrase(passphrase);
    final files = <String, Uint8List>{
      'project.json': Uint8List.fromList(
        utf8.encode(jsonEncode(snapshot.toJson())),
      ),
    };
    var size = files.values.single.length;
    if (size > _maxMetadataBytes) {
      throw const FormatException('项目元数据超过 32 MB，无法生成可恢复的备份');
    }
    void add(String name, Uint8List bytes) {
      if (files.containsKey(name)) return;
      size += bytes.length;
      if (size > maxExpandedBytes) {
        throw const FormatException('项目备份超过 256 MB，请减少未使用素材');
      }
      files[name] = bytes;
    }

    for (final row in snapshot.tables['story_assets']!) {
      final id = row['id'] as String;
      add('assets/${row['content_hash']}.png', await assets.read(id));
      add(
        'assets/${row['thumbnail_hash']}.jpg',
        await assets.read(id, thumbnail: true),
      );
    }
    for (final row in snapshot.tables['library_resources']!) {
      add(
        'originals/${row['id']}.bin',
        await resources.original(row['id'] as String),
      );
    }
    return Isolate.run(() async {
      final archive = Archive();
      final manifest = {
        'format': 'sillydraft-backup',
        'version': 1,
        'files': {
          for (final e in files.entries)
            e.key: {
              'size': e.value.length,
              'sha256': hashes.sha256.convert(e.value).toString(),
            },
        },
      };
      archive.addFile(
        ArchiveFile.string('manifest.json', jsonEncode(manifest)),
      );
      for (final e in files.entries) {
        archive.addFile(ArchiveFile.bytes(e.key, e.value));
      }
      final zipped = Uint8List.fromList(ZipEncoder().encode(archive));
      if (zipped.length > maxBytes - 128) {
        throw const FormatException('压缩备份超过 128 MB');
      }
      return _encrypt(zipped, passphrase);
    });
  }

  Future<BackupContents> read(
    Uint8List bytes, {
    required String passphrase,
  }) async {
    if (bytes.length > maxBytes) throw const FormatException('备份超过 128 MB');
    final contents = await Isolate.run(() async {
      final files = readSafeZip(
        await _decrypt(bytes, passphrase),
        maxExpandedBytes: maxExpandedBytes,
        maxEntries: 16384,
      );
      final manifestBytes = files.remove('manifest.json');
      if (manifestBytes == null || manifestBytes.length > 4 * 1024 * 1024) {
        throw const FormatException('备份清单缺失或过大');
      }
      final manifest = jsonDecode(utf8.decode(manifestBytes));
      if (manifest is! Map ||
          manifest['format'] != 'sillydraft-backup' ||
          manifest['version'] != 1 ||
          manifest['files'] is! Map) {
        throw const FormatException('备份清单无效');
      }
      final declared = manifest['files'] as Map;
      if (declared.length != files.length) {
        throw const FormatException('备份文件列表不匹配');
      }
      for (final e in files.entries) {
        final info = declared[e.key];
        if (info is! Map ||
            info['size'] != e.value.length ||
            info['sha256'] != hashes.sha256.convert(e.value).toString()) {
          throw const FormatException('备份文件损坏');
        }
      }
      final json = files['project.json'];
      if (json == null || json.length > _maxMetadataBytes) {
        throw const FormatException('项目元数据缺失或超过 32 MB');
      }
      final raw = jsonDecode(utf8.decode(json));
      if (raw is! Map<String, dynamic>) throw const FormatException('项目元数据无效');
      final snapshot = ProjectSnapshot.fromJson(raw);
      final wanted = <String>{'project.json'};
      for (final row in snapshot.tables['story_assets']!) {
        for (final thumbnail in [false, true]) {
          final hash = row[thumbnail ? 'thumbnail_hash' : 'content_hash'];
          if (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
            throw const FormatException('图片哈希无效');
          }
          final name = 'assets/$hash.${thumbnail ? 'jpg' : 'png'}';
          wanted.add(name);
          final image = files[name];
          if (image == null ||
              image.length > AssetLibrary.maxBytes ||
              hashes.sha256.convert(image).toString() != hash) {
            throw const FormatException('备份图片缺失或损坏');
          }
          final decoder = thumbnail ? img.JpegDecoder() : img.PngDecoder();
          final info = decoder.startDecode(image);
          if (info == null ||
              info.width < 1 ||
              info.height < 1 ||
              info.width > 8192 ||
              info.height > 8192 ||
              info.width * info.height > AssetLibrary.maxPixels ||
              decoder.numFrames() != 1) {
            throw const FormatException('备份图片尺寸或格式无效');
          }
          if (!thumbnail &&
              (row['width'] != info.width ||
                  row['height'] != info.height ||
                  row['byte_length'] != image.length)) {
            throw const FormatException('备份图片记录与文件不一致');
          }
          if (decoder.decodeFrame(0) == null) {
            throw const FormatException('备份图片无法解码');
          }
        }
      }
      for (final row in snapshot.tables['library_resources']!) {
        final id = row['id'];
        if (id is! String || !RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
          throw const FormatException('资源标识无效');
        }
        final name = 'originals/$id.bin';
        wanted.add(name);
        final original = files[name];
        if (original == null ||
            original.length > 32 * 1024 * 1024 ||
            hashes.sha256.convert(original).toString() != row['source_hash']) {
          throw const FormatException('ST 原文件缺失或损坏');
        }
      }
      if (wanted.length != files.length ||
          files.keys.any((f) => !wanted.contains(f))) {
        throw const FormatException('备份包含未声明的项目文件');
      }
      return BackupContents._(snapshot, files);
    });
    // Parse original resources before writing anything to the current project.
    for (final row in contents.snapshot.tables['library_resources']!) {
      final preview = resources.inspect(
        contents._files['originals/${row['id']}.bin']!,
        filename: row['filename'] as String,
        kind: ResourceKind.values.byName(row['kind'] as String),
      );
      if (canonicalJson(preview.raw) !=
          canonicalJson(jsonDecode(row['data_json'] as String))) {
        throw const FormatException('ST 原文件与资源记录不一致');
      }
    }
    return contents;
  }

  Future<Novel> restore(
    Uint8List bytes, {
    required String passphrase,
    bool asCopy = true,
    String? expectedFingerprint,
    String? title,
  }) async => restoreContents(
    await read(bytes, passphrase: passphrase),
    asCopy: asCopy,
    expectedFingerprint: expectedFingerprint,
    title: title,
  );

  Future<Novel> restoreContents(
    BackupContents contents, {
    bool asCopy = true,
    String? expectedFingerprint,
    String? title,
    Map<String, dynamic>? syncState,
  }) async {
    final original = contents.snapshot;
    final copied = asCopy ? original.copy(title: title) : null;
    final snapshot = copied?.snapshot ?? original;
    final encrypted = <String, List<int>>{};
    for (final row in original.tables['library_resources']!) {
      final id = row['id'] as String, newId = copied?.ids[id] ?? id;
      encrypted[newId] = await resources.protectOriginal(
        newId,
        contents._files['originals/$id.bin']!,
      );
    }
    // Validate in an isolated database first. Failed import can leave only
    // content-addressed orphan files, never partial visible project records.
    final staging = StoryRepository.memory();
    try {
      await staging.restoreProject(snapshot, encryptedSources: encrypted);
    } finally {
      await staging.close();
    }
    for (final e in contents._files.entries) {
      if (e.key.startsWith('assets/')) {
        await assets.installBackupFile(e.key.substring(7), e.value);
      }
    }
    return repository.restoreProject(
      snapshot,
      encryptedSources: encrypted,
      expectedFingerprint: expectedFingerprint,
      syncState: syncState,
    );
  }
}

final _magic = Uint8List.fromList(ascii.encode('SILLYDRAFT1\n'));
void _validatePassphrase(String phrase) {
  if (phrase.runes.length < 12 || utf8.encode(phrase).length > 1024) {
    throw const FormatException('备份口令至少 12 个字符，最多 1024 字节');
  }
}

Future<SecretKey> _derive(String phrase, List<int> salt) => Pbkdf2(
  macAlgorithm: Hmac.sha256(),
  iterations: 600000,
  bits: 256,
).deriveKeyFromPassword(password: phrase, nonce: salt);
Future<Uint8List> _encrypt(Uint8List bytes, String phrase) async {
  final random = Random.secure(),
      salt = List<int>.generate(16, (_) => random.nextInt(256));
  final aad = [..._magic, ...salt];
  final box = await AesGcm.with256bits().encrypt(
    bytes,
    secretKey: await _derive(phrase, salt),
    aad: aad,
  );
  return Uint8List.fromList([...aad, ...box.concatenation()]);
}

Future<Uint8List> _decrypt(Uint8List bytes, String phrase) async {
  if (bytes.length < _magic.length + 16 + 28 ||
      !_magic.indexed.every((e) => bytes[e.$1] == e.$2) ||
      utf8.encode(phrase).length > 1024) {
    throw const FormatException('不是有效的 SillyDraft 加密备份');
  }
  final prefix = _magic.length + 16;
  try {
    final key = await _derive(phrase, bytes.sublist(_magic.length, prefix));
    final box = SecretBox.fromConcatenation(
      bytes.sublist(prefix),
      nonceLength: 12,
      macLength: 16,
    );
    return Uint8List.fromList(
      await AesGcm.with256bits().decrypt(
        box,
        secretKey: key,
        aad: bytes.sublist(0, prefix),
      ),
    );
  } on SecretBoxAuthenticationError {
    throw const FormatException('备份口令不正确或文件已损坏');
  }
}
