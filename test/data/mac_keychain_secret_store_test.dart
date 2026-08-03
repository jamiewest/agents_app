import 'package:agents_app/data/mac_keychain_secret_store.dart';
import 'package:agents_flutter/agents_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [SecretStore] that records the calls made against it.
class _FakeSecretStore extends SecretStore {
  _FakeSecretStore([Map<String, String>? initial])
    : values = {...?initial};

  final Map<String, String> values;
  final List<String> deleted = [];
  bool failDeletes = false;

  /// Models a keychain that accepts a write and does not keep it.
  bool dropWrites = false;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    if (dropWrites) return;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDeletes) {
      throw StateError('keychain delete rejected');
    }
    deleted.add(key);
    values.remove(key);
  }
}

void main() {
  late _FakeSecretStore store;
  late _FakeSecretStore legacy;
  late MacKeychainSecretStore secrets;

  setUp(() {
    store = _FakeSecretStore();
    legacy = _FakeSecretStore();
    secrets = MacKeychainSecretStore(store: store, legacy: legacy);
  });

  test('reads from the data protection keychain without touching the '
      'legacy one', () async {
    store.values['api-key'] = 'current';
    legacy.values['api-key'] = 'stale';

    expect(await secrets.read('api-key'), 'current');
    expect(legacy.deleted, isEmpty);
    expect(legacy.values['api-key'], 'stale');
  });

  test('migrates a legacy secret on first read', () async {
    legacy.values['agents_app.tor.identity.sharing'] = 'onion-key';

    expect(await secrets.read('agents_app.tor.identity.sharing'), 'onion-key');
    expect(store.values['agents_app.tor.identity.sharing'], 'onion-key');
    expect(legacy.values, isEmpty);

    // The second read is served by the migrated copy.
    store.values['agents_app.tor.identity.sharing'] = 'onion-key';
    expect(await secrets.read('agents_app.tor.identity.sharing'), 'onion-key');
  });

  test('still migrates when the legacy entry cannot be removed', () async {
    legacy.values['pushover.token'] = 'token';
    legacy.failDeletes = true;

    expect(await secrets.read('pushover.token'), 'token');
    expect(store.values['pushover.token'], 'token');
    expect(legacy.values['pushover.token'], 'token');
  });

  test('keeps the legacy secret when the migrated copy does not stick', () async {
    legacy.values['agents_app.tor.identity.sharing'] = 'onion-key';
    store.dropWrites = true;

    // The caller still gets its secret — the only thing being protected here
    // is the sole surviving copy of it.
    expect(await secrets.read('agents_app.tor.identity.sharing'), 'onion-key');
    expect(legacy.values['agents_app.tor.identity.sharing'], 'onion-key');
    expect(legacy.deleted, isEmpty);
  });

  test('returns null when neither keychain holds the key', () async {
    expect(await secrets.read('absent'), isNull);
    expect(store.values, isEmpty);
  });

  test('writes only to the data protection keychain', () async {
    await secrets.write('api-key', 'value');

    expect(store.values['api-key'], 'value');
    expect(legacy.values, isEmpty);
  });

  test('deletes from both keychains', () async {
    store.values['api-key'] = 'value';
    legacy.values['api-key'] = 'old';

    await secrets.delete('api-key');

    expect(store.deleted, ['api-key']);
    expect(legacy.deleted, ['api-key']);
  });

  test('a rejected legacy delete does not fail the delete', () async {
    store.values['api-key'] = 'value';
    legacy.failDeletes = true;

    await secrets.delete('api-key');

    expect(store.values, isEmpty);
  });
}
