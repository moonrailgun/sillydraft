import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/services.dart';
import '../../app/widgets.dart';

final _assetFileProvider =
    FutureProvider.family<File, ({String id, bool thumbnail})>((
      ref,
      key,
    ) async {
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
    this.height,
    this.width,
    this.label = '小说插图',
  });
  final String assetId, label;
  final bool thumbnail;
  final BoxFit fit;
  final double? height, width;
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_assetFileProvider((id: assetId, thumbnail: thumbnail)))
      .when(
        data: (file) => Image.file(
          file,
          fit: fit,
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
