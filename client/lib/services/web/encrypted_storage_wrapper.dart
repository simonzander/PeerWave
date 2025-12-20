import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'webauthn_crypto_service.dart';
import '../native_crypto_service.dart';
import '../device_identity_service.dart';

/// Transparent encryption/decryption wrapper for IndexedDB storage
/// 
/// This wrapper automatically encrypts data before storing and decrypts
/// data when reading, using keys derived from WebAuthn signatures (web)
/// or secure storage (native).
class EncryptedStorageWrapper {
  final WebAuthnCryptoService _webCrypto = WebAuthnCryptoService.instance;
  final NativeCryptoService _nativeCrypto = NativeCryptoService.instance;
  final DeviceIdentityService _deviceIdentity = DeviceIdentityService.instance;
  
  /// Get encryption key (platform-specific)
  Future<Uint8List?> _getKey() async {
    if (kIsWeb) {
      return _webCrypto.getKeyFromSession(_deviceIdentity.deviceId);
    } else {
      return await _nativeCrypto.getKey(_deviceIdentity.deviceId);
    }
  }
  
  /// Encrypt data before storing
  /// 
  /// Returns an envelope containing:
  /// - version: Format version for future compatibility
  /// - deviceId: Device ownership verification
  /// - iv: Initialization vector for AES-GCM
  /// - data: Encrypted data (base64)
  /// - timestamp: When the data was encrypted
  Future<Map<String, dynamic>> encryptForStorage(dynamic value) async {
    // Get encryption key (platform-specific)
    final key = await _getKey();
    if (key == null) {
      throw Exception('No encryption key available. Please re-authenticate.');
    }
    
    // Serialize value
    final plaintext = jsonEncode(value);
    final plaintextBytes = utf8.encode(plaintext);
    
    // Encrypt (use web crypto service - works for both platforms)
    final encrypted = await _webCrypto.encrypt(Uint8List.fromList(plaintextBytes), key);
    
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
  /// For SQLite BLOB format, deviceId verification is skipped (device isolation handled by database name).
  Future<dynamic> decryptFromStorage(Map<String, dynamic> envelope) async {
    // Verify device ownership (skip if deviceId is null - SQLite BLOB format)
    final envelopeDeviceId = envelope['deviceId'];
    if (envelopeDeviceId != null && envelopeDeviceId != _deviceIdentity.deviceId) {
      throw Exception('Data belongs to different device');
    }
    
    // Get encryption key (platform-specific)
    final key = await _getKey();
    if (key == null) {
      throw Exception('No encryption key available. Please re-authenticate.');
    }
    
    // Decrypt (use web crypto service - works for both platforms)
    final decryptedBytes = await _webCrypto.decrypt(
      envelope['iv'] as String,
      envelope['data'] as String,
      key,
    );
    
    // Deserialize
    final plaintext = utf8.decode(decryptedBytes);
    return jsonDecode(plaintext);
  }
}
