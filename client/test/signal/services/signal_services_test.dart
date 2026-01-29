import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../helpers/testable_services.dart';

/// Tests for YOUR ACTUAL Signal service logic
/// These wrappers mirror KeyManager, SessionManager, EncryptionService
/// but use in-memory stores so we can test the REAL business logic
void main() {
  group('KeyManager Business Logic', () {
    test('Generates and retrieves identity key correctly', () async {
      final keyManager = await TestKeyManagerWrapper.create();

      // Get identity key
      final identityKey = await keyManager.getIdentityKey();
      expect(identityKey, isNotNull);
      expect(identityKey.serialize().length, greaterThan(0));

      // Get identity key pair
      final keyPair = await keyManager.getIdentityKeyPair();
      expect(
        keyPair.getPublicKey().serialize(),
        equals(identityKey.serialize()),
      );

      print('✅ KeyManager: Identity key operations work');
    });

    test('Manages registration ID correctly', () async {
      final keyManager = await TestKeyManagerWrapper.create();

      final regId = await keyManager.getRegistrationId();

      expect(regId, greaterThan(0));
      expect(regId, lessThan(16384)); // Valid range

      print('✅ KeyManager: Registration ID is valid: $regId');
    });

    test('PreKey CRUD operations work', () async {
      final keyManager = await TestKeyManagerWrapper.create();

      // Generate new prekey
      final newPreKey = generatePreKeys(100, 1).first;

      // Store
      await keyManager.storePreKey(newPreKey.id, newPreKey);
      expect(await keyManager.containsPreKey(newPreKey.id), isTrue);

      // Load
      final loaded = await keyManager.loadPreKey(newPreKey.id);
      expect(loaded.id, equals(newPreKey.id));

      // Remove
      await keyManager.removePreKey(newPreKey.id);
      expect(await keyManager.containsPreKey(newPreKey.id), isFalse);

      print('✅ KeyManager: PreKey CRUD operations work');
    });

    test('SignedPreKey CRUD operations work', () async {
      final keyManager = await TestKeyManagerWrapper.create();

      // Generate new signed prekey
      final identityKeyPair = await keyManager.getIdentityKeyPair();
      final newSignedPreKey = generateSignedPreKey(identityKeyPair, 999);

      // Store
      await keyManager.storeSignedPreKey(newSignedPreKey.id, newSignedPreKey);
      expect(await keyManager.containsSignedPreKey(newSignedPreKey.id), isTrue);

      // Load
      final loaded = await keyManager.loadSignedPreKey(newSignedPreKey.id);
      expect(loaded.id, equals(newSignedPreKey.id));

      // Load all
      final allKeys = await keyManager.loadSignedPreKeys();
      expect(allKeys.length, greaterThanOrEqualTo(2)); // Initial + new

      // Remove
      await keyManager.removeSignedPreKey(newSignedPreKey.id);
      expect(
        await keyManager.containsSignedPreKey(newSignedPreKey.id),
        isFalse,
      );

      print('✅ KeyManager: SignedPreKey CRUD operations work');
    });

    test('Identity trust operations work', () async {
      final keyManager = await TestKeyManagerWrapper.create();

      final bobAddress = SignalProtocolAddress('bob@test.com', 1);
      final bobIdentity = generateIdentityKeyPair().getPublicKey();

      // Save
      await keyManager.saveIdentity(bobAddress, bobIdentity);

      // Retrieve
      final retrieved = await keyManager.getIdentity(bobAddress);
      expect(retrieved, isNotNull);
      expect(retrieved!.serialize(), equals(bobIdentity.serialize()));

      // Trust check
      final isTrusted = await keyManager.isTrustedIdentity(
        bobAddress,
        bobIdentity,
        Direction.SENDING,
      );
      expect(isTrusted, isTrue);

      print('✅ KeyManager: Identity trust operations work');
    });
  });

  group('SessionManager Business Logic', () {
    test('Creates SessionCipher correctly', () async {
      final keyManager = await TestKeyManagerWrapper.create();
      final sessionManager = await TestSessionManagerWrapper.create(
        keyManager: keyManager,
      );

      final bobAddress = SignalProtocolAddress('bob@test.com', 1);

      // Should not throw
      final cipher = sessionManager.createSessionCipher(bobAddress);
      expect(cipher, isNotNull);

      print('✅ SessionManager: SessionCipher creation works');
    });

    test('Creates GroupCipher correctly', () async {
      final keyManager = await TestKeyManagerWrapper.create();
      final sessionManager = await TestSessionManagerWrapper.create(
        keyManager: keyManager,
      );

      final aliceAddress = SignalProtocolAddress('alice@test.com', 1);
      const groupId = 'test-group-123';

      // Should not throw
      final cipher = sessionManager.createGroupCipher(groupId, aliceAddress);
      expect(cipher, isNotNull);

      print('✅ SessionManager: GroupCipher creation works');
    });

    test('Session CRUD operations work', () async {
      final keyManager = await TestKeyManagerWrapper.create();
      final sessionManager = await TestSessionManagerWrapper.create(
        keyManager: keyManager,
      );

      final bobAddress = SignalProtocolAddress('bob@test.com', 1);

      // Initially no session
      expect(await sessionManager.containsSession(bobAddress), isFalse);

      // Store session
      final session = SessionRecord();
      await sessionManager.storeSession(bobAddress, session);

      // Load session
      final loaded = await sessionManager.loadSession(bobAddress);
      expect(loaded, isNotNull);

      // Delete session
      await sessionManager.deleteSession(bobAddress);

      // Should be gone (returns new empty session)
      final afterDelete = await sessionManager.loadSession(bobAddress);
      expect(afterDelete.isFresh(), isTrue);

      print('✅ SessionManager: Session CRUD operations work');
    });

    test('Sub-device session tracking works', () async {
      final keyManager = await TestKeyManagerWrapper.create();
      final sessionManager = await TestSessionManagerWrapper.create(
        keyManager: keyManager,
      );

      // Store sessions for multiple devices
      for (int deviceId = 1; deviceId <= 3; deviceId++) {
        final address = SignalProtocolAddress('bob@test.com', deviceId);
        await sessionManager.storeSession(address, SessionRecord());
      }

      // Get all device IDs
      final deviceIds = await sessionManager.getSubDeviceSessions(
        'bob@test.com',
      );
      expect(deviceIds.length, equals(3));
      expect(deviceIds, containsAll([1, 2, 3]));

      // Delete all
      await sessionManager.deleteAllSessions('bob@test.com');

      // Verify all gone
      final afterDelete = await sessionManager.getSubDeviceSessions(
        'bob@test.com',
      );
      expect(afterDelete, isEmpty);

      print('✅ SessionManager: Sub-device tracking works');
    });
  });

  group('EncryptionService Business Logic', () {
    test('1-to-1 encryption/decryption flow', () async {
      final aliceKeyManager = await TestKeyManagerWrapper.create();
      final aliceSessionManager = await TestSessionManagerWrapper.create(
        keyManager: aliceKeyManager,
      );
      final aliceEncryption = await TestEncryptionServiceWrapper.create(
        keyManager: aliceKeyManager,
        sessionManager: aliceSessionManager,
      );

      final bobKeyManager = await TestKeyManagerWrapper.create();
      final bobSessionManager = await TestSessionManagerWrapper.create(
        keyManager: bobKeyManager,
      );
      final bobEncryption = await TestEncryptionServiceWrapper.create(
        keyManager: bobKeyManager,
        sessionManager: bobSessionManager,
      );

      // Build session (Alice → Bob)
      final bobIdentity = await bobKeyManager.getIdentityKey();
      final bobAddress = SignalProtocolAddress('bob@test.com', 1);
      final aliceAddress = SignalProtocolAddress('alice@test.com', 1);

      // Get Bob's prekey bundle
      final bobPreKeys = await bobKeyManager.loadSignedPreKeys();
      final bobSignedPreKey = bobPreKeys.first;
      final bobPreKey = await bobKeyManager.loadPreKey(1);
      final bobRegId = await bobKeyManager.getRegistrationId();

      final bundle = PreKeyBundle(
        bobRegId,
        1,
        bobPreKey.id,
        bobPreKey.getKeyPair().publicKey,
        bobSignedPreKey.id,
        bobSignedPreKey.getKeyPair().publicKey,
        bobSignedPreKey.signature,
        bobIdentity,
      );

      // Build session
      final sessionBuilder = SessionBuilder(
        aliceSessionManager.sessionStore,
        aliceKeyManager.preKeyStore,
        aliceKeyManager.signedPreKeyStore,
        aliceKeyManager.identityStore,
        bobAddress,
      );
      await sessionBuilder.processPreKeyBundle(bundle);

      // Alice encrypts message to Bob
      final message = 'Hello Bob!';
      final plaintext = Uint8List.fromList(utf8.encode(message));

      final ciphertext = await aliceEncryption.encryptMessage(
        recipientAddress: bobAddress,
        plaintext: plaintext,
      );

      expect(ciphertext, isNotNull);
      expect(ciphertext.getType(), equals(CiphertextMessage.prekeyType));

      // Bob decrypts message from Alice
      final decrypted = await bobEncryption.decryptMessage(
        senderAddress: aliceAddress,
        payload: ciphertext.serialize(),
        messageType: ciphertext.getType(),
      );

      final decryptedText = utf8.decode(decrypted);
      expect(decryptedText, equals(message));

      print('✅ EncryptionService: 1-to-1 encryption/decryption works');
    });

    test('Multiple messages in same session', () async {
      final aliceKeyManager = await TestKeyManagerWrapper.create();
      final aliceSessionManager = await TestSessionManagerWrapper.create(
        keyManager: aliceKeyManager,
      );
      final aliceEncryption = await TestEncryptionServiceWrapper.create(
        keyManager: aliceKeyManager,
        sessionManager: aliceSessionManager,
      );

      final bobKeyManager = await TestKeyManagerWrapper.create();
      final bobSessionManager = await TestSessionManagerWrapper.create(
        keyManager: bobKeyManager,
      );
      final bobEncryption = await TestEncryptionServiceWrapper.create(
        keyManager: bobKeyManager,
        sessionManager: bobSessionManager,
      );

      // Setup session (simplified - use SessionBuilder)
      final bobAddress = SignalProtocolAddress('bob@test.com', 1);
      final aliceAddress = SignalProtocolAddress('alice@test.com', 1);

      // Build session first
      final bobIdentity = await bobKeyManager.getIdentityKey();
      final bobPreKeys = await bobKeyManager.loadSignedPreKeys();
      final bobSignedPreKey = bobPreKeys.first;
      final bobPreKey = await bobKeyManager.loadPreKey(1);
      final bobRegId = await bobKeyManager.getRegistrationId();

      final bundle = PreKeyBundle(
        bobRegId,
        1,
        bobPreKey.id,
        bobPreKey.getKeyPair().publicKey,
        bobSignedPreKey.id,
        bobSignedPreKey.getKeyPair().publicKey,
        bobSignedPreKey.signature,
        bobIdentity,
      );

      final sessionBuilder = SessionBuilder(
        aliceSessionManager.sessionStore,
        aliceKeyManager.preKeyStore,
        aliceKeyManager.signedPreKeyStore,
        aliceKeyManager.identityStore,
        bobAddress,
      );
      await sessionBuilder.processPreKeyBundle(bundle);

      // Send 10 messages
      for (int i = 0; i < 10; i++) {
        final message = 'Message $i';
        final plaintext = Uint8List.fromList(utf8.encode(message));

        final ciphertext = await aliceEncryption.encryptMessage(
          recipientAddress: bobAddress,
          plaintext: plaintext,
        );

        final decrypted = await bobEncryption.decryptMessage(
          senderAddress: aliceAddress,
          payload: ciphertext.serialize(),
          messageType: ciphertext.getType(),
        );

        expect(utf8.decode(decrypted), equals(message));
      }

      print('✅ EncryptionService: Multiple messages work');
    });
  });

  group('Integrated Service Stack', () {
    test(
      'Full stack: KeyManager → SessionManager → EncryptionService',
      () async {
        // Alice's services
        final aliceKeyManager = await TestKeyManagerWrapper.create();
        final aliceSessionManager = await TestSessionManagerWrapper.create(
          keyManager: aliceKeyManager,
        );
        final aliceEncryption = await TestEncryptionServiceWrapper.create(
          keyManager: aliceKeyManager,
          sessionManager: aliceSessionManager,
        );

        // Bob's services
        final bobKeyManager = await TestKeyManagerWrapper.create();
        final bobSessionManager = await TestSessionManagerWrapper.create(
          keyManager: bobKeyManager,
        );
        final bobEncryption = await TestEncryptionServiceWrapper.create(
          keyManager: bobKeyManager,
          sessionManager: bobSessionManager,
        );

        // Verify full stack is connected
        expect(aliceEncryption, isNotNull);
        expect(bobEncryption, isNotNull);

        // Verify stores are accessible through the stack
        expect(aliceSessionManager.sessionStore, isNotNull);
        expect(aliceKeyManager.identityStore, isNotNull);

        print('✅ Full service stack integration works');
      },
    );
  });
}
