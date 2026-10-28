// Regenerate the platform icons: flutter test tool/generate_icons.dart
// Uses the PNG export of assets/branding/logo.svg; no fonts are required.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

Future<Uint8List> icon(
  ui.Image source,
  int size, {
  bool rounded = false,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(size / 256);
  if (!rounded) {
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 256, 256),
      ui.Paint()..color = const ui.Color(0xffffffff),
    );
  }
  canvas.drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    rounded
        ? const ui.Rect.fromLTWH(12, 12, 232, 232)
        : const ui.Rect.fromLTWH(0, 0, 256, 256),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  final png = data!.buffer.asUint8List();
  // App Store icons must have no alpha channel, even when every pixel is opaque.
  return rounded
      ? png
      : raster.encodePng(raster.decodePng(png)!.convert(numChannels: 3));
}

void main() {
  testWidgets('regenerate native application icons from the approved logo', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(
        await File('assets/branding/logo.png').readAsBytes(),
      );
      final source = (await codec.getNextFrame()).image;
      codec.dispose();
      addTearDown(source.dispose);
      expect(source.width, greaterThanOrEqualTo(1024));
      expect(source.height, source.width);

      // Check both platform treatments before replacing the icon files.
      final rounded = raster.decodePng(await icon(source, 64, rounded: true))!;
      expect(rounded.getPixel(0, 0).a, 0);
      expect(rounded.getPixel(32, 6).a, 255);
      final opaque = raster.decodePng(await icon(source, 64))!;
      expect(opaque.numChannels, 3);
      expect(opaque.getPixel(0, 0).r, 255);
      expect(opaque.getPixel(0, 0).g, 255);
      expect(opaque.getPixel(0, 0).b, 255);

      for (final platform in ['ios', 'macos']) {
        final directory = '$platform/Runner/Assets.xcassets/AppIcon.appiconset';
        final manifest = jsonDecode(
          await File('$directory/Contents.json').readAsString(),
        ) as Map;
        for (final entry in manifest['images'] as List) {
          if (entry['filename'] == null) continue;
          final points = double.parse(
            (entry['size'] as String).split('x').first,
          );
          final scale = double.parse(
            (entry['scale'] as String).replaceAll('x', ''),
          );
          await File('$directory/${entry['filename']}').writeAsBytes(
            await icon(
              source,
              (points * scale).round(),
              rounded: platform == 'macos',
            ),
          );
        }
      }
      for (final entry in {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      }.entries) {
        await File(
          'android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png',
        ).writeAsBytes(await icon(source, entry.value, rounded: true));
      }
      final sizes = [16, 32, 48, 256];
      final images = [
        for (final size in sizes) await icon(source, size, rounded: true),
      ];
      final header = ByteData(6 + 16 * sizes.length)
        ..setUint16(2, 1, Endian.little)
        ..setUint16(4, sizes.length, Endian.little);
      var offset = header.lengthInBytes;
      for (var i = 0; i < sizes.length; i++) {
        final entry = 6 + i * 16;
        header.setUint8(entry, sizes[i] % 256);
        header.setUint8(entry + 1, sizes[i] % 256);
        header.setUint16(entry + 4, 1, Endian.little);
        header.setUint16(entry + 6, 32, Endian.little);
        header.setUint32(entry + 8, images[i].length, Endian.little);
        header.setUint32(entry + 12, offset, Endian.little);
        offset += images[i].length;
      }
      await File('windows/runner/resources/app_icon.ico').writeAsBytes(
        (BytesBuilder()
              ..add(header.buffer.asUint8List())
              ..add(images.expand((e) => e).toList()))
            .takeBytes(),
      );
      await File('linux/runner/sillydraft.png')
          .writeAsBytes(await icon(source, 256, rounded: true));
    });
  });
}
