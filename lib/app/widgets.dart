import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    super.key,
    required this.value,
    required this.builder,
    this.retry,
  });
  final AsyncValue<T> value;
  final Widget Function(T) builder;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => value.when(
    skipLoadingOnRefresh: true,
    skipLoadingOnReload: true,
    data: builder,
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, _) => ErrorPane(message: error.toString(), retry: retry),
  );
}

class ErrorPane extends StatelessWidget {
  const ErrorPane({super.key, required this.message, this.retry});
  final String message;
  final VoidCallback? retry;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 32),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (retry != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: FilledButton(onPressed: retry, child: const Text('重试')),
            ),
        ],
      ),
    ),
  );
}

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(error.toString()),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<String?> askText(
  BuildContext context, {
  required String title,
  String initial = '',
  String label = '名称',
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _TextDialog(title: title, initial: initial, label: label),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.label,
  });
  final String title, initial, label;
  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(labelText: widget.label),
      onSubmitted: (value) {
        if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (controller.text.trim().isNotEmpty) {
            Navigator.pop(context, controller.text.trim());
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}

String countCharacters(String text) =>
    '${text.replaceAll(RegExp(r'\s'), '').runes.length}';
String dateLabel(DateTime date) =>
    '${date.toLocal().month}月${date.toLocal().day}日';
