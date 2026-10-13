import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../model/asset.dart';
import '../storage/story_repository.dart';
import '../st/card_importer.dart';
import '../model/resource.dart';
import '../st/resource_library.dart';

final class AssetLibrary {
  AssetLibrary({required this.repository, required this.directory});
  final StoryRepository repository;
  final Directory directory;
  static const maxBytes = 32 * 1024 * 1024;
  static const maxPixels = 16 * 1024 * 1024;

  /// Run at startup, before any import or generation can prepare new files.
  /// The age guard retains writes left by another recently running process.
  Future<int> pruneOrphans() async {
    if (!await directory.exists()) return 0;
    final referenced = await repository.assetFileNames();
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    final ownedName = RegExp(
      r'^(?:[a-f0-9]{64}\.(?:png|jpg)|\.[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\.tmp)$',
    );
    var removed = 0;
    await for (final entry in directory.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is! File ||
          !ownedName.hasMatch(name) ||
          referenced.contains(name)) {
        continue;
      }
      if ((await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete();
        removed++;
      }
    }
    return removed;
  }

  Future<({List<StoryAsset> assets, List<String> warnings})> importCardArtwork({
    required String branchId,
    required String resourceId,
    required ResourceLibrary resources,
  }) async {
    final resource = await repository.getResource(resourceId);
    if (resource.kind != ResourceKind.character) {
      throw const FormatException('请选择角色卡');
    }
    final source = await resources.original(resourceId);
    final card = const CardImporter().decode(source, resource.filename);
    final candidates = <String, Uint8List>{
      if (source.length >= 8 &&
          source[0] == 137 &&
          source[1] == 80 &&
          source[2] == 78 &&
          source[3] == 71)
        'portrait.png': source,
      for (final e in card.assets.entries)
        if ([
          '.png',
          '.jpg',
          '.jpeg',
          '.webp',
        ].contains(p.extension(e.key).toLowerCase()))
          e.key: e.value,
    };
    final branch = await repository.getBranch(branchId);
    final existing = await repository.listAssets(
      branch.novelId,
      includeArchived: true,
    );
    final imported = <StoryAsset>[], warnings = <String>[];
    for (final e in candidates.entries) {
      final found = existing
          .where(
            (a) =>
                a.metadata['cardResourceId'] == resourceId &&
                a.metadata['cardAssetPath'] == e.key,
          )
          .firstOrNull;
      if (found != null) {
        imported.add(found);
        continue;
      }
      try {
        imported.add(
          await importImage(
            branchId: branch.id,
            name: '${card.name} · ${p.basename(e.key)}',
            bytes: e.value,
            purpose: AssetPurpose.reference,
            metadata: {
              'origin': 'characterCard',
              'cardResourceId': resourceId,
              'cardAssetPath': e.key,
            },
          ),
        );
      } on FormatException catch (error) {
        warnings.add('${p.basename(e.key)}：${error.message}');
      }
    }
    return (assets: imported, warnings: warnings);
  }

