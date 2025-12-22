import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';
import 'package:universal_html/html.dart' as html show window;

/// WebAuthn-based encryption key derivation and storage service
///
/// This service derives encryption keys from WebAuthn signatures and manages
/// them in SessionStorage for encrypted IndexedDB operations.
class WebAuthnCryptoService {
  static final WebAuthnCryptoService instance = WebAuthnCryptoService._();
  WebAuthnCryptoService._();

  static const String _keyStoragePrefix = 'peerwave_encryption_key_';

  // Memory store for native platforms (cleared on app close)
  final Map<String, Uint8List> _memoryKeyStore = {};

  /// Derive encryption key from WebAuthn signature using HKDF
  ///
  /// [signature] - WebAuthn signature bytes from authentication
  /// Returns 32-byte AES-256 key
  Future<Uint8List> deriveEncryptionKey(Uint8List signature) async {
    debugPrint(
      '[WEBAUTHN_CRYPTO] Deriving encryption key from signature (${signature.length} bytes)',
    );

    // HKDF parameters
    final salt = utf8.encode('peerwave-indexeddb-encryption-v1');
    final info = utf8.encode('aes-gcm-256');

    // Use HKDF implementation
    return _deriveKeyHKDF(signature, salt, info);
  }

  /// HKDF implementation (RFC 5869)
  Uint8List _deriveKeyHKDF(Uint8List ikm, List<int> salt, List<int> info) {
    debugPrint('[WEBAUTHN_CRYPTO] Using HKDF-SHA256');

    // HKDF-Extract
    final hmacExtract = Hmac(sha256, salt);
    final prk = hmacExtract.convert(ikm).bytes;

    // HKDF-Expand (32 bytes for AES-256)
    final hmacExpand = Hmac(sha256, prk);
    final t = <int>[];
    final okm = <int>[];

    for (var i = 1; okm.length < 32; i++) {
      t.addAll(info);
      t.add(i);
      final hash = hmacExpand.convert(t).bytes;
      okm.addAll(hash);
      t.clear();
      t.addAll(hash);
    }

    final key = Uint8List.fromList(okm.sublist(0, 32));
    debugPrint(
      '[WEBAUTHN_CRYPTO] ✓ Key derived successfully (${key.length} bytes)',
    );
    return key;
  }

  /// Store encryption key in SessionStorage (cleared on browser close)
  void storeKeyInSession(String deviceId, Uint8List key) {
    final keyString = base64Encode(key);
    final storageKey = '$_keyStoragePrefix$deviceId';

    if (kIsWeb) {
      html.window.sessionStorage[storageKey] = keyString;
      debugPrint('[WEBAUTHN_CRYPTO] ✓ Key stored in SessionStorage');
    } else {
      // Native: Store in memory (session-scoped)
      _memoryKeyStore[deviceId] = key;
      debugPrint('[WEBAUTHN_CRYPTO] ✓ Key stored in memory');
    }
  }

  /// Retrieve encryption key from SessionStorage
  Uint8List? getKeyFromSession(String deviceId) {
    final storageKey = '$_keyStoragePrefix$deviceId';

    if (kIsWeb) {
      final keyString = html.window.sessionStorage[storageKey];
      if (keyString != null) {
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Key retrieved from SessionStorage');
        return base64Decode(keyString);
      }
    } else {
      final key = _memoryKeyStore[deviceId];
      if (key != null) {
        debugPrint('[WEBAUTHN_CRYPTO] ✓ Key retrieved from memory');
        return key;
      }
    }

    debugPrint('[WEBAUTHN_CRYPTO] ✗ No key found in session');
    return null;
  }

  /// Clear encryption key from session
  void clearKeyFromSession(String deviceId) {
    final storageKey = '$_keyStoragePrefix$deviceId';

    if (kIsWeb) {
      html.window.sessionStorage.remove(storageKey);
    } else {
      _memoryKeyStore.remove(deviceId);
    }

    debugPrint('[WEBAUTHN_CRYPTO] ✓ Key cleared from session');
  }

  /// Encrypt data with AES-GCM-256
  Future<Map<String, String>> encrypt(
    Uint8List plaintext,
    Uint8List key,
  ) async {
    debugPrint('[WEBAUTHN_CRYPTO] Encrypting data (${plaintext.length} bytes)');

    try {
      // Generate random IV (12 bytes for GCM)
      final random = SecureRandom('Fortuna')
        ..seed(
          KeyParameter(
            Uint8List.fromList(
              List<int>.generate(32, (i) => Random.secure().nextInt(256)),
            ),
          ),
        );
      final iv = random.nextBytes(12);

      // Setup AES-GCM cipher
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true, // encrypt
          AEADParameters(
            KeyParameter(key),
            128, // tag length in bits
            iv,
            Uint8List(0), // no additional authenticated data
          ),
        );

      // Encrypt
      final encrypted = cipher.process(plaintext);

      debugPrint(
        '[WEBAUTHN_CRYPTO] ✓ Data encrypted (${encrypted.length} bytes)',
      );

      return {'iv': base64Encode(iv), 'data': base64Encode(encrypted)};
    } catch (e) {
      debugPrint('[WEBAUTHN_CRYPTO] ✗ Encryption failed: $e');
      throw Exception('Encryption failed: $e');
    }
  }

  /// Decrypt data with AES-GCM-256
  Future<Uint8List> decrypt(
    String ivBase64,
    String dataBase64,
    Uint8List key,
  ) async {
    debugPrint('[WEBAUTHN_CRYPTO] Decrypting data');

    try {
      final iv = base64Decode(ivBase64);
      final encryptedData = base64Decode(dataBase64);

      // Setup AES-GCM cipher
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false, // decrypt
          AEADParameters(
            KeyParameter(key),
            128, // tag length in bits
            iv,
            Uint8List(0), // no additional authenticated data
          ),
        );

      // Decrypt
      final decrypted = cipher.process(encryptedData);

      debugPrint(
        '[WEBAUTHN_CRYPTO] ✓ Data decrypted (${decrypted.length} bytes)',
      );

      return decrypted;
    } catch (e) {
      debugPrint('[WEBAUTHN_CRYPTO] ✗ Decryption failed: $e');
      throw Exception('Decryption failed: $e');
    }
  }
}
