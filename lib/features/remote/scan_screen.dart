import 'package:flutter/widgets.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/widgets.dart';

/// Scans one QR code and returns its text.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});
  @override
  State<ScanScreen> createState() => _ScanState();
}

class _ScanState extends State<ScanScreen> {
  bool _done = false;

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: '扫码',
    body: MobileScanner(
      onDetect: (capture) {
        final value = capture.barcodes.firstOrNull?.rawValue;
        if (_done || value == null) return;
        _done = true;
        Navigator.pop(context, value);
      },
      errorBuilder: (context, error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '无法使用相机：${error.errorDetails?.message ?? error.errorCode.name}。可以改用“粘贴链接”。',
          ),
        ),
      ),
    ),
  );
}
