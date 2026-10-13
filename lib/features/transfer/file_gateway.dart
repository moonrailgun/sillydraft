import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sillydraft_core/sillydraft_core.dart';

abstract interface class TransferFileGateway {
  Future<Uint8List?> chooseBackup();
  Future<bool> save(BuildContext context, PublicationFile file);
}

final transferFilesProvider = Provider<TransferFileGateway>(
  (_) => PlatformTransferFiles(),
);

final class PlatformTransferFiles implements TransferFileGateway {
  @override
  Future<Uint8List?> chooseBackup() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'SillyDraft 项目备份',
          extensions: ['sillydraft'],
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > ProjectBackup.maxBytes) {
      throw const FormatException('备份超过 128 MB');
    }
    return file.readAsBytes();
  }

  @override
  Future<bool> save(BuildContext context, PublicationFile file) async {
    if (Platform.isAndroid || Platform.isIOS) {
      final box = context.findRenderObject() as RenderBox?;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              file.bytes,
              mimeType: file.mimeType,
              name: file.filename,
            ),
          ],
          fileNameOverrides: [file.filename],
          sharePositionOrigin: box == null
              ? const Rect.fromLTWH(0, 0, 1, 1)
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      return result.status != ShareResultStatus.dismissed;
    }
    final location = await getSaveLocation(suggestedName: file.filename);
    if (location == null) return false;
    if (Platform.isMacOS) {
      await const MethodChannel('app.sillydraft/files').invokeMethod<void>(
        'saveAtomic',
        {'path': location.path, 'bytes': file.bytes},
      );
      return true;
    }
    final target = File(location.path);
    final staging = await Directory.systemTemp.createTemp('sillydraft-export-');
    try {
      final prepared = File('${staging.path}/export');
      await prepared.writeAsBytes(file.bytes, flush: true);
      // Copy to a sibling before rename so an interrupted write cannot truncate
      // an existing user-selected document, even across different volumes.
      final sibling = File(
        '${target.path}.sillydraft-${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await prepared.copy(sibling.path);
        await sibling.rename(target.path);
      } finally {
        if (await sibling.exists()) await sibling.delete();
      }
      return true;
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
