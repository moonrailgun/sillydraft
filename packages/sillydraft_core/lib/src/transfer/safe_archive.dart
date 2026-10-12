import 'dart:typed_data';

import 'package:archive/archive.dart';

/// No extraction to disk. Validate the directory before decompressing entries.
Map<String, Uint8List> readSafeZip(
  Uint8List bytes, {
  int maxExpandedBytes = 128 * 1024 * 1024,
  int maxEntries = 2048,
}) {
  try {
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.filePosition < 0 ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.fileHeaders.length !=
            directory.totalCentralDirectoryEntries ||
        directory.fileHeaders.length > maxEntries) {
      throw const FormatException('ZIP 目录损坏或文件数量超限');
    }
    var expanded = 0;
    final seen = <String>{};
    for (final header in directory.fileHeaders) {
      final name = header.filename;
      validateArchivePath(name, directory: name.endsWith('/'));
      if (!seen.add(name)) throw const FormatException('ZIP 中有重复文件名');
      if (header.generalPurposeBitFlag & 1 != 0 ||
          ![0, 8].contains(header.compressionMethod) ||
          (header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
          header.file?.filename != name) {
        throw const FormatException('不支持加密、链接或此压缩格式');
      }
      expanded += header.uncompressedSize;
      if (header.uncompressedSize < 0 || expanded > maxExpandedBytes) {
        throw const FormatException('ZIP 解压大小超出限制');
      }
    }
    final result = <String, Uint8List>{};
    for (final header in directory.fileHeaders) {
      if (header.filename.endsWith('/')) continue;
      final file = header.file!;
      final content = file.getStream().toUint8List();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw const FormatException('ZIP 文件校验失败');
      }
      result[header.filename] = Uint8List.fromList(content);
    }
    return result;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('无法读取 ZIP 文件');
  }
}

void validateArchivePath(String name, {bool directory = false}) {
  final path = directory && name.endsWith('/')
      ? name.substring(0, name.length - 1)
      : name;
  if (path.isEmpty ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.contains(':') ||
      path.contains('\x00') ||
      path.split('/').any((p) => p == '..' || p == '.' || p.isEmpty)) {
    throw const FormatException('资源路径不安全');
  }
}
