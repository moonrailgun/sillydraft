import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sillydraft/app/services.dart';

/// A keychain stand-in that can refuse access, like a denied macOS prompt.
final class _FakeKeychain implements LegacySecretStore {
  _FakeKeychain([Map<String, String>? values]) : values = {...?values};
  final Map<String, String> values;
  bool denied = false;
  int reads = 0;

  void _check() {
    if (denied) throw StateError('用户拒绝了钥匙串访问');
  }

  @override
  Future<String?> read(String key) async {
    _check();
    reads++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _check();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _check();
    values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll() async {
    _check();
    return {...values};
  }

  @override
  Future<void> deleteAll() async {
    _check();
    values.clear();
  }
}

void main() {
  late Directory dir;
  late File file;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sillydraft-secrets-');
    file = File('${dir.path}/secrets.json');
  });
  tearDown(() => dir.delete(recursive: true));

  test('secrets persist as a plain owner-only file across restarts', () async {
    final secrets = FileSecrets(file);
    await secrets.write('model/a', 'sk-one');
    await secrets.write('sync/x/auth', 'Bearer t');
    await secrets.delete('sync/x/auth');

    final reopened = FileSecrets(file);
    expect(await reopened.read('model/a'), 'sk-one');
    expect(await reopened.read('sync/x/auth'), isNull);
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['values'], {'model/a': 'sk-one'});
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    if (Platform.isMacOS || Platform.isLinux) {
      expect((await file.stat()).mode & 0x1FF, 0x180); // rw-------
    }
  });

  test(
    'keychain secrets move into the file once and the keychain is cleared',
    () async {
      final keychain = _FakeKeychain({
        'resources/aes256': 'old-resource-key',
        'model/a': 'sk-keychain',
      });
      final secrets = FileSecrets(file, legacy: keychain);
      await secrets.write('model/a', 'sk-file'); // written before migrating
      await secrets.migrateLegacy();

      expect(keychain.values, isEmpty);
      expect(await secrets.read('resources/aes256'), 'old-resource-key');
      expect(await secrets.read('model/a'), 'sk-file');
      final readsAfterMigration = keychain.reads;
      expect(await secrets.read('model/missing'), isNull);
      expect(
        keychain.reads,
        readsAfterMigration,
        reason: 'no keychain fallback',
      );

      // A later launch does not touch the keychain again.
      keychain.denied = true;
      final relaunched = FileSecrets(file, legacy: keychain);
      await relaunched.migrateLegacy();
      expect(await relaunched.read('resources/aes256'), 'old-resource-key');
    },
  );

  test('a refused keychain is an error, never a missing key', () async {
    final keychain = _FakeKeychain({'resources/aes256': 'old-resource-key'})
      ..denied = true;
    final secrets = FileSecrets(file, legacy: keychain);
    await expectLater(secrets.migrateLegacy(), throwsStateError);
    // Reading must fail rather than return null, so the resource key is not
    // regenerated and imported originals stay decryptable.
    await expectLater(secrets.read('resources/aes256'), throwsStateError);

    keychain.denied = false;
    expect(await secrets.read('resources/aes256'), 'old-resource-key');
    keychain.values.clear();
    expect(
      await FileSecrets(file, legacy: keychain).read('resources/aes256'),
      'old-resource-key',
      reason: 'copied into the file on first successful read',
    );
  });

  test('a key deleted before migration does not come back', () async {
    final keychain = _FakeKeychain({'model/gone': 'sk-old'})..denied = true;
    final secrets = FileSecrets(file, legacy: keychain);
    await secrets.delete('model/gone'); // keychain refuses the delete too
    expect(await secrets.read('model/gone'), isNull);

    keychain.denied = false;
    await FileSecrets(file, legacy: keychain).migrateLegacy();
    expect(await FileSecrets(file).read('model/gone'), isNull);
  });

  test(
    'a store that never had a keychain records nothing to migrate',
    () async {
      await FileSecrets(file).write('model/a', 'sk-new');
      final keychain = _FakeKeychain({'model/a': 'sk-stale'})..denied = true;
      final secrets = FileSecrets(file, legacy: keychain);
      await secrets.migrateLegacy(); // no keychain access at all
      expect(await secrets.read('model/b'), isNull);
      expect(await secrets.read('model/a'), 'sk-new');
    },
  );

  test('a damaged file is reported, not treated as empty', () async {
    await file.writeAsString('{not json');
    final secrets = FileSecrets(file);
    await expectLater(secrets.read('resources/aes256'), throwsFormatException);
    expect(await file.readAsString(), '{not json');
  });
}
