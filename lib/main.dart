import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    runApp(SillyDraftApp(services: await AppServices.open()));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 40),
                  const SizedBox(height: 20),
                  const Text('暂时无法打开本地资料库'),
                  const SizedBox(height: 12),
                  Text(error.toString(), textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  FilledButton(onPressed: main, child: const Text('重试')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
