import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:peerwave_client/services/permanent_identity_key_store.dart';
import 'package:peerwave_client/services/permanent_pre_key_store.dart';
import 'package:peerwave_client/services/permanent_signed_pre_key_store.dart';
import 'package:peerwave_client/services/permanent_session_store.dart';
import 'package:peerwave_client/services/sender_key_store.dart';
import 'dart:convert';

/// Test versions of production stores that use in-memory storage
/// This lets us test ALL the real business logic without database!

/// In-memory storage for testing (replaces DeviceScopedStorageService)
class InMemoryStorage {
  final Map<String, Map<String, String>> _stores = {};

  Future<String?> getDecrypted(
    String storeName,
    String dbName,
    String key,
  ) async {
    return _stores[storeName]?[key];
  }

  Future<void> setEncrypted(
    String storeName,
    String dbName,
    String key,
    String value,
  ) async {
    _stores.putIfAbsent(storeName, () => {});
    _stores[storeName]![key] = value;
  }

  Future<void> delete(String storeName, String dbName, String key) async {
    _stores[storeName]?.remove(key);
  }

  Future<List<String>> getAllKeys(String storeName, String dbName) async {
    return _stores[storeName]?.keys.toList() ?? [];
  }

  void clear() {
    _stores.clear();
  }
}

/// Testable version of PermanentIdentityKeyStore with in-memory storage
class TestableIdentityKeyStore extends PermanentIdentityKeyStore {
  final InMemoryStorage _storage;

  TestableIdentityKeyStore(
    this._storage,
    IdentityKeyPair identityKeyPair,
    int registrationId,
  ) {
    this.identityKeyPair = identityKeyPair;
    this.localRegistrationId = registrationId;
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final key = '$_keyPrefix${address.getName()}_${address.getDeviceId()}';
    final value = await _storage.getDecrypted(_storeName, _storeName, key);

    if (value != null) {
      return IdentityKey.fromBytes(base64Decode(value), 0);
    }
    return null;
  }

  @override
  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey identityKey,
  ) async {
    final key = '$_keyPrefix${address.getName()}_${address.getDeviceId()}';
    final value = base64Encode(identityKey.serialize());
    await _storage.setEncrypted(_storeName, _storeName, key, value);
    return true;
  }

  @override
  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey identityKey,
    Direction direction,
  ) async {
    // For testing, always trust
    return true;
  }
}

/// Testable version of PermanentPreKeyStore with in-memory storage
class TestablePreKeyStore extends PermanentPreKeyStore {
  final InMemoryStorage _storage;

  TestablePreKeyStore(this._storage);

  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final value = await _storage.getDecrypted(
      _storeName,
      _storeName,
      _preKeyKey(preKeyId),
    );

    if (value == null) {
      throw InvalidKeyIdException('No PreKey with id $preKeyId');
    }

    final bytes = base64Decode(value);
    return PreKeyRecord.fromBuffer(bytes);
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    final value = base64Encode(record.serialize());
    await _storage.setEncrypted(
      _storeName,
      _storeName,
      _preKeyKey(preKeyId),
      value,
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final value = await _storage.getDecrypted(
      _storeName,
      _storeName,
      _preKeyKey(preKeyId),
    );
    return value != null;
  }

  @override
  Future<void> removePreKey(int preKeyId) async {
    await _storage.delete(_storeName, _storeName, _preKeyKey(preKeyId));
  }

  String _preKeyKey(int id) => 'prekey_$id';
}

/// Testable version of PermanentSignedPreKeyStore with in-memory storage
class TestableSignedPreKeyStore extends PermanentSignedPreKeyStore {
  final InMemoryStorage _storage;

  TestableSignedPreKeyStore(this._storage, IdentityKeyPair identityKeyPair)
    : super(identityKeyPair);

  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final value = await _storage.getDecrypted(
      _storeName,
      _storeName,
      _signedPreKeyKey(signedPreKeyId),
    );

