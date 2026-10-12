import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'CLI survives SIGKILL with partial output and does not resubmit upstream',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sillydraft-runner-process-',
      );
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      var calls = 0;
      upstream.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {
                'delta': {'content': '已持久化的片段'},
                'finish_reason': null,
              },
            ],
          })}\n\n',
        );
        await request.response.flush();
        // The child is deliberately killed while its upstream stream is open.
      });
      final profile = File('${directory.path}/profiles.json');
      await profile.writeAsString(
        jsonEncode({
          'profiles': [
            {
              'id': 'writer',
              'name': 'Test writer',
              'baseUrl': 'http://127.0.0.1:${upstream.port}/v1',
              'model': 'test',
              'apiKeyEnv': 'TEST_UPSTREAM_KEY',
            },
          ],
        }),
      );
      final processes = <Process>[];
      addTearDown(() async {
        for (final process in processes) {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
        client.close(force: true);
        await upstream.close(force: true);
        await directory.delete(recursive: true);
      });
      Future<(Process, Uri)> start() async {
        final process = await Process.start(
          Platform.resolvedExecutable,
          [
            'run',
            'bin/sillydraft_server.dart',
            '--config',
            profile.path,
            '--data',
            '${directory.path}/data',
            '--port',
            '0',
          ],
          environment: {
            'SILLYDRAFT_RUNNER_TOKEN': 'test-process-token-123',
            'TEST_UPSTREAM_KEY': 'never-expose-this-key',
          },
        );
        processes.add(process);
        final listening = Completer<Uri>();
        final output = StringBuffer();
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              output.writeln(line);
              const prefix = 'SillyDraft runner listening on ';
              if (line.startsWith(prefix) && !listening.isCompleted) {
                listening.complete(Uri.parse(line.substring(prefix.length)));
              }
            });
        process.stderr.transform(utf8.decoder).listen(output.write);
        unawaited(
          process.exitCode.then((code) {
            if (!listening.isCompleted) {
              listening.completeError(
                StateError('Runner exited $code: $output'),
              );
            }
          }),
        );
        return (
          process,
          await listening.future.timeout(const Duration(seconds: 30)),
        );
      }

      Future<Map<String, dynamic>> request(
        Uri uri,
        String method,
        String path, [
        Object? data,
      ]) async {
        final req = await client.openUrl(method, uri.resolve(path));
        req.headers.set('Authorization', 'Bearer test-process-token-123');
        if (data != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(data));
        }
        final response = await req.close();
        expect(response.statusCode, inInclusiveRange(200, 299));
        return jsonDecode(await utf8.decoder.bind(response).join())
            as Map<String, dynamic>;
      }

      final (first, uri) = await start();
      await request(uri, 'POST', 'v1/jobs', {
        'id': 'crash-recovery',
        'profile': 'writer',
        'kind': 'text',
        'request': {
          'messages': [
            {'role': 'user', 'content': 'continue'},
          ],
        },
      });
      var found = false;
      for (var i = 0; i < 200; i++) {
        final job = await request(uri, 'GET', 'v1/jobs/crash-recovery');
        if (job['text'] == '已持久化的片段') {
          found = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        found,
        isTrue,
        reason:
            'upstream calls: $calls; job: ${await request(uri, "GET", "v1/jobs/crash-recovery")}',
      );
      expect(first.kill(ProcessSignal.sigkill), isTrue);
      await first.exitCode;
      final (second, restarted) = await start();
      final recovered = await request(
        restarted,
        'GET',
        'v1/jobs/crash-recovery',
      );
      expect(recovered['status'], 'interrupted');
      expect(recovered['text'], '已持久化的片段');
      expect(calls, 1);
      expect(jsonEncode(recovered), isNot(contains('never-expose-this-key')));
      second.kill(ProcessSignal.sigterm);
      expect(await second.exitCode.timeout(const Duration(seconds: 10)), 0);
    },
    skip: Platform.isWindows ? 'SIGKILL contract is Unix-specific' : false,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
