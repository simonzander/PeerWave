import 'package:flutter_test/flutter_test.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';
import 'package:peerwave_client/services/signal/core/encryption_service.dart';
import 'helpers/test_device_setup.dart';

/// Integration tests for real-world Signal Protocol service scenarios
///
/// These tests validate the production Signal services with real encrypted storage,
/// focusing on service creation, initialization, and key management workflows.
///
/// Run with: flutter test integration_test/signal_messaging_scenarios_test.dart -d windows
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Signal Service Integration Scenarios', () {
    tearDown(() async {
      // Wait for background operations to complete
      await Future.delayed(const Duration(milliseconds: 200));
    });

    test('Scenario 1: Fresh user initialization', () async {
      // Simulate a new user setting up Signal for the first time
      await initializeTestDeviceIdentity(
        email: 'alice@test.com',
        credentialId: 'alice-cred',
        clientId: 'alice-client',
      );

      // Create services in correct order
      final keyManager = await SignalKeyManager.create();
      final sessionManager = await SessionManager.create(
        keyManager: keyManager,
      );
      final encryptionService = await EncryptionService.create(
        keyManager: keyManager,
        sessionManager: sessionManager,
      );

      // Verify all services initialized
      expect(keyManager.isInitialized, isTrue);
      expect(sessionManager.isInitialized, isTrue);
      expect(encryptionService.isInitialized, isTrue);

      // Verify identity key was generated
      final identityKeyPair = await keyManager.identityStore
          .getIdentityKeyPair();
      expect(identityKeyPair, isNotNull);

      print('✅ Fresh user initialization successful');
    });

    test(
      'Scenario 2: Restart simulation - services reload from storage',
      () async {
        // Initial setup
        await initializeTestDeviceIdentity(
          email: 'bob@test.com',
          credentialId: 'bob-cred',
          clientId: 'bob-client',
        );

        var keyManager = await SignalKeyManager.create();

        // Get identity key from first initialization
        final originalIdentity = await keyManager.identityStore
            .getIdentityKeyPair();
        final originalPublicKey = originalIdentity.getPublicKey().serialize();

        // Simulate app restart: recreate services (storage persists)
        keyManager = await SignalKeyManager.create();

        // Identity key should be the same (loaded from storage)
        final reloadedIdentity = await keyManager.identityStore
            .getIdentityKeyPair();
        final reloadedPublicKey = reloadedIdentity.getPublicKey().serialize();

        expect(reloadedPublicKey, equals(originalPublicKey));

        print('✅ Service restart successful - identity persisted');
      },
    );

    test('Scenario 3: PreKey generation and management', () async {
      await initializeTestDeviceIdentity(
        email: 'charlie@test.com',
        credentialId: 'charlie-cred',
        clientId: 'charlie-client',
      );

      final keyManager = await SignalKeyManager.create();

      // Generate batch of prekeys (1-10)
      final preKeys = await keyManager.generatePreKeysInRange(1, 10);
      expect(preKeys.length, equals(10));

      // Verify prekeys were created
      final preKeyIds = await keyManager.preKeyStore.getAllPreKeyIds();
      expect(preKeyIds, hasLength(10));
      expect(preKeyIds, containsAll([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]));

      // Load a specific prekey
      final preKey5 = await keyManager.preKeyStore.loadPreKey(5);
      expect(preKey5, isNotNull);
      expect(preKey5.id, equals(5));

      print('✅ PreKey generation successful');
    });

    test('Scenario 4: SignedPreKey generation and rotation', () async {
      await initializeTestDeviceIdentity(
        email: 'dave@test.com',
        credentialId: 'dave-cred',
        clientId: 'dave-client',
      );

      final keyManager = await SignalKeyManager.create();

      // Generate first signed prekey
      final signedPreKey1 = await keyManager.generateNewSignedPreKey(1);
      expect(signedPreKey1.id, equals(1));

      // Verify it's stored
      final loaded1 = await keyManager.signedPreKeyStore.loadSignedPreKey(1);
      expect(loaded1, isNotNull);
      expect(loaded1.id, equals(1));

      // Generate another signed prekey (simulating rotation)
      final signedPreKey2 = await keyManager.generateNewSignedPreKey(2);
      expect(signedPreKey2.id, equals(2));

      // Both should exist
      final allSignedPreKeys = await keyManager.signedPreKeyStore
          .loadAllStoredSignedPreKeys();
      expect(allSignedPreKeys.length, greaterThanOrEqualTo(2));

      print('✅ SignedPreKey rotation successful');
    });

    test('Scenario 5: Multiple users with isolated storage', () async {
      // User 1
      await initializeTestDeviceIdentity(
        email: 'user1@test.com',
        credentialId: 'user1-cred',
        clientId: 'user1-client',
      );

      final keyManager1 = await SignalKeyManager.create();
      final identity1 = await keyManager1.identityStore.getIdentityKeyPair();
      final publicKey1 = identity1.getPublicKey().serialize();

      // User 2
      await initializeTestDeviceIdentity(
        email: 'user2@test.com',
        credentialId: 'user2-cred',
        clientId: 'user2-client',
      );

      final keyManager2 = await SignalKeyManager.create();
      final identity2 = await keyManager2.identityStore.getIdentityKeyPair();
      final publicKey2 = identity2.getPublicKey().serialize();

      // Identities should be different
      expect(publicKey1, isNot(equals(publicKey2)));

      print('✅ Multi-user storage isolation verified');
    });

    test('Scenario 6: Full service stack creation', () async {
      await initializeTestDeviceIdentity(
        email: 'eve@test.com',
        credentialId: 'eve-cred',
        clientId: 'eve-client',
      );

      // Create entire service stack
      final keyManager = await SignalKeyManager.create();
      final sessionManager = await SessionManager.create(
        keyManager: keyManager,
      );
      final encryptionService = await EncryptionService.create(
        keyManager: keyManager,
        sessionManager: sessionManager,
      );

      // Generate keys for production use
      await keyManager.generatePreKeysInRange(1, 100);
      await keyManager.generateNewSignedPreKey(1);

      // Verify all components are ready
      expect(keyManager.isInitialized, isTrue);
      expect(sessionManager.isInitialized, isTrue);
      expect(encryptionService.isInitialized, isTrue);

      final preKeyCount = await keyManager.preKeyStore.getAllPreKeyIds();
      expect(preKeyCount, hasLength(100));

      final signedPreKeys = await keyManager.signedPreKeyStore
          .loadAllStoredSignedPreKeys();
      expect(signedPreKeys, isNotEmpty);

      print('✅ Full service stack ready for production use');
    });

    test('Scenario 7: PreKey exhaustion and regeneration', () async {
      await initializeTestDeviceIdentity(
        email: 'frank@test.com',
        credentialId: 'frank-cred',
        clientId: 'frank-client',
      );

      final keyManager = await SignalKeyManager.create();

      // Generate initial batch
      await keyManager.generatePreKeysInRange(1, 5);
      var preKeyIds = await keyManager.preKeyStore.getAllPreKeyIds();
      expect(preKeyIds, hasLength(5));

      // Simulate consumption of prekeys
      await keyManager.preKeyStore.removePreKey(1);
      await keyManager.preKeyStore.removePreKey(2);
      await keyManager.preKeyStore.removePreKey(3);

      preKeyIds = await keyManager.preKeyStore.getAllPreKeyIds();
      expect(preKeyIds, hasLength(2)); // Only 4 and 5 remain

      // Regenerate with new IDs (6-15 generates 15 keys: 6,7,8...20)
      await keyManager.generatePreKeysInRange(6, 15);

      preKeyIds = await keyManager.preKeyStore.getAllPreKeyIds();
      expect(preKeyIds, hasLength(17)); // 2 old (4,5) + 15 new (6-20)

      print('✅ PreKey regeneration successful');
    });

    test('Scenario 8: Service dependencies verified', () async {
      await initializeTestDeviceIdentity(
        email: 'grace@test.com',
        credentialId: 'grace-cred',
        clientId: 'grace-client',
      );

      final keyManager = await SignalKeyManager.create();
      final sessionManager = await SessionManager.create(
        keyManager: keyManager,
      );
      final encryptionService = await EncryptionService.create(
        keyManager: keyManager,
        sessionManager: sessionManager,
      );

      // SessionManager should have access to KeyManager's stores
      expect(sessionManager.preKeyStore, equals(keyManager.preKeyStore));
      expect(
        sessionManager.signedPreKeyStore,
        equals(keyManager.signedPreKeyStore),
      );
      expect(sessionManager.identityStore, equals(keyManager.identityStore));
      expect(sessionManager.senderKeyStore, equals(keyManager.senderKeyStore));

      // EncryptionService should also have access via delegation
      expect(encryptionService.preKeyStore, equals(keyManager.preKeyStore));
      expect(
        encryptionService.signedPreKeyStore,
        equals(keyManager.signedPreKeyStore),
      );
      expect(encryptionService.identityStore, equals(keyManager.identityStore));
      expect(
        encryptionService.senderKeyStore,
        equals(keyManager.senderKeyStore),
      );
      expect(
        encryptionService.sessionStore,
        equals(sessionManager.sessionStore),
      );

      print('✅ Service dependencies correctly wired');
    });
  });
}
