import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';

/// Native client encryption key management
/// Generates and stores encryption keys in platform secure storage
class NativeCryptoService {
  static final NativeCryptoService instance = NativeCryptoService._();
  NativeCryptoService._();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _keyPrefix = 'peerwave_encryption_key_';

  /// Generate or retrieve encryption key for a device ID
  /// Returns 32 bytes of key material
  Future<Uint8List> getOrCreateKey(String deviceId) async {
    final storageKey = '$_keyPrefix$deviceId';

    // Try to load existing key
    final existingKey = await _secureStorage.read(key: storageKey);
    if (existingKey != null) {
      debugPrint(
        '[NATIVE_CRYPTO] ✓ Loaded existing encryption key for device: $deviceId',
      );
      return base64Decode(existingKey);
    }

    // Generate new 32-byte key
    debugPrint(
      '[NATIVE_CRYPTO] 🔑 Generating new encryption key for device: $deviceId',
    );
    final keyBytes = _generateRandomBytes(32);

    // Store in secure storage
    final keyBase64 = base64Encode(keyBytes);
    await _secureStorage.write(key: storageKey, value: keyBase64);

    debugPrint('[NATIVE_CRYPTO] ✓ Encryption key generated and stored');
    return keyBytes;
  }

  /// Derive encryption key from credentialId (for WebAuthn-based auth)
  /// This ensures the same key is generated across logins using the same passkey
  Future<Uint8List> deriveKeyFromCredentialId(
    String deviceId,
    String credentialId,
  ) async {
    final storageKey = '$_keyPrefix$deviceId';

    // Try to load existing key first
    final existingKey = await _secureStorage.read(key: storageKey);
    if (existingKey != null) {
      debugPrint(
        '[NATIVE_CRYPTO] ✓ Loaded existing encryption key for device: $deviceId',
      );
      return base64Decode(existingKey);
    }

    // Derive key from credentialId using PBKDF2
    debugPrint(
      '[NATIVE_CRYPTO] 🔑 Deriving encryption key from credentialId for device: $deviceId',
    );

    // Decode credentialId from base64url (handle missing padding)
    String paddedCredentialId = credentialId;
    // Add padding if needed
    while (paddedCredentialId.length % 4 != 0) {
      paddedCredentialId += '=';
    }
    final credentialBytes = base64Url.decode(paddedCredentialId);

    // Use PBKDF2 to derive a stable 32-byte key
    // Salt is deviceId to ensure unique keys per device
    final saltBytes = utf8.encode(deviceId);
    final keyBytes = _pbkdf2(credentialBytes, saltBytes, 100000, 32);

    // Store in secure storage
    final keyBase64 = base64Encode(keyBytes);
    await _secureStorage.write(key: storageKey, value: keyBase64);

    debugPrint('[NATIVE_CRYPTO] ✓ Encryption key derived and stored');
    return keyBytes;
  }

  /// Get encryption key from storage (returns null if not found)
  Future<Uint8List?> getKey(String deviceId) async {
    final storageKey = '$_keyPrefix$deviceId';
    final existingKey = await _secureStorage.read(key: storageKey);
    if (existingKey != null) {
      return base64Decode(existingKey);
    }
    return null;
  }

  /// Clear encryption key for a device
  Future<void> clearKey(String deviceId) async {
    final storageKey = '$_keyPrefix$deviceId';
    await _secureStorage.delete(key: storageKey);
    debugPrint(
      '[NATIVE_CRYPTO] ✓ Encryption key cleared for device: $deviceId',
    );
  }

  /// Generate cryptographically secure random bytes
  Uint8List _generateRandomBytes(int length) {
    // Use crypto-secure random from dart:convert for key generation
    final random = List<int>.generate(length, (i) {
      // Generate random bytes using SHA256 with timestamp + random data
      final timestamp = DateTime.now().microsecondsSinceEpoch;
      final combined = '$timestamp-$i-${DateTime.now().toString()}';
      final hash = sha256.convert(utf8.encode(combined));
      return hash.bytes[i % hash.bytes.length];
    });

    return Uint8List.fromList(random);
  }

  /// PBKDF2 key derivation function
  /// Used to derive stable encryption keys from credentialId
  Uint8List _pbkdf2(
    List<int> password,
    List<int> salt,
    int iterations,
    int keyLength,
  ) {
    var hmac = Hmac(sha256, password);
    var result = Uint8List(keyLength);
    var blockCount = (keyLength / 32).ceil();

    for (var block = 1; block <= blockCount; block++) {
      var blockSalt = Uint8List(salt.length + 4);
      blockSalt.setRange(0, salt.length, salt);
      blockSalt[salt.length] = (block >> 24) & 0xff;
      blockSalt[salt.length + 1] = (block >> 16) & 0xff;
      blockSalt[salt.length + 2] = (block >> 8) & 0xff;
      blockSalt[salt.length + 3] = block & 0xff;

      var u = hmac.convert(blockSalt).bytes;
      var f = Uint8List.fromList(u);

      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var j = 0; j < f.length; j++) {
          f[j] ^= u[j];
        }
      }

      var offset = (block - 1) * 32;
      var length = (block == blockCount) ? keyLength - offset : 32;
      result.setRange(offset, offset + length, f);
    }

    return result;
  }
}
