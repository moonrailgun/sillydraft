import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';

/// drift's serialized messages hold only bool, int, double, String,
/// Uint8List and lists of them. JSON carries all but the bytes, which
/// travel as `{"b": base64}`; a map never occurs otherwise.
Object? encodeDriftMessage(Object? message) => switch (message) {
  final Uint8List bytes => {'b': base64Encode(bytes)},
  final List<Object?> list => [for (final v in list) encodeDriftMessage(v)],
  _ => message,
};

Object? decodeDriftMessage(Object? message) => switch (message) {
  {'b': final String data} => base64Decode(data),
  final List<Object?> list => [for (final v in list) decodeDriftMessage(v)],
  _ => message,
};

/// [socket] as the channel drift's remote protocol runs on.
StreamChannel<Object?> driftChannel(WebSocket socket) {
  final outgoing = StreamController<Object?>();
  outgoing.stream.listen(
    (message) => socket.add(jsonEncode(encodeDriftMessage(message))),
    onDone: () => unawaited(socket.close().catchError((Object _) {})),
  );
  return StreamChannel(
    socket.map((frame) => decodeDriftMessage(jsonDecode(frame as String))),
    outgoing.sink,
  );
}
