import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'dart:convert';
import '../../permanent_session_store.dart';
import '../../permanent_pre_key_store.dart';
import '../../permanent_signed_pre_key_store.dart';
import '../../permanent_identity_key_store.dart';
import '../../sender_key_store.dart';

import 'key_manager.dart';
import 'session_manager.dart';

/// Handles Signal Protocol encryption and decryption operations
///
/// Responsibilities:
/// - 1-to-1 message encryption/decryption via SessionCipher
/// - Group message encryption/decryption via GroupCipher
/// - PreKey message handling
/// - Signal message handling
/// - Cipher creation and management
///
/// Dependencies:
/// - KeyManager: For identity/preKey/signedPreKey/senderKey stores
/// - SessionManager: For session store
///
/// Usage:
/// ```dart
/// // Self-initializing factory with dependencies
/// final encryptionService = await EncryptionService.create(
///   keyManager: keyManager,
///   sessionManager: sessionManager,
/// );
/// ```
class EncryptionService {
  final SignalKeyManager keyManager;
  final SessionManager sessionManager;

  bool _initialized = false;

  // Delegate to SessionManager and KeyManager for stores
  PermanentSessionStore get sessionStore => sessionManager.sessionStore;
  PermanentPreKeyStore get preKeyStore => keyManager.preKeyStore;
  PermanentSignedPreKeyStore get signedPreKeyStore =>
      keyManager.signedPreKeyStore;
  PermanentIdentityKeyStore get identityStore => keyManager.identityStore;
  PermanentSenderKeyStore get senderKeyStore => keyManager.senderKeyStore;

  bool get isInitialized => _initialized;

  // Private constructor with dependencies
  EncryptionService._({required this.keyManager, required this.sessionManager});

  /// Self-initializing factory - requires KeyManager and SessionManager
  static Future<EncryptionService> create({
    required SignalKeyManager keyManager,
    required SessionManager sessionManager,
  }) async {
    final service = EncryptionService._(
      keyManager: keyManager,
      sessionManager: sessionManager,
    );
    await service.init();
    return service;
  }

  /// Initialize (no stores to create - all from dependencies)
  Future<void> init() async {
    if (_initialized) {
      debugPrint('[ENCRYPTION_SERVICE] Already initialized');
      return;
    }

    debugPrint('[ENCRYPTION_SERVICE] Initialized (using dependency stores)');
    _initialized = true;
  }

  // ============================================================================
  // 1-TO-1 ENCRYPTION
  // ============================================================================

  /// Encrypt message for 1-to-1 communication
  /// Returns CiphertextMessage (can be PreKey or Signal message)
  Future<CiphertextMessage> encryptMessage({
    required SignalProtocolAddress recipientAddress,
    required Uint8List plaintext,
  }) async {
    try {
      debugPrint(
        '[ENCRYPTION_SERVICE] Encrypting message for ${recipientAddress.getName()}:${recipientAddress.getDeviceId()}',
      );

      final sessionCipher = SessionCipher(
        sessionStore,
        preKeyStore,
        signedPreKeyStore,
        identityStore,
        recipientAddress,
      );

      final ciphertext = await sessionCipher.encrypt(plaintext);

      debugPrint(
        '[ENCRYPTION_SERVICE] ✓ Message encrypted (type: ${ciphertext.getType()})',
      );

      return ciphertext;
    } catch (e) {
      debugPrint('[ENCRYPTION_SERVICE] Error encrypting message: $e');
      rethrow;
    }
  }

  // ============================================================================
  // 1-TO-1 DECRYPTION
  // ============================================================================

  /// Decrypt message based on cipher type
  /// Handles both PreKey and Signal messages automatically
  Future<String> decryptMessage({
    required SignalProtocolAddress senderAddress,
    required String payload, // base64-encoded
    required int cipherType,
  }) async {
    try {
      // Handle unencrypted system messages
      if (cipherType == 0) {
        debugPrint(
          '[ENCRYPTION_SERVICE] Processing unencrypted system message',
        );
        return payload;
      }

      final serialized = base64Decode(payload);
      Uint8List plaintext;

      if (cipherType == CiphertextMessage.prekeyType) {
        plaintext = await _decryptPreKeyMessage(
          senderAddress: senderAddress,
          serialized: serialized,
        );
      } else if (cipherType == CiphertextMessage.whisperType) {
        plaintext = await _decryptSignalMessage(
          senderAddress: senderAddress,
          serialized: serialized,
        );
      } else {
        throw Exception('Unknown cipher type: $cipherType');
      }

      return utf8.decode(plaintext);
    } catch (e) {
      debugPrint('[ENCRYPTION_SERVICE] Error decrypting message: $e');
      rethrow;
    }
  }

