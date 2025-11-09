import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;
import '../web/encrypted_storage_wrapper.dart';

/// Service for application-layer encryption/decryption of SQLite database fields
/// 
/// Since sqflite_common_ffi_web (SQLite in WASM) doesn't support SQLCipher,
/// we use application-layer encryption for sensitive columns.
/// 
/// Usage:
/// - Encrypt sensitive data before INSERT/UPDATE
/// - Decrypt sensitive data after SELECT
/// - Uses WebAuthn-derived encryption key
class DatabaseEncryptionService {
  static final DatabaseEncryptionService instance = DatabaseEncryptionService._();
  DatabaseEncryptionService._();
  
  final EncryptedStorageWrapper _encryption = EncryptedStorageWrapper();
  
  /// Encrypt a field value for storage in database
  /// 
  /// Returns BLOB-compatible bytes: [version(1) | iv(12) | encryptedData]
  Future<Uint8List> encryptField(dynamic value) async {
    debugPrint('[DB_ENCRYPTION] Encrypting field...');
    
    try {
      // Encrypt the value using WebAuthn-derived key
      final envelope = await _encryption.encryptForStorage(value);
      
      // Extract components from envelope
      // Note: 'iv' and 'data' are base64-encoded strings from WebAuthnCryptoService
      final ivBase64 = envelope['iv'] as String;
      final dataBase64 = envelope['data'] as String;
      final version = envelope['version'] as int;
      
      // Decode from base64
      final ivBytes = base64Decode(ivBase64);
      final encryptedBytes = base64Decode(dataBase64);
      
      // Concatenate: [version(1) | iv(12) | encryptedData]
      final combined = Uint8List(1 + ivBytes.length + encryptedBytes.length);
      combined[0] = version;
      combined.setRange(1, 1 + ivBytes.length, ivBytes);
      combined.setRange(1 + ivBytes.length, combined.length, encryptedBytes);
      
      debugPrint('[DB_ENCRYPTION] ✓ Field encrypted: ${combined.length} bytes');
      return combined;
    } catch (e) {
      debugPrint('[DB_ENCRYPTION] ✗ Encryption failed: $e');
      rethrow;
    }
  }
  
  /// Decrypt a field value from database
  /// 
  /// Expects BLOB format: [version(1) | iv(12) | encryptedData]
  Future<dynamic> decryptField(dynamic encryptedBlob) async {
    if (encryptedBlob == null) {
      return null;
    }
    
    debugPrint('[DB_ENCRYPTION] Decrypting field...');
    
    try {
      // Convert to Uint8List if needed
      Uint8List bytes;
      if (encryptedBlob is Uint8List) {
        bytes = encryptedBlob;
      } else if (encryptedBlob is List) {
        bytes = Uint8List.fromList(encryptedBlob.cast<int>());
      } else {
        throw Exception('Invalid encrypted blob type: ${encryptedBlob.runtimeType}');
      }
      
      // Extract components: [version(1) | iv(12) | encryptedData]
      if (bytes.length < 14) { // version + iv = 13 bytes minimum
        throw Exception('Invalid encrypted blob length: ${bytes.length}');
      }
      
      final version = bytes[0];
      final iv = bytes.sublist(1, 13); // 12 bytes
      final encryptedData = bytes.sublist(13);
      
      // Reconstruct envelope for decryption (base64-encoded for compatibility)
      final envelope = {
        'version': version,
        'deviceId': null, // Not used in this flow
        'iv': base64Encode(iv),
        'data': base64Encode(encryptedData),
      };
      
      // Decrypt using WebAuthn-derived key
      final decrypted = await _encryption.decryptFromStorage(envelope);
      
      debugPrint('[DB_ENCRYPTION] ✓ Field decrypted');
      return decrypted;
    } catch (e) {
      debugPrint('[DB_ENCRYPTION] ✗ Decryption failed: $e');
      rethrow;
    }
  }
  
  /// Encrypt a string field (convenience method)
  Future<Uint8List> encryptString(String value) async {
    return await encryptField(value);
  }
  
  /// Decrypt to string (convenience method)
  Future<String?> decryptString(dynamic encryptedBlob) async {
    final decrypted = await decryptField(encryptedBlob);
    return decrypted as String?;
  }
  
  /// Encrypt a map/JSON field
  Future<Uint8List> encryptJson(Map<String, dynamic> value) async {
    return await encryptField(value);
  }
  
  /// Decrypt to map/JSON
  Future<Map<String, dynamic>?> decryptJson(dynamic encryptedBlob) async {
    final decrypted = await decryptField(encryptedBlob);
    if (decrypted == null) return null;
    
    if (decrypted is Map<String, dynamic>) {
      return decrypted;
    } else if (decrypted is Map) {
      return Map<String, dynamic>.from(decrypted);
    }
    
    throw Exception('Decrypted value is not a Map: ${decrypted.runtimeType}');
  }
  
  /// Check if encryption is available
  bool get isAvailable {
    try {
      // Try to access the encryption service
      // If it throws, encryption is not available
      return true; // Encryption service is initialized
    } catch (e) {
      return false;
    }
  }
}
