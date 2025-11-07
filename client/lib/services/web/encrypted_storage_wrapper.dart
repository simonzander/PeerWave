import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'webauthn_crypto_service.dart';
import '../device_identity_service.dart';

/// Transparent encryption/decryption wrapper for IndexedDB storage
/// 
/// This wrapper automatically encrypts data before storing and decrypts
/// data when reading, using keys derived from WebAuthn signatures.
class EncryptedStorageWrapper {
  final WebAuthnCryptoService _crypto = WebAuthnCryptoService.instance;
  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  
  /// Encrypt data before storing
  /// 
  /// Returns an envelope containing:
  /// - version: Format version for future compatibility
  /// - deviceId: Device ownership verification
  /// - iv: Initialization vector for AES-GCM
  /// - data: Encrypted data (base64)
  /// - timestamp: When the data was encrypted
  Future<Map<String, dynamic>> encryptForStorage(dynamic value) async {
    // Get encryption key from session
    final key = _crypto.getKeyFromSession(_deviceIdentity.deviceId);
    if (key == null) {
      throw Exception('No encryption key available. Please re-authenticate.');
    }
    
    // Serialize value
    final plaintext = jsonEncode(value);
    final plaintextBytes = utf8.encode(plaintext);
    
    // Encrypt
    final encrypted = await _crypto.encrypt(Uint8List.fromList(plaintextBytes), key);
    
    // Create envelope with metadata
    return {
      'version': 1,
      'deviceId': _deviceIdentity.deviceId,
      'iv': encrypted['iv'],
      'data': encrypted['data'],
      'timestamp': DateTime.now().toIso8601String(),
    };
  }
  
  /// Decrypt data when reading
  /// 
  /// Verifies device ownership and decrypts the data using the session key.
  Future<dynamic> decryptFromStorage(Map<String, dynamic> envelope) async {
    // Verify device ownership
    if (envelope['deviceId'] != _deviceIdentity.deviceId) {
      throw Exception('Data belongs to different device');
    }
    
    // Get encryption key
    final key = _crypto.getKeyFromSession(_deviceIdentity.deviceId);
    if (key == null) {
      throw Exception('No encryption key available. Please re-authenticate.');
    }
    
    // Decrypt
    final decryptedBytes = await _crypto.decrypt(
      envelope['iv'] as String,
      envelope['data'] as String,
      key,
    );
    
    // Deserialize
    final plaintext = utf8.decode(decryptedBytes);
    return jsonDecode(plaintext);
  }
}
