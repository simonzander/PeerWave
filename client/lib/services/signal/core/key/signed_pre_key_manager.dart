import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../../api_service.dart';
import '../../../socket_service.dart'
    if (dart.library.io) '../../../socket_service_native.dart';
import '../../../permanent_identity_key_store.dart';
import '../../../permanent_signed_pre_key_store.dart';

/// Manages Signal Protocol SignedPreKeys
///
/// Responsibilities:
/// - SignedPreKey generation and rotation
/// - SignedPreKey validation (signature verification)
/// - SignedPreKey upload to server
/// - Lifecycle management (rotation based on age)
class SignedPreKeyManager {
  final PermanentIdentityKeyStore identityStore;
  final PermanentSignedPreKeyStore signedPreKeyStore;

  SignedPreKeyManager(this.identityStore, this.signedPreKeyStore);

  /// Generate and store a new SignedPreKey
  /// Returns the generated SignedPreKey record
  Future<SignedPreKeyRecord> generateNewSignedPreKey(int keyId) async {
    debugPrint(
      '[SIGNED_PRE_KEY_MANAGER] Generating SignedPreKey with ID $keyId',
    );

    final identityKeyPair = await identityStore.getIdentityKeyPair();
    final signedPreKey = generateSignedPreKey(identityKeyPair, keyId);

    await signedPreKeyStore.storeSignedPreKey(keyId, signedPreKey);

    debugPrint('[SIGNED_PRE_KEY_MANAGER] ✓ Generated SignedPreKey');
    return signedPreKey;
  }

  /// Get latest SignedPreKey ID
  Future<int?> getLatestSignedPreKeyId() async {
    try {
      final keys = await signedPreKeyStore.loadSignedPreKeys();
      return keys.isNotEmpty ? keys.last.id : null;
    } catch (e) {
      debugPrint(
        '[SIGNED_PRE_KEY_MANAGER] Error getting latest SignedPreKey ID: $e',
      );
      return null;
    }
  }

  /// Check if SignedPreKey needs rotation (older than 7 days)
  Future<bool> needsSignedPreKeyRotation() async {
    return await signedPreKeyStore.needsRotation();
  }

  /// Rotate SignedPreKey and upload to server
  Future<void> rotateSignedPreKey() async {
    try {
      debugPrint('[SIGNED_PRE_KEY_MANAGER] Starting SignedPreKey rotation...');

      final identityKeyPair = await identityStore.getIdentityKeyPair();
      await signedPreKeyStore.rotateSignedPreKey(identityKeyPair);

      debugPrint('[SIGNED_PRE_KEY_MANAGER] ✓ SignedPreKey rotation completed');
    } catch (e, stackTrace) {
      debugPrint(
        '[SIGNED_PRE_KEY_MANAGER] Error during SignedPreKey rotation: $e',
      );
      debugPrint('[SIGNED_PRE_KEY_MANAGER] Stack trace: $stackTrace');
      rethrow;
    }
  }

