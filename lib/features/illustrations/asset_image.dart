import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';
import '../remote/library_switcher.dart';

/// Read again when a remote library's link comes back or drops, so a
/// download that failed meanwhile is tried again; this device's own library
/// never changes link.
void _watchLink(Ref ref) =>
    ref.watch(remoteStatusProvider.select((s) => s.value?.connected ?? true));

final _assetFileProvider =
    FutureProvider.family<File, ({String id, bool thumbnail})>((
      ref,
      key,
    ) async {
      _watchLink(ref);
      final library = ref.watch(servicesProvider).assets;
      if (library == null) throw const FormatException('本地图片目录尚未配置');
      return library.file(key.id, thumbnail: key.thumbnail);
    });

class AssetImageView extends ConsumerWidget {
  const AssetImageView({
    super.key,
    required this.assetId,
    this.thumbnail = false,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    this.height,
    this.width,
    this.label = '小说插图',
  });
  final String assetId, label;
  final bool thumbnail;
  final BoxFit fit;
  final Alignment alignment;
  final double? height, width;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_assetFileProvider((id: assetId, thumbnail: thumbnail)))
      .when(
        // A re-read after a link change, even one that fails while the link
        // is down, keeps the picture shown.
        skipLoadingOnReload: true,
        skipError: true,
        data: (file) => Image.file(
          file,
          fit: fit,
          alignment: alignment,
          height: height,
          width: width,
          cacheWidth: thumbnail ? 480 : 2048,
          semanticLabel: label,
          errorBuilder: (_, _, _) => _missing(context),
        ),
        loading: () => SizedBox(
          height: height ?? 160,
          width: width,
          child: const Center(child: FCircularProgress()),
        ),
        error: (_, _) => _missing(context),
      );
  Widget _missing(BuildContext context) => SizedBox(
    height: height ?? 100,
    width: width,
    child: const Center(child: Text('图片暂不可用')),
  );
}

class LocalImageEmbedBuilder extends EmbedBuilder {
  const LocalImageEmbedBuilder();
  @override
  String get key => 'image';
  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final value = embedContext.node.value.data;
    if (value is! String || !value.startsWith('asset:')) {
      return const Text('请从插图库导入图片');
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: AssetImageView(assetId: value.substring(6), height: 300),
    );
  }
}

final _hashFileProvider =
    FutureProvider.family<File, ({String hash, bool thumbnail})>((
      ref,
      key,
    ) async {
      _watchLink(ref);
      final library = ref.watch(servicesProvider).assets;
      if (library == null) throw const FormatException('本地图片目录尚未配置');
      return library.fileForHash(key.hash, thumbnail: key.thumbnail);
    });

/// A stored image by content hash, such as a persona's reference picture.
class HashImageView extends ConsumerWidget {
  const HashImageView({
    super.key,
    required this.hash,
    this.thumbnail = false,
    this.fit = BoxFit.contain,
    this.height,
    this.width,
    this.label = '图片',
  });
  final String hash, label;
  final bool thumbnail;
  final BoxFit fit;
  final double? height, width;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_hashFileProvider((hash: hash, thumbnail: thumbnail)))
      .when(
        // A re-read after a link change, even one that fails while the link
        // is down, keeps the picture shown.
        skipLoadingOnReload: true,
        skipError: true,
        data: (file) => Image.file(
          file,
          fit: fit,
          height: height,
          width: width,
          semanticLabel: label,
          errorBuilder: (_, _, _) => _missing(),
        ),
        loading: () => SizedBox(
          height: height,
          width: width,
          child: const Center(child: FCircularProgress()),
        ),
        error: (_, _) => _missing(),
      );
  Widget _missing() => SizedBox(
    height: height,
    width: width,
    child: const Center(child: Text('图片暂不可用')),
  );
}
