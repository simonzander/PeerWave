/// Abstract interface for WebAuthn operations across platforms
///
/// Platform-specific implementations:
/// - Web: Uses browser's navigator.credentials API via JS interop
/// - Mobile (iOS/Android): Uses biometric authentication (Face ID, Touch ID, Fingerprint)
/// - Desktop: Not supported (returns null for all operations)
abstract class IWebAuthnProvider {
  /// Check if WebAuthn/biometric authentication is available on this platform
  Future<bool> isAvailable();

  /// Register a new WebAuthn credential
  ///
  /// Returns a map containing:
  /// - `credentialId`: String - The credential ID
  /// - `signature`: String - The attestation signature (for encryption key derivation)
  /// - `success`: bool - Whether registration succeeded
  ///
  /// Returns null if registration fails or is cancelled
  Future<Map<String, dynamic>?> register({
    required String serverUrl,
    required String email,
  });

  /// Authenticate with an existing WebAuthn credential
  ///
  /// Returns a map containing:
  /// - `credentialId`: String - The credential ID
  /// - `signature`: String - The assertion signature (for encryption key derivation)
  /// - `success`: bool - Whether authentication succeeded
  ///
  /// Returns null if authentication fails or is cancelled
  Future<Map<String, dynamic>?> authenticate({
    required String serverUrl,
    required String email,
    required String clientId,
  });

  /// Check if a credential exists for the given server and email
  Future<bool> hasCredential({
    required String serverUrl,
    required String email,
  });

  /// Delete a stored credential (mobile only)
  Future<void> deleteCredential({
    required String serverUrl,
    required String email,
  });
}
