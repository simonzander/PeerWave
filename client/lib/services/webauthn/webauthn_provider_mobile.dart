import 'package:flutter/foundation.dart';
import '../webauthn_service_mobile.dart';
import 'webauthn_provider.dart';

/// Mobile implementation of WebAuthn using biometric authentication
///
/// Uses MobileWebAuthnService for Face ID, Touch ID, and Fingerprint authentication
class WebAuthnProviderMobile implements IWebAuthnProvider {
  final MobileWebAuthnService _mobileService = MobileWebAuthnService.instance;

  @override
  Future<bool> isAvailable() async {
    return await _mobileService.isBiometricAvailable();
  }

  @override
  Future<Map<String, dynamic>?> register({
    required String serverUrl,
    required String email,
  }) async {
    try {
      // Call the existing mobile WebAuthn registration
      // Returns just the credential ID as a String
      final credentialId = await _mobileService.register(
        serverUrl: serverUrl,
        email: email,
      );

      if (credentialId == null) {
        return null;
      }

      // For mobile, we don't get a signature during registration
      // The signature comes from authentication
      return {
        'credentialId': credentialId,
        'signature': '', // Empty for registration
        'success': true,
      };
    } catch (e) {
      debugPrint('[WebAuthnProviderMobile] Registration error: $e');
      return null;
    }
  }

  @override
  Future<Map<String, dynamic>?> authenticate({
    required String serverUrl,
    required String email,
    required String clientId,
  }) async {
    try {
      // Call the existing mobile WebAuthn authentication
      final authResult = await _mobileService.authenticate(
        serverUrl: serverUrl,
        email: email,
      );

      if (authResult == null) {
        return null;
      }

      // Extract credential ID and signature from result
      return {
        'credentialId': authResult['credentialId'] as String,
        'signature': authResult['signature'] as String? ?? '',
        'success': true,
      };
    } catch (e) {
      debugPrint('[WebAuthnProviderMobile] Authentication error: $e');
      return null;
    }
  }

  @override
  Future<bool> hasCredential({
    required String serverUrl,
    required String email,
  }) async {
    return await _mobileService.hasCredential(serverUrl, email);
  }

  @override
  Future<void> deleteCredential({
    required String serverUrl,
    required String email,
  }) async {
    await _mobileService.deleteCredential(serverUrl, email);
  }
}
