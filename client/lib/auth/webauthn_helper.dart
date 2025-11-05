// webauthn_helper.dart
// This file provides a platform-specific helper for calling the JS WebAuthn function.

// Stub for non-web platforms
void webauthnLogin(String serverUrl, String email) {
  throw UnsupportedError('WebAuthn is only available on Flutter web.');
}

