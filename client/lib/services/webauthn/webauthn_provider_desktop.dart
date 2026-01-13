import 'package:flutter/foundation.dart';
import 'webauthn_provider.dart';

/// Desktop implementation of WebAuthn (not supported)
///
/// Returns false/null for all operations since desktop platforms
/// use magic key authentication instead
class WebAuthnProviderDesktop implements IWebAuthnProvider {
  @override
  Future<bool> isAvailable() async {
    return false; // Desktop doesn't support WebAuthn
  }

  @override
  Future<Map<String, dynamic>?> register({
    required String serverUrl,
    required String email,
  }) async {
    debugPrint('[WebAuthnProviderDesktop] WebAuthn not supported on desktop');
    return null;
  }

  @override
  Future<Map<String, dynamic>?> authenticate({
    required String serverUrl,
    required String email,
    required String clientId,
  }) async {
    debugPrint('[WebAuthnProviderDesktop] WebAuthn not supported on desktop');
    return null;
  }

  @override
  Future<bool> hasCredential({
    required String serverUrl,
    required String email,
  }) async {
    return false;
  }

  @override
  Future<void> deleteCredential({
    required String serverUrl,
    required String email,
  }) async {
    // No-op on desktop
  }
}