  /// Check and perform SignedPreKey rotation if needed
  Future<void> checkAndRotateSignedPreKey() async {
    try {
      final needsRotation = await needsSignedPreKeyRotation();
      if (needsRotation) {
        debugPrint('[SIGNED_PRE_KEY_MANAGER] SignedPreKey rotation needed');
        await rotateSignedPreKey();
      } else {
        debugPrint(
          '[SIGNED_PRE_KEY_MANAGER] SignedPreKey rotation not needed (< 7 days old)',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('[SIGNED_PRE_KEY_MANAGER] Error during rotation check: $e');
      debugPrint('[SIGNED_PRE_KEY_MANAGER] Stack trace: $stackTrace');
    }
  }

  /// Upload SignedPreKey to server
  Future<void> uploadSignedPreKey(SignedPreKeyRecord signedPreKey) async {
    debugPrint('[SIGNED_PRE_KEY_MANAGER] Uploading SignedPreKey to server...');

    final response = await ApiService.post(
      '/signal/signedprekey',
      data: {
        'id': signedPreKey.id,
        'data': base64Encode(signedPreKey.getKeyPair().publicKey.serialize()),
        'signature': base64Encode(signedPreKey.signature),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to upload SignedPreKey: ${response.statusCode}');
    }

    debugPrint('[SIGNED_PRE_KEY_MANAGER] ✓ SignedPreKey uploaded');
  }

  /// Validate owner's own SignedPreKey on the server
  ///
  /// Ensures the device owner's SignedPreKey has valid signature.
  /// Auto-recovers by regenerating if signature is invalid.
  Future<void> validateOwnSignedPreKey(Map<String, dynamic> status) async {
    try {
      debugPrint(
        '[SIGNED_PRE_KEY_MANAGER] Validating own SignedPreKey on server...',
      );

      // Get local identity key pair
      final identityKeyPair = await identityStore.getIdentityKeyPair();
      final localIdentityKey = identityKeyPair.getPublicKey();
      final localPublicKey = Curve.decodePoint(localIdentityKey.serialize(), 0);

      // Get server's SignedPreKey data
      final signedPreKeyData = status['signedPreKey'];
      if (signedPreKeyData == null) {
        debugPrint(
          '[SIGNED_PRE_KEY_MANAGER] ⚠️ No SignedPreKey on server to validate',
        );
        return;
      }

      final signedPreKeyPublicBase64 =
          signedPreKeyData['signed_prekey_data'] as String?;
      final signedPreKeySignatureBase64 =
          signedPreKeyData['signed_prekey_signature'] as String?;

      if (signedPreKeyPublicBase64 == null ||
          signedPreKeySignatureBase64 == null) {
        debugPrint(
          '[SIGNED_PRE_KEY_MANAGER] ⚠️ Incomplete SignedPreKey data on server',
        );
        await regenerateAndUploadSignedPreKey(identityKeyPair);
        return;
      }

      // Decode and validate signature
      final signedPreKeyPublicBytes = base64Decode(signedPreKeyPublicBase64);
      final signedPreKeySignatureBytes = base64Decode(
        signedPreKeySignatureBase64,
      );
      final signedPreKeyPublic = Curve.decodePoint(signedPreKeyPublicBytes, 0);

      final isValid = Curve.verifySignature(
        localPublicKey,
        signedPreKeyPublic.serialize(),
        signedPreKeySignatureBytes,
      );

      if (!isValid) {
        debugPrint(
          '[SIGNED_PRE_KEY_MANAGER] ❌ CRITICAL: SignedPreKey signature INVALID!',
        );
        await regenerateAndUploadSignedPreKey(identityKeyPair);
      } else {
        debugPrint('[SIGNED_PRE_KEY_MANAGER] ✓ SignedPreKey signature valid');
      }

      // Check signature length
      if (signedPreKeySignatureBytes.length != 64) {
        debugPrint(
          '[SIGNED_PRE_KEY_MANAGER] ⚠️ SignedPreKey signature has invalid length: ${signedPreKeySignatureBytes.length}',
        );
        await regenerateAndUploadSignedPreKey(identityKeyPair);
      }
    } catch (e, stackTrace) {
      debugPrint('[SIGNED_PRE_KEY_MANAGER] ⚠️ Error validating own keys: $e');
      debugPrint('[SIGNED_PRE_KEY_MANAGER] Stack trace: $stackTrace');
    }
  }

  /// Regenerate and upload SignedPreKey (internal helper for validation)
  Future<void> regenerateAndUploadSignedPreKey(
    IdentityKeyPair identityKeyPair,
  ) async {
    debugPrint(
      '[SIGNED_PRE_KEY_MANAGER] → Regenerating and uploading new SignedPreKey...',
    );

    final newSignedPreKey = generateSignedPreKey(identityKeyPair, 0);
    await signedPreKeyStore.storeSignedPreKey(
      newSignedPreKey.id,
      newSignedPreKey,
    );

    SocketService().emit("storeSignedPreKey", {
      'id': newSignedPreKey.id,
      'data': base64Encode(newSignedPreKey.getKeyPair().publicKey.serialize()),
      'signature': base64Encode(newSignedPreKey.signature),
    });

    debugPrint(
      '[SIGNED_PRE_KEY_MANAGER] ✓ New SignedPreKey uploaded to server',
    );
  }
}
