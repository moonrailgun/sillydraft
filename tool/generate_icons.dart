// Regenerate the platform icons: flutter test tool/generate_icons.dart
// The mark is drawn as vectors, without fonts or external image dependencies.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as raster;

Future<Uint8List> icon(int size, {bool rounded = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder)..scale(size / 256);
  final purple = ui.Paint()..color = const ui.Color(0xff7060ad);
  final paper = ui.Paint()..color = const ui.Color(0xfffffcf4);
  if (rounded) {
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(
        const ui.Rect.fromLTWH(12, 12, 232, 232),
        const ui.Radius.circular(52),
      ),
      purple,
    );
  } else {
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 256, 256), purple);
  }
  canvas.drawPath(
    ui.Path()
      ..moveTo(48, 91)
      ..quadraticBezierTo(88, 78, 121, 101)
      ..lineTo(121, 196)
      ..quadraticBezierTo(89, 174, 48, 185)
      ..close(),
    paper,
  );
  canvas.drawPath(
    ui.Path()
      ..moveTo(135, 101)
      ..quadraticBezierTo(164, 86, 208, 91)
      ..lineTo(208, 185)
      ..quadraticBezierTo(169, 178, 135, 196)
      ..close(),
    paper,
  );
  final line = ui.Paint()
    ..color = const ui.Color(0xffb6acd5)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 5
    ..strokeCap = ui.StrokeCap.round;
  for (final y in [118.0, 140.0, 162.0]) {
    canvas.drawPath(
      ui.Path()
        ..moveTo(66, y)
        ..quadraticBezierTo(83, y - 2, 103, y + 7),
      line,
    );
    canvas.drawPath(
      ui.Path()
        ..moveTo(153, y + 7)
        ..quadraticBezierTo(170, y, 189, y),
      line,
    );
  }
  canvas.drawPath(
    ui.Path()
      ..moveTo(187, 37)
      ..lineTo(195, 56)
      ..lineTo(214, 64)
      ..lineTo(195, 72)
      ..lineTo(187, 91)
      ..lineTo(179, 72)
      ..lineTo(160, 64)
      ..lineTo(179, 56)
      ..close(),
    ui.Paint()..color = const ui.Color(0xfff0cc87),
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
  testWidgets('regenerate native application icons from the vector mark', (
    tester,
  ) async {
    await tester.runAsync(() async {
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
            await icon((points * scale).round(), rounded: platform == 'macos'),
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
        ).writeAsBytes(await icon(entry.value));
      }
      final sizes = [16, 32, 48, 256];
      final images = [
        for (final size in sizes) await icon(size, rounded: true),
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
          .writeAsBytes(await icon(256, rounded: true));
    });
  });
}
