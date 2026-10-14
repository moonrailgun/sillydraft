import 'dart:io';

import 'package:dio/dio.dart';

/// A newer published release than the running app.
final class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.downloadUrl,
    required this.pageUrl,
  });

  final String version;
  final String notes;

  /// This platform's package, or [pageUrl] when the release has none.
  final String downloadUrl;
  final String pageUrl;
}

/// GitHub omits drafts and prereleases here, so a release whose builds have
/// not all succeeded (still a draft, see `.github/workflows/release.yml`) is
/// never offered.
final latestReleaseUrl = Uri.parse(
  'https://api.github.com/repos/moonrailgun/sillydraft/releases/latest',
);

/// Asset name endings uploaded by the release workflow, keyed by
/// `Platform.operatingSystem`.
const releaseAssetSuffixes = {
  'android': '-android.apk',
  'macos': '-macos.zip',
  'windows': '-windows-x64.zip',
  'linux': '-linux-x64.tar.gz',
};

/// The latest release when it is newer than [current] (`major.minor.patch`),
/// otherwise null. Failures throw an [HttpException] or [FormatException]
/// whose message is shown as is.
Future<UpdateInfo?> checkForUpdate({
  required String current,
  required String platform,
  Uri? endpoint,
}) async {
  final client = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'accept': 'application/vnd.github+json'},
      // 404: the repository has no published release yet.
      validateStatus: (status) => status == 200 || status == 404,
    ),
  );
  try {
    final Response<Object?> response;
    try {
      response = await client.getUri(endpoint ?? latestReleaseUrl);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      throw HttpException(
        status == null ? '无法连接 GitHub' : 'GitHub 返回 HTTP $status',
      );
    }
    if (response.statusCode == 404) return null;
    final json = response.data;
    if (json is! Map) throw const FormatException('发布信息格式无效');
    final tag = json['tag_name'], page = json['html_url'];
    final remote = tag is String && tag.startsWith('v')
        ? _parse(tag.substring(1))
        : null;
    final local = _parse(current);
    if (remote == null || local == null || !_newer(remote, local)) return null;
    if (page is! String) throw const FormatException('发布信息缺少页面地址');
    final suffix = releaseAssetSuffixes[platform];
    final asset = suffix == null
        ? null
        : (json['assets'] as List? ?? const []).whereType<Map>().where((a) {
            final name = a['name'];
            return name is String && name.endsWith(suffix);
          }).firstOrNull;
    final download = asset?['browser_download_url'];
    return UpdateInfo(
      version: remote.join('.'),
      notes: (json['body'] as String? ?? '').trim(),
      downloadUrl: download is String ? download : page,
      pageUrl: page,
    );
  } finally {
    client.close();
  }
}

List<int>? _parse(String version) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(version);
  return match == null
      ? null
      : [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
}

bool _newer(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
