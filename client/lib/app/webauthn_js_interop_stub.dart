// Stub for non-web platforms

String? getLocalStorageEmail() {
  // localStorage only works on web
  return null;
}

Future<bool> webauthnRegister(String serverUrl, String email) async {
  // WebAuthn JS API only works on web
  return false;
}
