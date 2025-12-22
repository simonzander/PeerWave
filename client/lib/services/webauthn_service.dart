import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'device_identity_service.dart';
import 'web/webauthn_crypto_service.dart';

/// Service for managing WebAuthn authentication and encryption key derivation
///
/// This service captures WebAuthn signatures during login and derives
/// encryption keys for secure IndexedDB storage.
class WebAuthnService {
  static final WebAuthnService instance = WebAuthnService._();
  WebAuthnService._();

  String? _currentCredentialId;
  Uint8List? _lastSignature;

  /// Decode base64URL string to bytes (handles URL-safe base64 without padding)
  Uint8List _base64UrlDecode(String base64Url) {
    // Convert base64URL to standard base64
    String base64 = base64Url.replaceAll('-', '+').replaceAll('_', '/');

    // Add padding if needed
    switch (base64.length % 4) {
      case 0:
        break; // No padding needed
      case 2:
        base64 += '==';
        break;
      case 3:
        base64 += '=';
        break;
      default:
        throw FormatException('Invalid base64URL string');
    }

    return base64Decode(base64);
  }

  /// Initialize and capture WebAuthn response data
  ///
  /// Call this after successful WebAuthn authentication to extract and store
  /// the signature for encryption key derivation.
  ///
  /// [credentialId] - The WebAuthn credential ID (rawId as base64URL)
  /// [signatureBase64] - The WebAuthn signature (response.signature as base64URL)
  Future<void> captureWebAuthnResponse(
    String credentialId,
    String signatureBase64,
  ) async {
    try {
      _currentCredentialId = credentialId;
      _lastSignature = _base64UrlDecode(signatureBase64);

      debugPrint('[WEBAUTHN_SERVICE] Captured WebAuthn response');
      debugPrint(
        '[WEBAUTHN_SERVICE] Credential ID: ${credentialId.substring(0, 16)}...',
      );
      debugPrint(
        '[WEBAUTHN_SERVICE] Signature length: ${_lastSignature!.length} bytes',
      );
    } catch (e) {
      debugPrint('[AUTH] ✗ Failed to capture WebAuthn signature: $e');
      rethrow;
    }
  }

  /// Initialize device encryption after WebAuthn login
  ///
  /// This should be called after successful WebAuthn authentication to:
  /// 1. Set device identity (email + credential + clientId)
  /// 2. Derive encryption key from CREDENTIAL ID (stable, not signature)
  /// 3. Store key in SessionStorage
  ///
  /// IMPORTANT: We derive the key from credentialId, NOT signature!
  /// - credentialId is stable across logins (same authenticator = same ID)
  /// - signature changes every time (includes counter + timestamp)
  /// - This allows encrypted data to be decrypted across login sessions
  ///
  /// [email] - User's email address
  /// [clientId] - Browser/device unique UUID
  Future<void> initializeDeviceEncryption(String email, String clientId) async {
    if (_currentCredentialId == null || _lastSignature == null) {
      throw Exception(
        'No WebAuthn response captured. Call captureWebAuthnResponse first.',
      );
    }

    debugPrint('[WEBAUTHN_SERVICE] Initializing device encryption');

    // 1. Set device identity
    DeviceIdentityService.instance.setDeviceIdentity(
      email,
      _currentCredentialId!,
      clientId,
    );

    final deviceId = DeviceIdentityService.instance.deviceId;
    debugPrint('[WEBAUTHN_SERVICE] ✓ Device identity set: $deviceId');

    // 2. Derive encryption key from CREDENTIAL ID (stable across logins)
    // CRITICAL FIX: Don't use signature (changes every login), use credentialId (stable)
    final credentialBytes = _base64UrlDecode(_currentCredentialId!);
    final encryptionKey = await WebAuthnCryptoService.instance
        .deriveEncryptionKey(credentialBytes);
    debugPrint(
      '[WEBAUTHN_SERVICE] ✓ Encryption key derived from credentialId (${encryptionKey.length} bytes)',
    );

    // 3. Store key in SessionStorage
    WebAuthnCryptoService.instance.storeKeyInSession(deviceId, encryptionKey);
    debugPrint('[WEBAUTHN_SERVICE] ✓ Encryption key stored in session');

    // 4. Verify key is retrievable
    final retrievedKey = WebAuthnCryptoService.instance.getKeyFromSession(
      deviceId,
    );
    if (retrievedKey == null) {
      throw Exception('Failed to store encryption key in SessionStorage');
    }

    debugPrint('[WEBAUTHN_SERVICE] ✓ Encryption key verified in session');
  }

  /// Clear WebAuthn data on logout
  void clearWebAuthnData() {
    debugPrint('[WEBAUTHN_SERVICE] Clearing WebAuthn data');
    _currentCredentialId = null;
    _lastSignature = null;
  }

  /// Get current credential ID
  String? get currentCredentialId => _currentCredentialId;

  /// Get last captured signature
  Uint8List? get lastSignature => _lastSignature;

  /// Check if WebAuthn response is available
  bool get hasWebAuthnResponse =>
      _currentCredentialId != null && _lastSignature != null;
}
