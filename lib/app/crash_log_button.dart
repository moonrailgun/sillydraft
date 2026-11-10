import 'package:flutter/widgets.dart';

import 'crash_logging.dart';
import 'widgets.dart';

/// Also works on the startup error screen, where no library or toaster exists.
class CrashLogButton extends StatefulWidget {
  const CrashLogButton({super.key});

  @override
  State<CrashLogButton> createState() => _CrashLogButtonState();
}

class _CrashLogButtonState extends State<CrashLogButton> {
  bool _opening = false;
  String? _error;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      FButton(
        variant: FButtonVariant.outline,
        mainAxisSize: MainAxisSize.min,
        onPress: _opening
            ? null
            : () async {
                setState(() {
                  _opening = true;
                  _error = null;
                });
                try {
                  await openCrashLogDirectory();
                } catch (error, stack) {
                  recordLocalError(error, stack, source: 'open-log-directory');
                  if (mounted) setState(() => _error = error.toString());
                } finally {
                  if (mounted) setState(() => _opening = false);
                }
              },
        prefix: const Icon(FLucideIcons.folderOpen),
        child: Text(_opening ? '正在打开…' : '打开崩溃日志目录'),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(_error!, style: TextStyle(color: context.theme.colors.error)),
      ],
    ],
  );
}