    if (value == null) {
      throw InvalidKeyIdException('No SignedPreKey with id $signedPreKeyId');
    }

    final bytes = base64Decode(value);
    return SignedPreKeyRecord.fromSerialized(bytes);
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final keys = await _storage.getAllKeys(_storeName, _storeName);
    final records = <SignedPreKeyRecord>[];

    for (final key in keys) {
      if (key.startsWith('signed_prekey_')) {
        final value = await _storage.getDecrypted(_storeName, _storeName, key);
        if (value != null) {
          records.add(SignedPreKeyRecord.fromSerialized(base64Decode(value)));
        }
      }
    }

    return records;
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    final value = base64Encode(record.serialize());
    await _storage.setEncrypted(
      _storeName,
      _storeName,
      _signedPreKeyKey(signedPreKeyId),
      value,
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final value = await _storage.getDecrypted(
      _storeName,
      _storeName,
      _signedPreKeyKey(signedPreKeyId),
    );
    return value != null;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await _storage.delete(
      _storeName,
      _storeName,
      _signedPreKeyKey(signedPreKeyId),
    );
  }

  String _signedPreKeyKey(int id) => 'signed_prekey_$id';
}

/// Testable version of PermanentSessionStore with in-memory storage
class TestableSessionStore extends PermanentSessionStore {
  final InMemoryStorage _storage;

  TestableSessionStore(this._storage);

  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final key = _sessionKey(address);
    final value = await _storage.getDecrypted(_storeName, _storeName, key);

    if (value == null) {
      return SessionRecord();
    }

    final bytes = base64Decode(value);
    return SessionRecord.fromSerialized(bytes);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final keys = await _storage.getAllKeys(_storeName, _storeName);
    final deviceIds = <int>[];

    for (final key in keys) {
      if (key.startsWith('session_$name:')) {
        final parts = key.split(':');
        if (parts.length == 2) {
          deviceIds.add(int.parse(parts[1]));
        }
      }
    }

    return deviceIds;
  }

  @override
  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    final key = _sessionKey(address);
    final value = base64Encode(record.serialize());
    await _storage.setEncrypted(_storeName, _storeName, key, value);
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async {
    final session = await loadSession(address);
    return session.hasSenderChain();
  }

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async {
    await _storage.delete(_storeName, _storeName, _sessionKey(address));
  }

  @override
  Future<void> deleteAllSessions(String name) async {
    final keys = await _storage.getAllKeys(_storeName, _storeName);
    for (final key in keys) {
      if (key.startsWith('session_$name:')) {
        await _storage.delete(_storeName, _storeName, key);
      }
    }
  }

  String _sessionKey(SignalProtocolAddress address) =>
      'session_${address.getName()}:${address.getDeviceId()}';
}

/// Testable version of PermanentSenderKeyStore with in-memory storage
class TestableSenderKeyStore extends PermanentSenderKeyStore {
  final InMemoryStorage _storage;

  TestableSenderKeyStore(this._storage);

  @override
  Future<void> storeSenderKey(
    SenderKeyName senderKeyName,
    SenderKeyRecord record,
  ) async {
    final key = _senderKeyKey(senderKeyName);
    final value = base64Encode(record.serialize());
    await _storage.setEncrypted(_storeName, _storeName, key, value);
  }

  @override
  Future<SenderKeyRecord?> loadSenderKey(SenderKeyName senderKeyName) async {
    final key = _senderKeyKey(senderKeyName);
    final value = await _storage.getDecrypted(_storeName, _storeName, key);

    if (value == null) {
      return null;
    }

    final bytes = base64Decode(value);
    return SenderKeyRecord.fromSerialized(bytes);
  }

  String _senderKeyKey(SenderKeyName name) =>
      'senderkey_${name.getGroupId()}_${name.getSender().getName()}_${name.getSender().getDeviceId()}';
}
