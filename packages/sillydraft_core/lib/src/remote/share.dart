import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../agent/skills.dart';
import '../assets/asset_library.dart';
import '../model/persona.dart';
import '../model/resource.dart';
import '../providers/provider.dart';
import '../st/import_types.dart';
import '../st/resource_library.dart';
import '../storage/story_repository.dart';
import 'links.dart';
import 'tls.dart';

/// Turns the cast and lookup errors of malformed received data into the
/// [FormatException] callers show to the user.
T _parsed<T>(T Function() parse) {
  try {
    return parse();
  } on TypeError {
    throw const FormatException('分享内容格式有误');
  } on ArgumentError {
    throw const FormatException('分享内容格式有误');
  }
}

Future<T> _parsedAsync<T>(Future<T> Function() parse) async {
  try {
    return await parse();
  } on TypeError {
    throw const FormatException('分享内容格式有误');
  } on ArgumentError {
    throw const FormatException('分享内容格式有误');
  }
}

enum ShareKind { resource, skill, persona, connection }

/// One item handed from one device to another: what a share link fetches.
final class SharePayload {
  SharePayload({required this.kind, required this.name, required this.data});

  static const format = 1;

  factory SharePayload.fromJson(Map<String, dynamic> json) =>
      _parsed(() => SharePayload._fromJson(json));

  factory SharePayload._fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const FormatException('分享内容来自不兼容的版本，请把两台设备升级到同一版本');
    }
    final kind =
        ShareKind.values.asNameMap()[json['kind']] ??
        (throw const FormatException('不认识的分享类型，请把两台设备升级到同一版本'));
    return SharePayload(
      kind: kind,
      name: json['name'] as String,
      data: jsonObject(json['data'], 'data'),
    );
  }

  final ShareKind kind;
  final String name;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {
    'format': format,
    'kind': kind.name,
    'name': name,
    'data': data,
  };
}

/// The shares a host hands out: each token fetches its payload once, within
/// its lifetime, until its page closes it.
final class ShareRegistry {
  final _open =
      <
        String,
        ({SharePayload payload, DateTime expires, Completer<void> received})
      >{};

  ShareTicket open(
    SharePayload payload, {
    Duration lifetime = const Duration(minutes: 10),
  }) {
    final token = randomSecret(), received = Completer<void>();
    _open[token] = (
      payload: payload,
      expires: DateTime.now().add(lifetime),
      received: received,
    );
    return ShareTicket._(this, token, received.future);
  }

  /// The payload for [token], used up by this call; null when unknown,
  /// expired or taken.
  SharePayload? take(String token) {
    final entry = _open.remove(token);
    if (entry == null || !entry.expires.isAfter(DateTime.now())) return null;
    entry.received.complete();
    return entry.payload;
  }

  bool get isEmpty {
    _open.removeWhere((_, e) => !e.expires.isAfter(DateTime.now()));
    return _open.isEmpty;
  }
}

final class ShareTicket {
  ShareTicket._(this._registry, this.token, this.received);
  final ShareRegistry _registry;
  final String token;

  /// Completes once a device has fetched the payload.
  final Future<void> received;

  void close() => _registry._open.remove(token);
}

/// The payload [link] points to, fetched over its pinned certificate.
Future<SharePayload> fetchShare(ReceiveLink link) async {
  final client = pinnedClient(link.fingerprint);
  try {
    final request = await client.getUrl(link.endpoint)
      ..followRedirects = false;
    final response = await request.close();
    final json = jsonDecode(await utf8.decodeStream(response));
    if (response.statusCode != 200 || json is! Map<String, dynamic>) {
      throw FormatException(
        (json is Map ? json['error'] as String? : null) ?? '分享读取失败',
      );
    }
    return SharePayload.fromJson(json);
  } finally {
    client.close(force: true);
  }
}

