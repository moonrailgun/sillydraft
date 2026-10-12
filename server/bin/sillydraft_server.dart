import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:sillydraft_server/runner_server.dart';

const usage = '''SillyDraft personal remote runner
dart run bin/sillydraft_server.dart --config model-profiles.json
  [--data ./runner-data] [--host 127.0.0.1] [--port 8787] [--max-concurrent 2]
Set SILLYDRAFT_RUNNER_TOKEN (at least 16 characters) in the environment.
Upstream API keys are read from each profile's apiKeyEnv environment variable.
''';

Future<void> main(List<String> args) async {
  if (args.contains('--help')) {
    stdout.write(usage);
    return;
  }
  RunnerServer? server;
  try {
    final options = <String, String>{};
    for (var i = 0; i < args.length; i += 2) {
      if (i + 1 >= args.length ||
          ![
            '--config',
            '--data',
            '--host',
            '--port',
            '--max-concurrent',
          ].contains(args[i]) ||
          options.containsKey(args[i])) {
        throw const FormatException('Invalid command line');
      }
      options[args[i]] = args[i + 1];
    }
    if (!options.containsKey('--config')) {
      stderr.write(usage);
      exitCode = 64;
      return;
    }
    final file = File(options['--config']!);
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('Profile file too large');
    }
    final document =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final profiles = <String, ModelConnection>{};
    final keys = <String, String>{};
    final hosts = <String, List<String>>{};
    for (final raw in document['profiles'] as List) {
      final profile = Map<String, dynamic>.from(raw as Map);
      if (profile.containsKey('apiKey')) {
        throw const FormatException('Use apiKeyEnv');
      }
      final connection = ModelConnection.fromJson({
        ...profile,
        'protocol': 'openAICompatible',
      });
      if (profiles.containsKey(connection.id)) {
        throw const FormatException('Duplicate profile');
      }
      final variable = profile['apiKeyEnv'] as String?;
      if (variable != null &&
          !RegExp(r'^[A-Z_][A-Z0-9_]*$').hasMatch(variable)) {
        throw const FormatException('Invalid environment variable');
      }
      final key = variable == null ? '' : Platform.environment[variable];
      if (key == null || (variable != null && key.isEmpty)) {
        throw const FormatException('Missing upstream credential');
      }
      profiles[connection.id] = connection;
      keys[connection.id] = key;
      hosts[connection.id] = (profile['imageDownloadHosts'] as List? ?? [])
          .cast<String>();
    }
    server = await RunnerServer.open(
      directory: Directory(options['--data'] ?? 'runner-data'),
      token: Platform.environment['SILLYDRAFT_RUNNER_TOKEN'] ?? '',
      profiles: profiles,
      providerFactory: (config) async => OpenAICompatibleProvider(
        config: config,
        apiKey: keys[config.id] ?? '',
      ),
      imageProviderFactory: (config) async =>
          OpenAIImageProvider(config: config, apiKey: keys[config.id] ?? ''),
      imageDownloadHosts: hosts,
      address: InternetAddress(options['--host'] ?? '127.0.0.1'),
      port: int.parse(options['--port'] ?? '8787'),
      maxConcurrent: int.parse(options['--max-concurrent'] ?? '2'),
    );
    stdout.writeln('SillyDraft runner listening on ${server.uri}');
    final stopped = Completer<void>();
    final subscriptions = <StreamSubscription<ProcessSignal>>[];
    for (final signal in [
      ProcessSignal.sigint,
      if (!Platform.isWindows) ProcessSignal.sigterm,
    ]) {
      subscriptions.add(
        signal.watch().listen((_) {
          if (!stopped.isCompleted) stopped.complete();
        }),
      );
    }
    await stopped.future;
    await server.close();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  } catch (_) {
    stderr.writeln(
      'Runner could not start or shut down. Check config, required environment variables, address and data-directory access.',
    );
    if (server != null) await server.close();
    exitCode = 1;
  }
}
