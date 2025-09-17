// Stub for non-web platforms
dynamic webauthnLoginJs(String serverUrl, String email) {
  throw UnimplementedError('WebAuthn JS interop is only available on web.');
}