  Future<PreparedAsset> prepare(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('图片大小须在 32 MB 以内');
    }
    final normalized = await Isolate.run(() => _normalize(bytes));
    final hash = sha256.convert(normalized.png).toString(),
        thumb = sha256.convert(normalized.thumbnail).toString();
    await _writeFile(hash, 'png', normalized.png);
    await _writeFile(thumb, 'jpg', normalized.thumbnail);
    return PreparedAsset(
      hash: hash,
      thumbnailHash: thumb,
      width: normalized.width,
      height: normalized.height,
      byteLength: normalized.png.length,
    );
  }

  /// Installs a previously verified portable asset without changing its hash.
  /// Existing files are checked, never blindly overwritten.
  Future<void> installBackupFile(String name, Uint8List bytes) async {
    if (!RegExp(r'^[a-f0-9]{64}\.(png|jpg)$').hasMatch(name) ||
        bytes.isEmpty ||
        bytes.length > maxBytes) {
      throw const FormatException('备份图片文件无效');
    }
    final hash = name.substring(0, 64);
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('备份图片校验失败');
    }
    await _writeFile(hash, name.substring(65), bytes);
  }

  Future<StoryAsset> importImage({
    required String branchId,
    required String name,
    required Uint8List bytes,
    AssetPurpose purpose = AssetPurpose.illustration,
    String? sourceChapterId,
    String? sourceRevisionId,
    Map<String, dynamic> metadata = const {},
  }) async {
    await repository.getBranch(branchId);
    final prepared = await prepare(bytes);
    return repository.storeAsset(
      branchId: branchId,
      name: name,
      prepared: prepared,
      purpose: purpose,
      sourceChapterId: sourceChapterId,
      sourceRevisionId: sourceRevisionId,
      metadata: metadata,
    );
  }

  File _path(String hash, String extension) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        !['png', 'jpg'].contains(extension)) {
      throw const FormatException('无效的资源路径');
    }
    return File(p.join(directory.path, '$hash.$extension'));
  }

  Future<void> _writeFile(
    String hash,
    String extension,
    Uint8List bytes,
  ) async {
    await directory.create(recursive: true);
    final target = _path(hash, extension);
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      if (sha256.convert(await target.readAsBytes()).toString() != hash) {
        throw const FormatException('已有图片文件校验失败');
      }
      return;
    }
    if (type != FileSystemEntityType.notFound) {
      throw const FormatException('资源路径不是普通文件');
    }
    final staging = File(p.join(directory.path, '.${const Uuid().v4()}.tmp'));
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(target.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }

  Future<File> file(String assetId, {bool thumbnail = false}) async {
    final asset = await repository.getAsset(assetId);
    final target = _path(
      thumbnail ? asset.thumbnailHash : asset.hash,
      thumbnail ? 'jpg' : 'png',
    );
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('图片文件缺失或路径无效');
    }
    if (await target.length() > maxBytes) {
      throw const FormatException('图片文件大小异常');
    }
    return target;
  }

  Future<Uint8List> read(String assetId, {bool thumbnail = false}) async {
    final asset = await repository.getAsset(assetId),
        target = await file(assetId, thumbnail: thumbnail);
    final bytes = await target.readAsBytes();
    if (sha256.convert(bytes).toString() !=
        (thumbnail ? asset.thumbnailHash : asset.hash)) {
      throw const FormatException('图片文件已损坏');
    }
    return bytes;
  }
}

({Uint8List png, Uint8List thumbnail, int width, int height}) _normalize(
  Uint8List bytes,
) {
  try {
    img.Decoder? decoder;
    for (final candidate in <img.Decoder>[
      img.PngDecoder(),
      img.JpegDecoder(),
      img.WebPDecoder(),
    ]) {
      if (candidate.isValidFile(bytes)) {
        decoder = candidate;
        break;
      }
    }
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width < 1 ||
        info.height < 1 ||
        info.width > 8192 ||
        info.height > 8192 ||
        info.width * info.height > AssetLibrary.maxPixels ||
        decoder!.numFrames() != 1) {
      throw const FormatException('支持静态 PNG、JPEG、WebP，最多 1600 万像素');
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) throw const FormatException('无法解码图片');
    // Copy pixel data into a fresh image; card text chunks, EXIF and other
    // metadata never leak from encrypted character sources into public assets.
    final oriented = img.bakeOrientation(decoded);
    final clean = img.Image.fromBytes(
      width: oriented.width,
      height: oriented.height,
      bytes: oriented.getBytes(order: img.ChannelOrder.rgba).buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    final png = img.encodePng(clean);
    if (png.length > AssetLibrary.maxBytes) {
      throw const FormatException('标准化后的图片超过 32 MB，请缩小图片');
    }
    final thumb = img.copyResize(
      clean,
      width: clean.width >= clean.height ? 480 : null,
      height: clean.height > clean.width ? 480 : null,
      maintainAspect: true,
    );
    return (
      png: png,
      thumbnail: img.encodeJpg(thumb, quality: 85),
      width: clean.width,
      height: clean.height,
    );
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('图片损坏或格式不受支持');
  }
}
