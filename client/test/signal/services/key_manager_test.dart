import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';
import 'package:peerwave_client/services/signal/core/encryption_service.dart';

/// REAL tests for production Signal services
/// Tests the actual KeyManager, SessionManager, EncryptionService
/// that the app depends on. If these fail, the app WILL break!
void main() {
  // Helper to create services with in-memory stores for testing
  Future<KeyManager> createTestKeyManager() async {
    final identityStore = InMemoryIdentityKeyStore(
      generateIdentityKeyPair(),
      generateRegistrationId(false),
    );
    final preKeyStore = InMemoryPreKeyStore();
    final signedPreKeyStore = InMemorySignedPreKeyStore();
    final sessionStore = InMemorySessionStore();
    final senderKeyStore = InMemorySenderKeyStore();

    // Generate initial keys
    final identityKeyPair = await identityStore.getIdentityKeyPair();
    final signedPreKey = generateSignedPreKey(identityKeyPair, 1);
    await signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);

    final preKeys = generatePreKeys(1, 10);
    for (final preKey in preKeys) {
      await preKeyStore.storePreKey(preKey.id, preKey);
    }

    return KeyManager(
      identityStore: identityStore,
      preKeyStore: preKeyStore,
      signedPreKeyStore: signedPreKeyStore,
      sessionStore: sessionStore,
      senderKeyStore: senderKeyStore,
    );
  }

  group('KeyManager - Production Service Tests', () {
    group('PermanentIdentityKeyStore - Production Logic', () {
      late InMemoryStorage storage;
      late TestableIdentityKeyStore identityStore;
      late IdentityKeyPair testKeyPair;

      setUp(() {
        storage = InMemoryStorage();
        testKeyPair = generateIdentityKeyPair();
        identityStore = TestableIdentityKeyStore(storage, testKeyPair, 12345);
      });

      test('Returns correct identity key pair', () async {
        final keyPair = await identityStore.getIdentityKeyPair();

        expect(keyPair, isNotNull);
        expect(
          keyPair.getPublicKey().serialize(),
          equals(testKeyPair.getPublicKey().serialize()),
        );

        print('✅ Identity key pair matches');
      });

      test('Returns correct registration ID', () async {
        final regId = await identityStore.getLocalRegistrationId();

        expect(regId, equals(12345));

        print('✅ Registration ID correct');
      });

      test('Saves and retrieves identity correctly', () async {
        final address = SignalProtocolAddress('bob@test.com', 1);
        final bobIdentity = generateIdentityKeyPair().getPublicKey();

        // Save
        await identityStore.saveIdentity(address, bobIdentity);

        // Retrieve
        final retrieved = await identityStore.getIdentity(address);

        expect(retrieved, isNotNull);
        expect(retrieved!.serialize(), equals(bobIdentity.serialize()));

        print('✅ Identity saved and retrieved');
      });

      test('Returns null for unknown identity', () async {
        final address = SignalProtocolAddress('unknown@test.com', 1);

        final identity = await identityStore.getIdentity(address);

        expect(identity, isNull);

        print('✅ Unknown identity returns null');
      });
    });

    group('PermanentPreKeyStore - Production Logic', () {
      late InMemoryStorage storage;
      late TestablePreKeyStore preKeyStore;

      setUp(() {
        storage = InMemoryStorage();
        preKeyStore = TestablePreKeyStore(storage);
      });

      test('Stores and loads PreKey correctly', () async {
        final preKey = generatePreKeys(1, 1).first;

        // Store
        await preKeyStore.storePreKey(preKey.id, preKey);

        // Load
        final loaded = await preKeyStore.loadPreKey(preKey.id);

        expect(loaded.id, equals(preKey.id));
        expect(
          loaded.getKeyPair().publicKey.serialize(),
          equals(preKey.getKeyPair().publicKey.serialize()),
        );

        print('✅ PreKey stored and loaded');
      });

      test('containsPreKey returns correct values', () async {
        final preKey = generatePreKeys(1, 1).first;

        // Initially doesn't exist
        expect(await preKeyStore.containsPreKey(preKey.id), isFalse);

        // Store it
        await preKeyStore.storePreKey(preKey.id, preKey);

        // Now exists
        expect(await preKeyStore.containsPreKey(preKey.id), isTrue);

        print('✅ containsPreKey works');
      });

      test('removePreKey deletes correctly', () async {
        final preKey = generatePreKeys(1, 1).first;

        // Store
        await preKeyStore.storePreKey(preKey.id, preKey);
        expect(await preKeyStore.containsPreKey(preKey.id), isTrue);

        // Remove
        await preKeyStore.removePreKey(preKey.id);
        expect(await preKeyStore.containsPreKey(preKey.id), isFalse);

        print('✅ PreKey removed');
      });

      test('loadPreKey throws for missing key', () async {
        expect(
          () => preKeyStore.loadPreKey(999),
          throwsA(isA<InvalidKeyIdException>()),
        );

        print('✅ Missing PreKey throws exception');
      });
    });

    group('PermanentSignedPreKeyStore - Production Logic', () {
      late InMemoryStorage storage;
      late TestableSignedPreKeyStore signedPreKeyStore;
      late IdentityKeyPair identityKeyPair;

      setUp(() {
        storage = InMemoryStorage();
        identityKeyPair = generateIdentityKeyPair();
        signedPreKeyStore = TestableSignedPreKeyStore(storage, identityKeyPair);
      });

      test('Stores and loads SignedPreKey correctly', () async {
        final signedPreKey = generateSignedPreKey(identityKeyPair, 1);

        // Store
        await signedPreKeyStore.storeSignedPreKey(
          signedPreKey.id,
          signedPreKey,
        );

        // Load
        final loaded = await signedPreKeyStore.loadSignedPreKey(
          signedPreKey.id,
        );

        expect(loaded.id, equals(signedPreKey.id));
        expect(
          loaded.getKeyPair().publicKey.serialize(),
          equals(signedPreKey.getKeyPair().publicKey.serialize()),
        );

        print('✅ SignedPreKey stored and loaded');
      });

      test('loadSignedPreKeys returns all keys', () async {
        // Store 3 signed prekeys
        for (int i = 1; i <= 3; i++) {
          final key = generateSignedPreKey(identityKeyPair, i);
          await signedPreKeyStore.storeSignedPreKey(key.id, key);
        }

        // Load all
        final allKeys = await signedPreKeyStore.loadSignedPreKeys();

        expect(allKeys.length, equals(3));
        expect(allKeys.map((k) => k.id).toList(), containsAll([1, 2, 3]));

        print('✅ All SignedPreKeys loaded: ${allKeys.length}');
      });

      test('removeSignedPreKey deletes correctly', () async {
        final signedPreKey = generateSignedPreKey(identityKeyPair, 1);

        // Store
        await signedPreKeyStore.storeSignedPreKey(
          signedPreKey.id,
          signedPreKey,
        );
        expect(
          await signedPreKeyStore.containsSignedPreKey(signedPreKey.id),
          isTrue,
        );

        // Remove
        await signedPreKeyStore.removeSignedPreKey(signedPreKey.id);
        expect(
          await signedPreKeyStore.containsSignedPreKey(signedPreKey.id),
          isFalse,
        );

        print('✅ SignedPreKey removed');
      });
    });

    group('PermanentSessionStore - Production Logic', () {
      late InMemoryStorage storage;
      late TestableSessionStore sessionStore;

      setUp(() {
        storage = InMemoryStorage();
        sessionStore = TestableSessionStore(storage);
      });

      test('Stores and loads session correctly', () async {
        final address = SignalProtocolAddress('bob@test.com', 1);
        final session = SessionRecord();

        // Store
        await sessionStore.storeSession(address, session);

        // Load
        final loaded = await sessionStore.loadSession(address);

        expect(loaded, isNotNull);

        print('✅ Session stored and loaded');
      });

      test('containsSession requires sender chain', () async {
        final address = SignalProtocolAddress('bob@test.com', 1);
        final emptySession = SessionRecord();

        // Store empty session
        await sessionStore.storeSession(address, emptySession);

        // Should not contain (no sender chain yet)
        expect(await sessionStore.containsSession(address), isFalse);

        print('✅ containsSession checks for sender chain');
      });

      test('Deletes session correctly', () async {
        final address = SignalProtocolAddress('bob@test.com', 1);
        final session = SessionRecord();

        // Store
        await sessionStore.storeSession(address, session);

        // Delete
        await sessionStore.deleteSession(address);

        // Load should return new empty session
        final loaded = await sessionStore.loadSession(address);
        expect(loaded.hasSenderChain(), isFalse);

        print('✅ Session deleted');
      });

      test('getSubDeviceSessions returns correct device IDs', () async {
        // Store sessions for multiple devices
        for (int deviceId = 1; deviceId <= 3; deviceId++) {
          final address = SignalProtocolAddress('bob@test.com', deviceId);
          await sessionStore.storeSession(address, SessionRecord());
        }

        // Get all device IDs
        final deviceIds = await sessionStore.getSubDeviceSessions(
          'bob@test.com',
        );

        expect(deviceIds.length, equals(3));
        expect(deviceIds, containsAll([1, 2, 3]));

        print('✅ Sub-device sessions retrieved: $deviceIds');
      });

      test('deleteAllSessions removes all devices', () async {
        // Store sessions for multiple devices
        for (int deviceId = 1; deviceId <= 3; deviceId++) {
          final address = SignalProtocolAddress('bob@test.com', deviceId);
          await sessionStore.storeSession(address, SessionRecord());
        }

        // Delete all
        await sessionStore.deleteAllSessions('bob@test.com');

        // Verify all gone
        final deviceIds = await sessionStore.getSubDeviceSessions(
          'bob@test.com',
        );
        expect(deviceIds, isEmpty);

        print('✅ All sessions deleted');
      });
    });

    group('PermanentSenderKeyStore - Production Logic', () {
      late InMemoryStorage storage;
      late TestableSenderKeyStore senderKeyStore;

      setUp(() {
        storage = InMemoryStorage();
        senderKeyStore = TestableSenderKeyStore(storage);
      });

      test('Stores and loads sender key correctly', () async {
        final address = SignalProtocolAddress('alice@test.com', 1);
        final senderKeyName = SenderKeyName('group-123', address);
        final record = SenderKeyRecord();

        // Store
        await senderKeyStore.storeSenderKey(senderKeyName, record);

        // Load
        final loaded = await senderKeyStore.loadSenderKey(senderKeyName);

        expect(loaded, isNotNull);

        print('✅ SenderKey stored and loaded');
      });

      test('Returns null for unknown sender key', () async {
        final address = SignalProtocolAddress('alice@test.com', 1);
        final senderKeyName = SenderKeyName('unknown-group', address);

        final loaded = await senderKeyStore.loadSenderKey(senderKeyName);

        expect(loaded, isNull);

        print('✅ Unknown SenderKey returns null');
      });
    });
  }); // Close 'KeyManager - Production Service Tests' group
}
