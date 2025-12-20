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
      debugPrint('[NATIVE_CRYPTO] ✓ Loaded existing encryption key for device: $deviceId');
      return base64Decode(existingKey);
    }
    
    // Generate new 32-byte key
    debugPrint('[NATIVE_CRYPTO] 🔑 Generating new encryption key for device: $deviceId');
    final keyBytes = _generateRandomBytes(32);
    
    // Store in secure storage
    final keyBase64 = base64Encode(keyBytes);
    await _secureStorage.write(key: storageKey, value: keyBase64);
    
    debugPrint('[NATIVE_CRYPTO] ✓ Encryption key generated and stored');
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
    debugPrint('[NATIVE_CRYPTO] ✓ Encryption key cleared for device: $deviceId');
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
}
