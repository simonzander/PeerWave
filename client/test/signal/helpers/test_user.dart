import 'dart:typed_data';
import 'dart:convert';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';
import 'package:peerwave_client/services/signal/core/encryption_service.dart';

/// Test user with full Signal Protocol setup
/// Used for integration testing real encryption/decryption flows
class TestUser {
  final String userId;
  final int deviceId;
  late SignalKeyManager keyManager;
  late SessionManager sessionManager;
  late EncryptionService encryptionService;

  bool _initialized = false;

  TestUser({required this.userId, this.deviceId = 1});

  SignalProtocolAddress get address => SignalProtocolAddress(userId, deviceId);

  /// Initialize all services with real stores and keys
  Future<void> initialize() async {
    if (_initialized) return;

    // Create dependency chain
    keyManager = await SignalKeyManager.create();
    sessionManager = await SessionManager.create(keyManager: keyManager);
    encryptionService = await EncryptionService.create(
      keyManager: keyManager,
      sessionManager: sessionManager,
    );

    // Ensure keys exist (generates if needed)
    await keyManager.getIdentityKeyPair();

    _initialized = true;
  }

  /// Get identity key for this user
  Future<IdentityKey> getIdentityKey() async {
    final identityKeyPair = await keyManager.identityStore.getIdentityKeyPair();
    return identityKeyPair.getPublicKey();
  }

  /// Get identity key pair for this user
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    return await keyManager.identityStore.getIdentityKeyPair();
  }

  /// Get registration ID
  Future<int> getRegistrationId() async {
    return await keyManager.identityStore.getLocalRegistrationId();
  }

  /// Build PreKey bundle for session establishment
  Future<PreKeyBundle> getPreKeyBundle() async {
    // Get registration ID and identity
    final registrationId = await keyManager.identityStore
        .getLocalRegistrationId();
    final identityKeyPair = await keyManager.identityStore.getIdentityKeyPair();
    final identityKey = identityKeyPair.getPublicKey();

    // Get a PreKey
    final preKeyIds = await keyManager.preKeyStore.getAllPreKeyIds();
    if (preKeyIds.isEmpty) {
      throw StateError('No PreKeys available for user $userId');
    }
    final preKeyId = preKeyIds.first;
    final preKeyRecord = await keyManager.preKeyStore.loadPreKey(preKeyId);

    // Get SignedPreKey
    final signedPreKeys = await keyManager.signedPreKeyStore
        .loadSignedPreKeys();
    if (signedPreKeys.isEmpty) {
      throw StateError('No SignedPreKeys available for user $userId');
    }
    final signedPreKey = signedPreKeys.first;

    return PreKeyBundle(
      registrationId,
      deviceId,
      preKeyId,
      preKeyRecord.getKeyPair().publicKey,
      signedPreKey.id,
      signedPreKey.getKeyPair().publicKey,
      signedPreKey.signature,
      identityKey,
    );
  }

  /// Encrypt message to another user
  Future<CiphertextMessage> encryptTo(
    TestUser recipient,
    String message,
  ) async {
    final plaintext = Uint8List.fromList(message.codeUnits);
    return await encryptionService.encryptMessage(
      recipientAddress: recipient.address,
      plaintext: plaintext,
    );
  }

  /// Decrypt message from another user
  Future<String> decryptFrom(
    TestUser sender,
    CiphertextMessage ciphertext,
  ) async {
    final payload = base64Encode(ciphertext.serialize());
    return await encryptionService.decryptMessage(
      senderAddress: sender.address,
      payload: payload,
      cipherType: ciphertext.getType(),
    );
  }

  /// Build session with another user
  Future<void> buildSessionWith(TestUser otherUser) async {
    final bundle = await otherUser.getPreKeyBundle();
    await sessionManager.buildSessionFromPreKeyBundle(
      otherUser.userId,
      otherUser.deviceId,
      bundle,
    );
  }

  /// Check if session exists with another user
  Future<bool> hasSessionWith(TestUser otherUser) async {
    return await sessionManager.sessionStore.containsSession(otherUser.address);
  }

  /// Delete session with another user
  Future<void> deleteSessionWith(TestUser otherUser) async {
    await sessionManager.sessionStore.deleteSession(otherUser.address);
  }

  /// Clean up (for test teardown)
  Future<void> cleanup() async {
    // Clean up stores if needed
    // Note: In-memory stores will be garbage collected
    _initialized = false;
  }
}

/// Create a test user with specified ID
Future<TestUser> createTestUser(String userId, {int deviceId = 1}) async {
  final user = TestUser(userId: userId, deviceId: deviceId);
  await user.initialize();
  return user;
}
