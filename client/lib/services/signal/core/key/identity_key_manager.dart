import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../../../api_service.dart';
import '../../../permanent_identity_key_store.dart';

/// Manages Signal Protocol Identity Keys
///
/// Responsibilities:
/// - Identity key pair generation and storage
/// - Identity key validation
/// - Identity key upload to server
class IdentityKeyManager {
  final PermanentIdentityKeyStore identityStore;

  IdentityKeyManager(this.identityStore);

  /// Ensure identity key pair exists, generate if missing
  /// Returns the identity key pair
  ///
  /// Note: The identity store handles generation automatically via getIdentityKeyPairData()
  /// This method just ensures the key pair is loaded
  Future<IdentityKeyPair> ensureIdentityKeyExists() async {
    try {
      // This will auto-generate if missing
      return await identityStore.getIdentityKeyPair();
    } catch (e) {
      debugPrint(
        '[IDENTITY_KEY_MANAGER] Error ensuring identity key exists: $e',
      );
      rethrow;
    }
  }

  /// Get local identity public key as base64 string
  Future<String?> getLocalIdentityPublicKey() async {
    try {
      final identity = await identityStore.getIdentityKeyPairData();
      return identity['publicKey'];
    } catch (e) {
      debugPrint(
        '[IDENTITY_KEY_MANAGER] Error getting local identity public key: $e',
      );
      return null;
    }
  }

  /// Upload identity key to server
  Future<void> uploadIdentityKey() async {
    debugPrint('[IDENTITY_KEY_MANAGER] Uploading identity key to server...');

    final identityData = await identityStore.getIdentityKeyPairData();
    final registrationId = await identityStore.getLocalRegistrationId();

    final response = await ApiService.post(
      '/signal/identity',
      data: {
        'publicKey': identityData['publicKey'],
        'registrationId': registrationId.toString(),
      },
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to upload identity: ${response.statusCode}');
    }

    debugPrint('[IDENTITY_KEY_MANAGER] ✓ Identity key uploaded');
  }
}
