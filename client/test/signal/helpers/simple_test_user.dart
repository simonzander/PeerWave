import 'dart:typed_data';
import 'dart:convert';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Lightweight test user using in-memory stores (no database required)
/// Perfect for fast unit/integration tests - no API, no Socket, no Database needed!
class TestUser {
  final String userId;
  final int deviceId;

  late InMemoryIdentityKeyStore identityStore;
  late InMemoryPreKeyStore preKeyStore;
  late InMemorySignedPreKeyStore signedPreKeyStore;
  late InMemorySessionStore sessionStore;
  late InMemorySenderKeyStore senderKeyStore;

  late IdentityKeyPair identityKeyPair;
  late int registrationId;
  final List<int> _preKeyIds = [];

  bool _initialized = false;

  TestUser({required this.userId, this.deviceId = 1});

  SignalProtocolAddress get address => SignalProtocolAddress(userId, deviceId);

  /// Initialize with in-memory stores (fast, no database)
  Future<void> initialize() async {
    if (_initialized) return;

    // Create in-memory stores (provided by libsignal)
    identityStore = InMemoryIdentityKeyStore(
      generateIdentityKeyPair(),
      generateRegistrationId(false),
    );
    preKeyStore = InMemoryPreKeyStore();
    signedPreKeyStore = InMemorySignedPreKeyStore();
    sessionStore = InMemorySessionStore();
    senderKeyStore = InMemorySenderKeyStore();

    // Get generated identity
    identityKeyPair = await identityStore.getIdentityKeyPair();
    registrationId = await identityStore.getLocalRegistrationId();

    // Generate signed prekey
    final signedPreKey = generateSignedPreKey(identityKeyPair, 1);
    await signedPreKeyStore.storeSignedPreKey(signedPreKey.id, signedPreKey);

    // Generate prekeys (10 keys for testing)
    final preKeys = generatePreKeys(1, 10);
    for (final preKey in preKeys) {
      await preKeyStore.storePreKey(preKey.id, preKey);
      _preKeyIds.add(preKey.id);
    }

    _initialized = true;
  }

  /// Get identity key
  Future<IdentityKey> getIdentityKey() async {
    return identityKeyPair.getPublicKey();
  }

  /// Build PreKey bundle for session establishment
  Future<PreKeyBundle> getPreKeyBundle() async {
    // Get a PreKey
    if (_preKeyIds.isEmpty) {
      throw StateError('No PreKeys available for user $userId');
    }
    final preKeyId = _preKeyIds.first;
    final preKeyRecord = await preKeyStore.loadPreKey(preKeyId);

    // Get SignedPreKey
    final signedPreKeys = await signedPreKeyStore.loadSignedPreKeys();
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
      identityKeyPair.getPublicKey(),
    );
  }

  /// Encrypt message to another user
  Future<CiphertextMessage> encryptTo(
    TestUser recipient,
    String message,
  ) async {
    final plaintext = Uint8List.fromList(utf8.encode(message));

    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      recipient.address,
    );

    return await sessionCipher.encrypt(plaintext);
  }

  /// Decrypt message from another user
  Future<String> decryptFrom(
    TestUser sender,
    CiphertextMessage ciphertext,
  ) async {
    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      sender.address,
    );

    Uint8List plaintext;

    if (ciphertext.getType() == CiphertextMessage.prekeyType) {
      final preKeyMessage = PreKeySignalMessage(ciphertext.serialize());
      plaintext = await sessionCipher.decryptWithCallback(
        preKeyMessage,
        (plaintext) {},
      );
    } else {
      final signalMessage = SignalMessage.fromSerialized(
        ciphertext.serialize(),
      );
      plaintext = await sessionCipher.decryptFromSignal(signalMessage);
    }

    return utf8.decode(plaintext);
  }

  /// Build session with another user
  Future<void> buildSessionWith(TestUser otherUser) async {
    final bundle = await otherUser.getPreKeyBundle();

    final sessionBuilder = SessionBuilder(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      otherUser.address,
    );

    await sessionBuilder.processPreKeyBundle(bundle);
  }

  /// Check if session exists with another user
  Future<bool> hasSessionWith(TestUser otherUser) async {
    return await sessionStore.containsSession(otherUser.address);
  }

  /// Delete session with another user
  Future<void> deleteSessionWith(TestUser otherUser) async {
    await sessionStore.deleteSession(otherUser.address);
  }

  /// Clean up (for test teardown)
  Future<void> cleanup() async {
    _initialized = false;
  }
}

/// Create a test user with in-memory stores
Future<TestUser> createTestUser(String userId, {int deviceId = 1}) async {
  final user = TestUser(userId: userId, deviceId: deviceId);
  await user.initialize();
  return user;
}