  /// Internal: Decrypt PreKey message
  Future<Uint8List> _decryptPreKeyMessage({
    required SignalProtocolAddress senderAddress,
    required Uint8List serialized,
  }) async {
    debugPrint(
      '[ENCRYPTION_SERVICE] Decrypting PreKey message from ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
    );

    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      senderAddress,
    );

    final preKeyMsg = PreKeySignalMessage(serialized);
    final plaintext = await sessionCipher.decryptWithCallback(
      preKeyMsg,
      (pt) {},
    );

    debugPrint('[ENCRYPTION_SERVICE] ✓ PreKey message decrypted');
    return plaintext;
  }

  /// Internal: Decrypt Signal message (normal encrypted message)
  Future<Uint8List> _decryptSignalMessage({
    required SignalProtocolAddress senderAddress,
    required Uint8List serialized,
  }) async {
    debugPrint(
      '[ENCRYPTION_SERVICE] Decrypting Signal message from ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
    );

    final sessionCipher = SessionCipher(
      sessionStore,
      preKeyStore,
      signedPreKeyStore,
      identityStore,
      senderAddress,
    );

    final signalMsg = SignalMessage.fromSerialized(serialized);
    final plaintext = await sessionCipher.decryptFromSignal(signalMsg);

    debugPrint('[ENCRYPTION_SERVICE] ✓ Signal message decrypted');
    return plaintext;
  }

  // ============================================================================
  // GROUP ENCRYPTION
  // ============================================================================

  /// Encrypt message for group using sender key
  /// Returns base64-encoded ciphertext
  Future<String> encryptGroupMessage({
    required String groupId,
    required String currentUserId,
    required int currentDeviceId,
    required String message,
  }) async {
    try {
      debugPrint(
        '[ENCRYPTION_SERVICE] Encrypting group message for group $groupId',
      );

      final senderAddress = SignalProtocolAddress(
        currentUserId,
        currentDeviceId,
      );

      final senderKeyName = SenderKeyName(groupId, senderAddress);

      // Verify sender key exists
      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );
      if (!hasSenderKey) {
        throw Exception('No sender key found for group $groupId');
      }

      // Create group cipher
      final groupCipher = GroupCipher(senderKeyStore, senderKeyName);

      // Encrypt message
      final plaintext = Uint8List.fromList(utf8.encode(message));
      final ciphertext = await groupCipher.encrypt(plaintext);

      debugPrint('[ENCRYPTION_SERVICE] ✓ Group message encrypted');
      return base64Encode(ciphertext);
    } catch (e) {
      debugPrint('[ENCRYPTION_SERVICE] Error encrypting group message: $e');
      rethrow;
    }
  }

  /// Decrypt group message using sender key
  /// Returns decrypted plaintext string
  Future<String> decryptGroupMessage({
    required String groupId,
    required SignalProtocolAddress senderAddress,
    required String encryptedData, // base64-encoded
  }) async {
    try {
      debugPrint(
        '[ENCRYPTION_SERVICE] Decrypting group message from ${senderAddress.getName()}:${senderAddress.getDeviceId()}',
      );

      final senderKeyName = SenderKeyName(groupId, senderAddress);

      // Verify sender key exists
      final hasSenderKey = await senderKeyStore.containsSenderKey(
        senderKeyName,
      );
      if (!hasSenderKey) {
        throw Exception(
          'No sender key found for sender ${senderAddress.getName()} in group $groupId',
        );
      }

      // Create group cipher
      final groupCipher = GroupCipher(senderKeyStore, senderKeyName);

      // Decrypt message
      final ciphertext = base64Decode(encryptedData);
      final plaintext = await groupCipher.decrypt(ciphertext);

      debugPrint('[ENCRYPTION_SERVICE] ✓ Group message decrypted');
      return utf8.decode(plaintext);
    } catch (e) {
      debugPrint('[ENCRYPTION_SERVICE] Error decrypting group message: $e');
      rethrow;
    }
  }
}
