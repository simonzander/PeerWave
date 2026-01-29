import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:peerwave_client/services/signal/core/key_manager.dart';
import 'package:peerwave_client/services/signal/core/session_manager.dart';
import 'package:peerwave_client/services/signal/core/encryption_service.dart';

/// Test wrapper that mirrors SignalKeyManager functionality with in-memory stores
/// This lets us test ALL the KeyManager logic without database dependencies
class TestKeyManagerWrapper {
  final InMemoryIdentityKeyStore identityStore;
  final InMemoryPreKeyStore preKeyStore;
  final InMemorySignedPreKeyStore signedPreKeyStore;
  final InMemorySenderKeyStore senderKeyStore;

  TestKeyManagerWrapper({
    required this.identityStore,
    required this.preKeyStore,
    required this.signedPreKeyStore,
    required this.senderKeyStore,
  });

  /// Factory to create test wrapper with in-memory stores
  static Future<TestKeyManagerWrapper> create() async {
    // Create in-memory stores
    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);

    final identityStore = InMemoryIdentityKeyStore(
      identityKeyPair,
      registrationId,
    );
    final preKeyStore = InMemoryPreKeyStore();
    final signedPreKeyStore = InMemorySignedPreKeyStore();
    final senderKeyStore = InMemorySenderKeyStore();

    // Generate initial keys
    final signedPreKey = generateSignedPreKey(identityKeyPair, 1);
    await signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);

    final preKeys = generatePreKeys(1, 10);
    for (final preKey in preKeys) {
      await preKeyStore.storePreKey(preKey.id, preKey);
    }

    return TestKeyManagerWrapper(
      identityStore: identityStore,
      preKeyStore: preKeyStore,
      signedPreKeyStore: signedPreKeyStore,
      senderKeyStore: senderKeyStore,
    );
  }

  // Mirror KeyManager methods for testing
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    return await identityStore.getIdentityKeyPair();
  }

  Future<IdentityKey> getIdentityKey() async {
    final keyPair = await getIdentityKeyPair();
    return keyPair.getPublicKey();
  }

  Future<int> getRegistrationId() async {
    return await identityStore.getLocalRegistrationId();
  }

  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    return await preKeyStore.loadPreKey(preKeyId);
  }

  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async {
    await preKeyStore.storePreKey(preKeyId, record);
  }

  Future<bool> containsPreKey(int preKeyId) async {
    return await preKeyStore.containsPreKey(preKeyId);
  }

  Future<void> removePreKey(int preKeyId) async {
    await preKeyStore.removePreKey(preKeyId);
  }

  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    return await signedPreKeyStore.loadSignedPreKey(signedPreKeyId);
  }

  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    return await signedPreKeyStore.loadSignedPreKeys();
  }

  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) async {
    await signedPreKeyStore.storeSignedPreKey(signedPreKeyId, record);
  }

  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    return await signedPreKeyStore.containsSignedPreKey(signedPreKeyId);
  }

  Future<void> removeSignedPreKey(int signedPreKeyId) async {
    await signedPreKeyStore.removeSignedPreKey(signedPreKeyId);
  }

  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    return await identityStore.getIdentity(address);
  }

  Future<bool> saveIdentity(
    SignalProtocolAddress address,
    IdentityKey identityKey,
  ) async {
    return await identityStore.saveIdentity(address, identityKey);
  }

  Future<bool> isTrustedIdentity(
    SignalProtocolAddress address,
    IdentityKey identityKey,
    Direction direction,
  ) async {
    return await identityStore.isTrustedIdentity(
      address,
      identityKey,
      direction,
    );
  }
}

/// Test wrapper for SessionManager functionality
class TestSessionManagerWrapper {
  final TestKeyManagerWrapper keyManager;
  final InMemorySessionStore sessionStore;

  TestSessionManagerWrapper({
    required this.keyManager,
    required this.sessionStore,
  });

  static Future<TestSessionManagerWrapper> create({
    required TestKeyManagerWrapper keyManager,
  }) async {
    return TestSessionManagerWrapper(
      keyManager: keyManager,
      sessionStore: InMemorySessionStore(),
    );
  }

  // Mirror SessionManager methods
  SessionCipher createSessionCipher(SignalProtocolAddress address) {
    return SessionCipher(
      sessionStore,
      keyManager.preKeyStore,
      keyManager.signedPreKeyStore,
      keyManager.identityStore,
      address,
    );
  }

  GroupCipher createGroupCipher(
    String groupId,
    SignalProtocolAddress senderAddress,
  ) {
    final senderKeyName = SenderKeyName(groupId, senderAddress);
    return GroupCipher(keyManager.senderKeyStore, senderKeyName);
  }

  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    return await sessionStore.loadSession(address);
  }

  Future<void> storeSession(
    SignalProtocolAddress address,
    SessionRecord record,
  ) async {
    await sessionStore.storeSession(address, record);
  }

  Future<bool> containsSession(SignalProtocolAddress address) async {
    return await sessionStore.containsSession(address);
  }

  Future<void> deleteSession(SignalProtocolAddress address) async {
    await sessionStore.deleteSession(address);
  }

  Future<void> deleteAllSessions(String name) async {
    await sessionStore.deleteAllSessions(name);
  }

  Future<List<int>> getSubDeviceSessions(String name) async {
    return await sessionStore.getSubDeviceSessions(name);
  }
}

/// Test wrapper for EncryptionService functionality
class TestEncryptionServiceWrapper {
  final TestKeyManagerWrapper keyManager;
  final TestSessionManagerWrapper sessionManager;

  TestEncryptionServiceWrapper({
    required this.keyManager,
    required this.sessionManager,
  });

  static Future<TestEncryptionServiceWrapper> create({
    required TestKeyManagerWrapper keyManager,
    required TestSessionManagerWrapper sessionManager,
  }) async {
    return TestEncryptionServiceWrapper(
      keyManager: keyManager,
      sessionManager: sessionManager,
    );
  }

  // Mirror EncryptionService methods
  Future<CiphertextMessage> encryptMessage({
    required SignalProtocolAddress recipientAddress,
    required Uint8List plaintext,
  }) async {
    final sessionCipher = sessionManager.createSessionCipher(recipientAddress);
    return await sessionCipher.encrypt(plaintext);
  }

  Future<Uint8List> decryptMessage({
    required SignalProtocolAddress senderAddress,
    required Uint8List payload,
    required int messageType,
  }) async {
    final sessionCipher = sessionManager.createSessionCipher(senderAddress);

    if (messageType == CiphertextMessage.prekeyType) {
      final preKeyMessage = PreKeySignalMessage(payload);
      return await sessionCipher.decryptWithCallback(
        preKeyMessage,
        (plaintext) {},
      );
    } else {
      final signalMessage = SignalMessage.fromSerialized(payload);
      return await sessionCipher.decryptFromSignal(signalMessage);
    }
  }

  Future<Uint8List> encryptGroupMessage({
    required String groupId,
    required SignalProtocolAddress senderAddress,
    required Uint8List plaintext,
  }) async {
    final groupCipher = sessionManager.createGroupCipher(
      groupId,
      senderAddress,
    );
    return await groupCipher.encrypt(plaintext);
  }

  Future<Uint8List> decryptGroupMessage({
    required String groupId,
    required SignalProtocolAddress senderAddress,
    required Uint8List ciphertext,
  }) async {
    final groupCipher = sessionManager.createGroupCipher(
      groupId,
      senderAddress,
    );
    return await groupCipher.decrypt(ciphertext);
  }
}
