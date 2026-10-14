import 'dart:convert';
import 'dart:io';

import 'package:sillydraft_core/sillydraft_core.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late Uri endpoint;
  var status = 200;
  Object? release;
  setUp(() async {
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint = Uri.parse('http://127.0.0.1:${server.port}/latest');
    server.listen((r) {
      expect(r.headers.value('accept'), 'application/vnd.github+json');
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(release ?? {'message': 'Not Found'}))
        ..close();
    });
  });
  tearDown(() => server.close(force: true));

  Map<String, Object?> releaseOf(String tag) => {
    'tag_name': tag,
    'html_url': 'https://example.test/releases/$tag',
    'body': ' - fix: reader \n',
    'assets': [
      for (final name in [
        'sillydraft-${tag.substring(1)}-android.apk',
        'sillydraft-${tag.substring(1)}-macos.zip',
      ])
        {'name': name, 'browser_download_url': 'https://example.test/$name'},
    ],
  };

  Future<UpdateInfo?> check(String current, {String platform = 'android'}) =>
      checkForUpdate(current: current, platform: platform, endpoint: endpoint);

  test('newer release yields this platform package', () async {
    release = releaseOf('v0.2.0');
    final info = (await check('0.1.9'))!;
    expect(info.version, '0.2.0');
    expect(info.notes, '- fix: reader');
    expect(
      info.downloadUrl,
      'https://example.test/sillydraft-0.2.0-android.apk',
    );
    expect(info.pageUrl, 'https://example.test/releases/v0.2.0');
    expect(
      (await check('0.1.9', platform: 'macos'))!.downloadUrl,
      endsWith('-macos.zip'),
    );
  });

  test('versions compare numerically, not as text', () async {
    release = releaseOf('v0.10.0');
    expect((await check('0.9.9'))?.version, '0.10.0');
    expect(await check('0.10.0'), isNull);
    expect(await check('1.0.0'), isNull);
  });

  test('missing package falls back to the release page', () async {
    release = releaseOf('v1.0.0');
    final info = (await check('0.1.0', platform: 'windows'))!;
    expect(info.downloadUrl, info.pageUrl);
  });

  test('unrecognised tags and no release are not updates', () async {
    release = releaseOf('v1.0.0')..['tag_name'] = 'nightly';
    expect(await check('0.1.0'), isNull);
    release = releaseOf('v1.0.0-beta.1');
    expect(await check('0.1.0'), isNull);
    status = 404;
    release = null;
    expect(await check('0.1.0'), isNull);
  });

  test('server errors are thrown', () async {
    status = 500;
    release = {'message': 'boom'};
    await expectLater(
      check('0.1.0'),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('500'),
        ),
      ),
    );
  });
}