/// [resourceId] with every version it was edited from, oldest first, so the
/// receiver rebuilds the chain and keeps the card's attachments.
Future<SharePayload> resourceShare(
  ResourceLibrary library,
  String resourceId,
) async {
  final chain = <LibraryResource>[];
  for (String? id = resourceId; id != null;) {
    final resource = await library.repository.getResource(id);
    chain.insert(0, resource);
    id = resource.parentId;
  }
  return SharePayload(
    kind: ShareKind.resource,
    name: chain.last.name,
    data: {
      'kind': chain.last.kind.name,
      'versions': [
        for (final r in chain)
          {
            'filename': r.filename,
            'bytes': base64Encode(await library.original(r.id)),
          },
      ],
    },
  );
}

Future<LibraryResource> receiveResource(
  ResourceLibrary library,
  SharePayload payload,
) => _parsedAsync(() => _receiveResource(library, payload));

Future<LibraryResource> _receiveResource(
  ResourceLibrary library,
  SharePayload payload,
) async {
  final kind = ResourceKind.values.byName(payload.data['kind'] as String);
  LibraryResource? last;
  for (final version
      in (payload.data['versions'] as List).cast<Map<String, dynamic>>()) {
    final bytes = base64Decode(version['bytes'] as String);
    final filename = version['filename'] as String;
    // ponytail: receiving the same edited share twice adds its edits twice;
    // only the original file is deduplicated.
    last = last == null
        ? await library.importOnce(bytes, filename: filename, kind: kind)
        : await library.import(
            bytes,
            filename: filename,
            kind: kind,
            parentId: last.id,
          );
  }
  return last ?? (throw const FormatException('分享内容为空'));
}

SharePayload skillShare(AgentSkill skill) =>
    SharePayload(kind: ShareKind.skill, name: skill.title, data: skill.raw);

/// The shared skill as the receiver's own, never a built-in.
AgentSkill receivedSkill(SharePayload payload) =>
    _parsed(() => AgentSkill.fromJson({...payload.data, 'builtIn': false}));

Future<SharePayload> personaShare(Persona persona, AssetLibrary assets) async =>
    SharePayload(
      kind: ShareKind.persona,
      name: persona.name,
      data: {
        ...persona.snapshot,
        'images': [
          for (final image in persona.images)
            base64Encode(await assets.readHash(image.hash)),
        ],
      },
    );

Future<Persona> receivePersona(
  StoryRepository repository,
  AssetLibrary assets,
  SharePayload payload,
) => _parsedAsync(() => _receivePersona(repository, assets, payload));

Future<Persona> _receivePersona(
  StoryRepository repository,
  AssetLibrary assets,
  SharePayload payload,
) async {
  final data = payload.data;
  return repository.savePersona(
    Persona(
      id: '',
      name: data['name'] as String,
      description: data['description'] as String? ?? '',
      appearance: data['appearance'] as String? ?? '',
      outfit: data['outfit'] as String? ?? '',
      images: [
        for (final image in (data['images'] as List? ?? []).cast<String>())
          PersonaImage.of(await assets.prepare(base64Decode(image))),
      ],
    ),
  );
}

SharePayload connectionShare(ModelConnection connection, String apiKey) =>
    SharePayload(
      kind: ShareKind.connection,
      name: connection.name,
      data: {'connection': connection.raw, 'apiKey': apiKey},
    );

/// The shared connection under an id [takenIds] does not hold yet.
({ModelConnection connection, String apiKey}) receivedConnection(
  SharePayload payload,
  Set<String> takenIds,
) => _parsed(() {
  final raw = jsonObject(payload.data['connection'], 'connection');
  final id = raw['id'] as String;
  return (
    // A command is an executable path the receiver would run; never take
    // one from a share, so the receiver detects its own CLI.
    connection: ModelConnection.fromJson({
      ...raw,
      'command': '',
      if (takenIds.contains(id)) 'id': const Uuid().v4(),
    }),
    apiKey: payload.data['apiKey'] as String? ?? '',
  );
});
