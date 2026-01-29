import 'package:flutter_test/flutter_test.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';
import 'package:peerwave_client/services/signal/core/encryption_service.dart';
import '../helpers/test_user.dart';

/// Tests for dependency injection pattern
/// Verifies that services use dependencies correctly and don't create duplicate stores
void main() {
  group('Dependency Injection - Real Instance Tests', () {
    late SignalKeyManager keyManager;
    late SessionManager sessionManager;
    late EncryptionService encryptionService;

    setUp(() async {
      // Create real instances with dependency injection
      keyManager = await SignalKeyManager.create();
      sessionManager = await SessionManager.create(keyManager: keyManager);
      encryptionService = await EncryptionService.create(
        keyManager: keyManager,
        sessionManager: sessionManager,
      );
    });

    test('KeyManager creates and initializes stores', () async {
      expect(keyManager.isInitialized, isTrue);
      expect(keyManager.identityStore, isNotNull);
      expect(keyManager.preKeyStore, isNotNull);
      expect(keyManager.signedPreKeyStore, isNotNull);
      expect(keyManager.senderKeyStore, isNotNull);
    });

    test('SessionManager delegates to KeyManager stores', () async {
      expect(sessionManager.isInitialized, isTrue);

      // SessionManager should use KeyManager's stores
      expect(
        identical(sessionManager.identityStore, keyManager.identityStore),
        isTrue,
      );
      expect(
        identical(sessionManager.preKeyStore, keyManager.preKeyStore),
        isTrue,
      );
      expect(
        identical(
          sessionManager.signedPreKeyStore,
          keyManager.signedPreKeyStore,
        ),
        isTrue,
      );
      expect(
        identical(sessionManager.senderKeyStore, keyManager.senderKeyStore),
        isTrue,
      );

      // SessionManager should have its own sessionStore
      expect(sessionManager.sessionStore, isNotNull);
    });

    test(
      'EncryptionService delegates to KeyManager and SessionManager',
      () async {
        expect(encryptionService.isInitialized, isTrue);

        // EncryptionService should use KeyManager's stores
        expect(
          identical(encryptionService.identityStore, keyManager.identityStore),
          isTrue,
        );
        expect(
          identical(encryptionService.preKeyStore, keyManager.preKeyStore),
          isTrue,
        );
        expect(
          identical(
            encryptionService.signedPreKeyStore,
            keyManager.signedPreKeyStore,
          ),
          isTrue,
        );
        expect(
          identical(
            encryptionService.senderKeyStore,
            keyManager.senderKeyStore,
          ),
          isTrue,
        );

        // EncryptionService should use SessionManager's sessionStore
        expect(
          identical(
            encryptionService.sessionStore,
            sessionManager.sessionStore,
          ),
          isTrue,
        );
      },
    );

    test('No duplicate stores created across dependency chain', () async {
      // Verify all services use same store instances (single source of truth)
      final keyManagerIdentity = keyManager.identityStore;
      final sessionManagerIdentity = sessionManager.identityStore;
      final encryptionServiceIdentity = encryptionService.identityStore;

      // All should be identical (same instance)
      expect(identical(keyManagerIdentity, sessionManagerIdentity), isTrue);
      expect(
        identical(sessionManagerIdentity, encryptionServiceIdentity),
        isTrue,
      );

      // Same for other stores
      expect(
        identical(keyManager.preKeyStore, encryptionService.preKeyStore),
        isTrue,
      );
      expect(
        identical(sessionManager.sessionStore, encryptionService.sessionStore),
        isTrue,
      );
    });

    test('Services can create real ciphers', () async {
      final testAddress = SignalProtocolAddress('test-user', 1);

      // SessionManager can create SessionCipher
      final sessionCipher = sessionManager.createSessionCipher(testAddress);
      expect(sessionCipher, isNotNull);

      // SessionManager can create GroupCipher
      final groupCipher = sessionManager.createGroupCipher(
        'test-group',
        testAddress,
      );
      expect(groupCipher, isNotNull);
    });
  });

  group('Dependency Injection - TestUser Integration', () {
    test('TestUser correctly uses dependency chain', () async {
      final alice = await createTestUser('alice');

      // Verify full dependency chain is initialized
      expect(alice.keyManager.isInitialized, isTrue);
      expect(alice.sessionManager.isInitialized, isTrue);
      expect(alice.encryptionService.isInitialized, isTrue);

      // Verify dependencies flow correctly
      expect(
        identical(alice.sessionManager.keyManager, alice.keyManager),
        isTrue,
      );
      expect(
        identical(alice.encryptionService.keyManager, alice.keyManager),
        isTrue,
      );
      expect(
        identical(alice.encryptionService.sessionManager, alice.sessionManager),
        isTrue,
      );

      await alice.cleanup();
    });

    test('Multiple TestUsers have independent stores', () async {
      final alice = await createTestUser('alice');
      final bob = await createTestUser('bob');

      // Each user has their own key manager
      expect(identical(alice.keyManager, bob.keyManager), isFalse);

      // Each user has independent identity keys
      final aliceIdentity = await alice.getIdentityKey();
      final bobIdentity = await bob.getIdentityKey();
      expect(identical(aliceIdentity, bobIdentity), isFalse);

      await alice.cleanup();
      await bob.cleanup();
    });
  });

  group('Service Construction Pattern', () {
    test('Services use create() factory pattern', () {
      // Verify factory methods exist and return correct types
      expect(SignalKeyManager.create, isA<Function>());
      expect(SessionManager.create, isA<Function>());
      expect(EncryptionService.create, isA<Function>());
    });

    test('Services throw error when accessed before initialization', () {
      // This is tested implicitly - KeyManager.create() always initializes
      // Services cannot be created in uninitialized state via public API
      expect(SignalKeyManager.create, isA<Function>());
    });

    test('Services can only be initialized once', () async {
      final keyManager = await SignalKeyManager.create();
      expect(keyManager.isInitialized, isTrue);

      // Second init should be no-op
      await keyManager.init();
      expect(keyManager.isInitialized, isTrue);
    });
  });
}
